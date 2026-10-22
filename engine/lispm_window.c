/* lispm_window.c --- dsda-doom's window, when the window is an Emacs buffer
 *
 * Copyright (C) 2026  Ryan.K
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at
 * your option) any later version.  It is built into dsda-doom, which is
 * under the GNU General Public License, version 2 or later; the program
 * they make together is under the GNU Affero General Public License,
 * version 3 or later.
 *
 * The engine is a process of Emacs's, and has no window.  Its OpenGL
 * renderer (dsda-doom's, OpenGL 2's fixed pipeline) draws in a context
 * made with CGL, OpenGL 2.1's legacy profile, into a framebuffer object
 * standing for the window's: binding framebuffer 0 binds it, and swapping
 * reads it back.  Each frame goes to Emacs as a PPM file, which Emacs
 * shows as an image scaled to its window (a canvas image would be
 * cheaper, but Emacs on macOS drops a canvas's scale whenever it is
 * refreshed); two files take turns, so that Emacs reads one while the
 * next is written:
 *
 *   OpenGL --glReadPixels BGRA--> frame-N.ppm (mmap) --"frame N"--> Emacs
 *   Emacs  --"d KEY" / "u KEY" on standard input--> D_PostEvent
 *
 * The protocol is lines on standard output starting "lispm-doom ".  The
 * engine's own messages go to standard error.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <OpenGL/OpenGL.h>

#include "SDL.h"
#include "SDL_opengl.h"

#include "doomtype.h"
#include "d_event.h"
#include "d_main.h"
#include "i_main.h"
#include "i_system.h"
#include "lprintf.h"

#include "lispm_window.h"

#define PROTOCOL "lispm-doom "

static int protocol_fd = -1;

static CGLContextObj context;
static GLuint framebuffer, colour, depth_stencil;
static void *gl_library;
static PFNGLBINDFRAMEBUFFEREXTPROC real_bind_framebuffer_ext;
static PFNGLBINDFRAMEBUFFERPROC real_bind_framebuffer;

static int frame_width, frame_height;
static unsigned char *frames[2];
static size_t frame_bytes, frame_header;
static int frame_next;
static uint32_t *readback;

static char input[1024];
static size_t input_length;

static void say(const char *format, ...)
{
  char line[512];
  va_list arguments;
  int length;

  if (protocol_fd < 0)
    return;
  va_start(arguments, format);
  length = vsnprintf(line, sizeof(line) - 1, format, arguments);
  va_end(arguments);
  if (length < 0)
    return;
  if (length > (int) sizeof(line) - 2)
    length = sizeof(line) - 2;
  line[length] = '\n';
  /* One write a line: a pipe keeps it whole. */
  if (write(protocol_fd, line, length + 1) < 0 && errno == EPIPE)
    I_SafeExit(0);
}

void lispm_window_begin(void)
{
  int flags;

  protocol_fd = dup(STDOUT_FILENO);
  dup2(STDERR_FILENO, STDOUT_FILENO);
  flags = fcntl(STDIN_FILENO, F_GETFL);
  if (flags >= 0)
    fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
  say(PROTOCOL "hello 1");
}

void lispm_window_caption(const char *caption)
{
  say(PROTOCOL "caption %s", caption);
}

/* The frame files, in LISPM_DOOM_FRAMES, mapped: PPM, P6, a header and
   then the rows from the top, three bytes a pixel. */

static void close_frames(void)
{
  int i;

  for (i = 0; i < 2; i++)
  {
    if (frames[i])
      munmap(frames[i], frame_bytes);
    frames[i] = NULL;
  }
  free(readback);
  readback = NULL;
}

static void open_frames(int width, int height)
{
  const char *directory = getenv("LISPM_DOOM_FRAMES");
  char header[64];
  int i;

  if (!directory)
    I_Error("lispm-doom: LISPM_DOOM_FRAMES names no directory for the frames");
  close_frames();
  frame_width = width;
  frame_height = height;
  frame_header = snprintf(header, sizeof(header), "P6\n%d %d\n255\n", width, height);
  frame_bytes = frame_header + (size_t) width * height * 3;
  for (i = 0; i < 2; i++)
  {
    char name[4096];
    int fd;

    snprintf(name, sizeof(name), "%s/frame-%d.ppm", directory, i);
    fd = open(name, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (fd < 0 || ftruncate(fd, frame_bytes) < 0)
      I_Error("lispm-doom: %s: %s", name, strerror(errno));
    frames[i] = mmap(NULL, frame_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (frames[i] == MAP_FAILED)
    {
      frames[i] = NULL;
      I_Error("lispm-doom: cannot map %s: %s", name, strerror(errno));
    }
    memcpy(frames[i], header, frame_header);
  }
  readback = malloc((size_t) width * height * 4);
  if (!readback)
    I_Error("lispm-doom: no memory for a frame");
  frame_next = 0;
  say(PROTOCOL "size %d %d", width, height);
}

static void hand_over(void)
{
  say(PROTOCOL "frame %d", frame_next);
  frame_next ^= 1;
}

/* OpenGL, its window a framebuffer object. */

static void APIENTRY bind_framebuffer_ext(GLenum target, GLuint name)
{
  real_bind_framebuffer_ext(target, name ? name : framebuffer);
}

static void APIENTRY bind_framebuffer(GLenum target, GLuint name)
{
  real_bind_framebuffer(target, name ? name : framebuffer);
}

/* SDL's, for the window there is not: these take the place of the
   library's own for the engine, which looks its OpenGL functions up
   through them. */

void *SDL_GL_GetProcAddress(const char *proc)
{
  void *address;

  if (!gl_library)
    gl_library = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
  address = gl_library ? dlsym(gl_library, proc) : NULL;
  if (address && !strcmp(proc, "glBindFramebufferEXT"))
  {
    real_bind_framebuffer_ext = address;
    return (void *) bind_framebuffer_ext;
  }
  if (address && !strcmp(proc, "glBindFramebuffer"))
  {
    real_bind_framebuffer = address;
    return (void *) bind_framebuffer;
  }
  return address;
}

void SDL_GL_SwapWindow(SDL_Window *window)
{
  (void) window;
  lispm_window_present_gl();
}

void SDL_GL_GetDrawableSize(SDL_Window *window, int *w, int *h)
{
  (void) window;
  if (w)
    *w = frame_width;
  if (h)
    *h = frame_height;
}

int SDL_GL_SetAttribute(SDL_GLattr attr, int value)
{
  (void) attr;
  (void) value;
  return 0;
}

int SDL_GL_GetAttribute(SDL_GLattr attr, int *value)
{
  (void) attr;
  if (value)
    *value = 0;
  return 0;
}

static void close_gl(void)
{
  PFNGLDELETEFRAMEBUFFERSEXTPROC delete_framebuffers;
  PFNGLDELETERENDERBUFFERSEXTPROC delete_renderbuffers;

  if (!context)
    return;
  CGLSetCurrentContext(context);
  delete_framebuffers = SDL_GL_GetProcAddress("glDeleteFramebuffersEXT");
  delete_renderbuffers = SDL_GL_GetProcAddress("glDeleteRenderbuffersEXT");
  if (delete_framebuffers && framebuffer)
    delete_framebuffers(1, &framebuffer);
  if (delete_renderbuffers)
  {
    GLuint renderbuffers[2] = { colour, depth_stencil };
    delete_renderbuffers(2, renderbuffers);
  }
  framebuffer = colour = depth_stencil = 0;
  CGLSetCurrentContext(NULL);
  CGLDestroyContext(context);
  context = NULL;
}

void lispm_window_open_gl(int width, int height)
{
  CGLPixelFormatAttribute attributes[] = {
    kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute) kCGLOGLPVersion_Legacy,
    kCGLPFAColorSize, (CGLPixelFormatAttribute) 24,
    kCGLPFAAlphaSize, (CGLPixelFormatAttribute) 8,
    kCGLPFADepthSize, (CGLPixelFormatAttribute) 24,
    kCGLPFAStencilSize, (CGLPixelFormatAttribute) 8,
    kCGLPFAAllowOfflineRenderers,
    (CGLPixelFormatAttribute) 0
  };
  CGLPixelFormatObj format = NULL;
  GLint count = 0;
  CGLError error;
  PFNGLGENFRAMEBUFFERSEXTPROC gen_framebuffers;
  PFNGLGENRENDERBUFFERSEXTPROC gen_renderbuffers;
  PFNGLBINDRENDERBUFFEREXTPROC bind_renderbuffer;
  PFNGLRENDERBUFFERSTORAGEEXTPROC renderbuffer_storage;
  PFNGLFRAMEBUFFERRENDERBUFFEREXTPROC framebuffer_renderbuffer;
  PFNGLCHECKFRAMEBUFFERSTATUSEXTPROC check_framebuffer_status;
  GLenum status;

  close_gl();
  error = CGLChoosePixelFormat(attributes, &format, &count);
  if (error != kCGLNoError || !format)
    I_Error("lispm-doom: no OpenGL 2.1 pixel format: %s", CGLErrorString(error));
  error = CGLCreateContext(format, NULL, &context);
  CGLDestroyPixelFormat(format);
  if (error != kCGLNoError || !context)
    I_Error("lispm-doom: no OpenGL 2.1 context: %s", CGLErrorString(error));
  CGLSetCurrentContext(context);

  gen_framebuffers = SDL_GL_GetProcAddress("glGenFramebuffersEXT");
  gen_renderbuffers = SDL_GL_GetProcAddress("glGenRenderbuffersEXT");
  bind_renderbuffer = SDL_GL_GetProcAddress("glBindRenderbufferEXT");
  renderbuffer_storage = SDL_GL_GetProcAddress("glRenderbufferStorageEXT");
  framebuffer_renderbuffer = SDL_GL_GetProcAddress("glFramebufferRenderbufferEXT");
  check_framebuffer_status = SDL_GL_GetProcAddress("glCheckFramebufferStatusEXT");
  /* Looked up last, it is the real one the engine's binds call. */
  SDL_GL_GetProcAddress("glBindFramebufferEXT");
  if (!gen_framebuffers || !gen_renderbuffers || !bind_renderbuffer || !renderbuffer_storage
      || !framebuffer_renderbuffer || !check_framebuffer_status || !real_bind_framebuffer_ext)
    I_Error("lispm-doom: this OpenGL has no framebuffer objects");

  gen_framebuffers(1, &framebuffer);
  real_bind_framebuffer_ext(GL_FRAMEBUFFER_EXT, framebuffer);
  gen_renderbuffers(1, &colour);
  bind_renderbuffer(GL_RENDERBUFFER_EXT, colour);
  renderbuffer_storage(GL_RENDERBUFFER_EXT, GL_RGBA8, width, height);
  framebuffer_renderbuffer(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_RENDERBUFFER_EXT, colour);
  gen_renderbuffers(1, &depth_stencil);
  bind_renderbuffer(GL_RENDERBUFFER_EXT, depth_stencil);
  renderbuffer_storage(GL_RENDERBUFFER_EXT, GL_DEPTH24_STENCIL8_EXT, width, height);
  framebuffer_renderbuffer(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, depth_stencil);
  framebuffer_renderbuffer(GL_FRAMEBUFFER_EXT, GL_STENCIL_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, depth_stencil);
  status = check_framebuffer_status(GL_FRAMEBUFFER_EXT);
  if (status != GL_FRAMEBUFFER_COMPLETE_EXT)
    I_Error("lispm-doom: the framebuffer is incomplete (0x%x)", status);
  glViewport(0, 0, width, height);
  lprintf(LO_INFO, "lispm-doom: %s, OpenGL %s, %dx%d\n",
          (const char *) glGetString(GL_RENDERER), (const char *) glGetString(GL_VERSION), width, height);
  open_frames(width, height);
}

void lispm_window_open_software(int width, int height)
{
  close_gl();
  open_frames(width, height);
}

/* Write the row FROM, 0xAARRGGBB pixels, as row ROW of the frame being
   written. */
static void put_row(int row, const uint32_t *from)
{
  unsigned char *to = frames[frame_next] + frame_header + (size_t) row * frame_width * 3;
  int x;

  for (x = 0; x < frame_width; x++)
  {
    uint32_t pixel = from[x];

    to[0] = pixel >> 16;
    to[1] = pixel >> 8;
    to[2] = pixel;
    to += 3;
  }
}

void lispm_window_present_gl(void)
{
  int row;

  if (!frames[frame_next] || !context)
    return;
  real_bind_framebuffer_ext(GL_FRAMEBUFFER_EXT, framebuffer);
  glPixelStorei(GL_PACK_ALIGNMENT, 4);
  glReadPixels(0, 0, frame_width, frame_height, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, readback);
  /* OpenGL's rows go up from the bottom, PPM's down from the top. */
  for (row = 0; row < frame_height; row++)
    put_row(row, readback + (size_t) (frame_height - 1 - row) * frame_width);
  hand_over();
}

void lispm_window_present_pixels(const uint32_t *pixels, int width, int height, int pitch)
{
  int row;

  if (!frames[frame_next] || width != frame_width || height != frame_height)
    return;
  for (row = 0; row < height; row++)
    put_row(row, (const uint32_t *) ((const char *) pixels + (size_t) row * pitch));
  hand_over();
}

/* Keys: "d KEY" pressed, "u KEY" released, KEY a Doom key code; "q" to
   quit.  Standard input closed, Emacs is gone, and so is the game. */

static void handle(const char *line)
{
  event_t event;

  memset(&event, 0, sizeof(event));
  if ((line[0] == 'd' || line[0] == 'u') && line[1] == ' ')
  {
    event.type = line[0] == 'd' ? ev_keydown : ev_keyup;
    event.data1.i = atoi(line + 2);
    if (event.data1.i > 0)
      D_PostEvent(&event);
  }
  else if (line[0] == 'q')
    I_SafeExit(0);
}

void lispm_window_read_input(void)
{
  for (;;)
  {
    ssize_t got = read(STDIN_FILENO, input + input_length, sizeof(input) - 1 - input_length);
    char *start, *newline;

    if (got == 0)
      I_SafeExit(0);
    if (got < 0)
    {
      if (errno == EINTR)
        continue;
      return;
    }
    input_length += got;
    input[input_length] = '\0';
    start = input;
    while ((newline = strchr(start, '\n')))
    {
      *newline = '\0';
      handle(start);
      start = newline + 1;
    }
    input_length -= start - input;
    memmove(input, start, input_length);
    if (input_length == sizeof(input) - 1)
      input_length = 0;
  }
}
