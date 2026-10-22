/* lispm_window.h --- dsda-doom's window, when the window is an Emacs buffer
 *
 * Copyright (C) 2026  Ryan.K
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * The engine runs as a process of Emacs's.  It draws with OpenGL into a
 * framebuffer of its own, no window anywhere, and hands each frame to
 * Emacs as a PPM file Emacs shows as an image; the keys come back on its
 * standard input.  See lispm_window.c.
 */

#ifndef LISPM_WINDOW_H
#define LISPM_WINDOW_H

#include <stdint.h>

/* Start talking to Emacs: standard output carries the protocol from now
   on, and what the engine prints goes to standard error. */
void lispm_window_begin(void);

/* Make, or make again, the OpenGL context and framebuffer WIDTH by HEIGHT
   pixels, and the frame files as large. */
void lispm_window_open_gl(int width, int height);

/* Make, or make again, the frame files WIDTH by HEIGHT pixels, for the
   software renderer, which has no OpenGL context. */
void lispm_window_open_software(int width, int height);

/* Hand Emacs the frame OpenGL drew. */
void lispm_window_present_gl(void);

/* Hand Emacs PIXELS, WIDTH by HEIGHT 0x00RRGGBB values, PITCH bytes a row
   apart, as the software renderer drew them. */
void lispm_window_present_pixels(const uint32_t *pixels, int width, int height, int pitch);

/* Post to the game the keys Emacs sent since the last call. */
void lispm_window_read_input(void);

/* Tell Emacs the window's title. */
void lispm_window_caption(const char *caption);

#endif
