;;; lispm-doom.el --- Doom in an Emacs buffer, drawn with OpenGL -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (lispm-prebuilt "0.1.0"))
;; Keywords: games
;; URL: https://github.com/LispMachineLab/lispm-doom
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; M-x lispm-doom plays Doom in a buffer: dsda-doom, its OpenGL renderer
;; drawing off screen in a process of its own (see engine/), each frame
;; shown as an image filling the window, with sound and music.  The game is
;; Freedoom: Phase 1, free to share, downloaded and checked the first time;
;; `lispm-doom-iwad' names another, as doom.wad.
;;
;;   engine --"lispm-doom frame N", frame-N.ppm--> the image, reloaded
;;
;; The frames are PPM files, not a canvas image's pixels: Emacs on macOS
;; drops a canvas's scale whenever the canvas is refreshed, so a canvas
;; cannot fill a window there.
;;   keys   --"d KEY" / "u KEY"-->  engine
;;
;; Emacs hears no key released, only keys pressed and repeated: a key
;; counts as held until it has not repeated for a moment, see
;; `lispm-doom-release-delay'.
;;
;; Keys: W A S D or the arrows move, Q and E turn, F or J fires, Space
;; opens doors, Tab shows the map, 1 to 7 choose a weapon, Escape opens
;; the menu.  C-c C-q quits the game; C-x and M-x work as anywhere.  The
;; game stops while its buffer is not shown, or Emacs is not in front.
;;
;; It runs in Emacs 32, which LispM's experimental install has: in Emacs
;; 30 and 31 M-x lispm-doom says so and runs nothing.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'lispm-doom-engine)

;; Defined only in an Emacs built with a window system.
(declare-function image-flush "image.c" (spec &optional frame))


(defconst lispm-doom-emacs-version 32
  "The first major version of Emacs lispm-doom runs in.")

(defcustom lispm-doom-iwad nil
  "The game: nil for Freedoom: Phase 1, downloaded the first time, or an
IWAD file of your own, as doom.wad or doom2.wad."
  :type '(choice (const :tag "Freedoom: Phase 1" nil) file)
  :group 'lispm-doom)

(defcustom lispm-doom-resolution "320x200"
  "The resolution the game draws at, WIDTHxHEIGHT; 320x200 and 640x400 are
stretched to 4:3, as on a CRT.  Emacs on macOS copies a frame's pixels one
at a time: at 320x200, Doom's own, a frame takes it about 10 ms, at
640x400 four times as long, more than a frame has.  Scaling the frames
up, see `lispm-doom-scale', costs next to nothing."
  :type 'string :group 'lispm-doom)

(defcustom lispm-doom-scale nil
  "How many times the frames are scaled up: nil to fill the game's window,
keeping their shape, or a number, as 3."
  :type '(choice (const :tag "Fill the window" nil) number)
  :group 'lispm-doom)

(defcustom lispm-doom-directory (locate-user-emacs-file "lispm-doom/")
  "Where lispm-doom keeps Freedoom, the game's settings and its saves."
  :type 'directory :group 'lispm-doom)

(defcustom lispm-doom-frame-rate 35
  "How many frames a second the game draws, at most.  35 is Doom's own,
the rate of its tics; above it, frames are drawn between tics.  Each
frame shown takes Emacs about 10 ms at 320x200."
  :type 'natnum :group 'lispm-doom)

(defcustom lispm-doom-arguments nil
  "More arguments for the engine, dsda-doom's, as (\"-nosound\") or
(\"-skill\" \"4\")."
  :type '(repeat string) :group 'lispm-doom)

(defcustom lispm-doom-release-delay '(0.5 . 0.12)
  "How long a key counts as held after Emacs last heard it: (FIRST . NEXT).
FIRST, after it was pressed, outlasts the keyboard's wait before it
repeats; NEXT, after a repeat, the time between repeats."
  :type '(cons number number) :group 'lispm-doom)

(defconst lispm-doom-freedoom
  '(:url "https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip"
    :sha256 "3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59"
    :directory "freedoom-0.13.0"
    :files (("freedoom1.wad" . "7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d")
            ("freedoom2.wad" . "a8772e088847032510d97ba2312406a6998f21cbab44d4ff10696faa9c0ecd4b")
            ("COPYING.txt" . nil)))
  "Freedoom 0.13.0, as its signed checksums list it: the archive, and the
WADs in it.  Freedoom is under the BSD 3-clause licence, in COPYING.txt.")

(define-error 'lispm-doom-unsupported "Doom cannot run here")

(defvar lispm-doom--process nil
  "The engine, while a game runs.")

(defvar lispm-doom--image nil
  "The image spec the frames are shown as.")

(defvar lispm-doom--size nil
  "The frames' size, (WIDTH . HEIGHT) in pixels.")

(defvar lispm-doom--frames nil
  "The directory the engine writes the frames in.")

(defvar lispm-doom--held nil
  "The keys held, an alist of a Doom key and the timer releasing it.")

(defvar lispm-doom--watch nil
  "The timer stopping the game while it is not seen, and going on after.")

(defvar lispm-doom--stopped nil
  "Non-nil while the engine is stopped.")

(defvar lispm-doom--getting nil
  "Non-nil while the engine or Freedoom is got for a game to start.")

(defconst lispm-doom-buffer-name "*Doom*"
  "The game's buffer.")

(defvar lispm-doom-ended-map)

;;;; Whether it can

(defun lispm-doom-unsupported-reason ()
  "Return why Doom cannot run in this Emacs, a sentence, or nil when it
can."
  (cond ((< emacs-major-version lispm-doom-emacs-version)
         (format "lispm-doom needs Emacs %d or later; this is Emacs %s"
                 lispm-doom-emacs-version emacs-version))
        ((not (image-type-available-p 'pbm))
         "this Emacs shows no PPM images, which the game's frames are")
        ((not (lispm-prebuilt-target 'lispm-doom-engine))
         (format "lispm-doom's engine runs on macOS, not on %s" system-configuration))))

(defun lispm-doom-supported-p ()
  "Return non-nil when Doom can run in this Emacs."
  (not (lispm-doom-unsupported-reason)))

;;;; Freedoom

(defun lispm-doom--freedoom-directory ()
  "Return where Freedoom is kept."
  (expand-file-name "freedoom" lispm-doom-directory))

(defun lispm-doom--freedoom-complete-p ()
  "Return non-nil when Freedoom's files are there, the WADs checked."
  (let ((directory (lispm-doom--freedoom-directory)))
    (seq-every-p (lambda (file)
                   (let ((path (expand-file-name (car file) directory)))
                     (and (file-readable-p path)
                          (or (null (cdr file)) (equal (lispm-prebuilt-sha256 path) (cdr file))))))
                 (plist-get lispm-doom-freedoom :files))))

(defun lispm-doom-freedoom-get (callback)
  "Get Freedoom: Phase 1's WAD, then call CALLBACK with it and nil, or with
nil and why there is none.  When it is not there, Freedoom is downloaded
first, in the background, Emacs not waiting, and checked against its
signed checksums."
  (let ((directory (lispm-doom--freedoom-directory)))
    (cond
     ((lispm-doom--freedoom-complete-p)
      (funcall callback (expand-file-name "freedoom1.wad" directory) nil))
     ((not (and (executable-find "curl") (executable-find "unzip")))
      (funcall callback nil "Downloading Freedoom needs curl and unzip"))
     (t
      (let* ((temporary (make-temp-file "lispm-doom-freedoom" t))
             (archive (expand-file-name "freedoom.zip" temporary)))
        (cl-flet ((done (why)
                    (delete-directory temporary t)
                    (if why
                        (funcall callback nil why)
                      (message "Downloading Freedoom…done")
                      (funcall callback (expand-file-name "freedoom1.wad" directory) nil))))
          (message "Downloading Freedoom (24 MB)…")
          (lispm-prebuilt-fetch
           (plist-get lispm-doom-freedoom :url) archive
           (lambda (why)
             (cond
              (why (done why))
              ((not (equal (lispm-prebuilt-sha256 archive) (plist-get lispm-doom-freedoom :sha256)))
               (done "The Freedoom downloaded is not Freedoom 0.13.0: its SHA-256 differs, so it was refused"))
              (t
               (make-directory directory t)
               (lispm-prebuilt-run
                "unzip" (append (list "-o" "-j" archive)
                                (mapcar (lambda (file)
                                          (concat (plist-get lispm-doom-freedoom :directory) "/" (car file)))
                                        (plist-get lispm-doom-freedoom :files))
                                (list "-d" directory))
                (lambda (exit _said)
                  (done (cond ((not (eql exit 0)) "Freedoom could not be unpacked")
                              ((not (lispm-doom--freedoom-complete-p))
                               "Freedoom's WADs are not the ones its checksums list")))))))))))))))

;;;; The engine's settings

(defconst lispm-doom-settings
  "videomode                       \"OpenGL\"
use_mouse                       0
show_endoom                     0
autorun                         1
input_forward                   119,173 -1 -1 | 119,173 -1 -1 | 119,173 -1 -1
input_backward                  115,175 -1 -1 | 115,175 -1 -1 | 115,175 -1 -1
input_turnleft                  113,172 -1 -1 | 113,172 -1 -1 | 113,172 -1 -1
input_turnright                 101,174 -1 -1 | 101,174 -1 -1 | 101,174 -1 -1
input_strafeleft                97 -1 -1 | 97 -1 -1 | 97 -1 -1
input_straferight               100 -1 -1 | 100 -1 -1 | 100 -1 -1
input_fire                      102,106 -1 -1 | 102,106 -1 -1 | 102,106 -1 -1
input_use                       32 -1 -1 | 32 -1 -1 | 32 -1 -1
input_menu_up                   173,119 -1 -1 | 173,119 -1 -1 | 173,119 -1 -1
input_menu_down                 175,115 -1 -1 | 175,115 -1 -1 | 175,115 -1 -1
"
  "The engine's settings the first time: OpenGL, no mouse, and keys an
Emacs can send, Control and Shift alone being none.  The engine keeps
what is changed from its menus.")

(defun lispm-doom--setting (key value)
  "Make the settings in the current buffer set KEY to VALUE, a string."
  (goto-char (point-min))
  (if (re-search-forward (concat "^" (regexp-quote key) "[ \t].*$") nil t)
      (replace-match (format "%-31s %s" key value) t t)
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (insert (format "%-31s %s\n" key value))))

(defun lispm-doom--settings-file ()
  "Return the engine's settings file, writing it the first time; its
frame rate is `lispm-doom-frame-rate' each time."
  (let ((file (expand-file-name "lispm-doom.cfg" lispm-doom-directory))
        (rate (max 1 lispm-doom-frame-rate)))
    (unless (file-exists-p file)
      (make-directory lispm-doom-directory t)
      (with-temp-file file
        (insert lispm-doom-settings)))
    ;; Unlimited, the engine draws hundreds of frames a second, each one
    ;; Emacs has to show.
    (with-temp-file file
      (insert-file-contents file)
      (lispm-doom--setting "uncapped_framerate" (if (> rate 35) "1" "0"))
      (lispm-doom--setting "dsda_fps_limit" (number-to-string rate)))
    file))

(defun lispm-doom--arguments (iwad)
  "Return the engine's arguments to play IWAD."
  (let ((data (expand-file-name "data" lispm-doom-directory)))
    (make-directory data t)
    (apply #'list "-iwad" (expand-file-name iwad)
          "-config" (lispm-doom--settings-file)
          "-data" data
          "-vidmode" "gl"
          "-geom" (concat lispm-doom-resolution "w")
          "-nomouse"
          lispm-doom-arguments)))

;;;; Frames

(defun lispm-doom--frame-file (index)
  "Return the file of frame INDEX, 0 or 1."
  (expand-file-name (format "frame-%d.ppm" index) lispm-doom--frames))

(defun lispm-doom--scale (width height)
  "Return how many times frames WIDTH by HEIGHT pixels are scaled up:
`lispm-doom-scale', or as many times as they fit the game's window, to a
hundredth, keeping their shape."
  (or lispm-doom-scale
      (if-let* ((window (get-buffer-window lispm-doom-buffer-name t)))
          (max 0.25 (/ (floor (* 100 (min (/ (float (window-body-width window t)) width)
                                          (/ (float (window-body-height window t)) height))))
                       100.0))
        1.0)))

(defun lispm-doom--rescale (&rest _)
  "Scale the frames to the game's window again, when it changed size."
  (when lispm-doom--image
    (let* ((props (cdr lispm-doom--image))
           (scale (lispm-doom--scale (car lispm-doom--size) (cdr lispm-doom--size))))
      (unless (equal scale (plist-get props :scale))
        (plist-put props :scale scale)
        (when-let* ((buffer (get-buffer lispm-doom-buffer-name)))
          (force-window-update buffer))))))

(defun lispm-doom--show (width height)
  "Show frames WIDTH by HEIGHT pixels in the game's buffer from now on.
The image's spec is the buffer's display property itself: each frame
changes the file it names, and its scale follows the window."
  (setq lispm-doom--size (cons width height)
        lispm-doom--image (list 'image :type 'pbm
                                :file (lispm-doom--frame-file 0)
                                :scale (lispm-doom--scale width height)))
  (when-let* ((buffer (get-buffer lispm-doom-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        ;; Centred: the space reaches to half the image's width left of
        ;; the middle, however it is scaled.
        (insert (propertize " " 'display `(space :align-to (- center (0.5 . ,lispm-doom--image)))))
        (let ((start (point)))
          (insert "[Doom]")
          (add-text-properties start (point) `(display ,lispm-doom--image rear-nonsticky t)))
        (goto-char (point-max))))))

(defun lispm-doom--frame (index)
  "Show frame INDEX the engine has written, scaled to the window as it is
now: a frame costs a comparison, and no change of the window's size is
missed, however it came.  Emacs keeps the image of each file it read:
the one read last of this file, two frames ago, goes first."
  (when lispm-doom--image
    (lispm-doom--rescale)
    (plist-put (cdr lispm-doom--image) :file (lispm-doom--frame-file index))
    (image-flush lispm-doom--image t)
    (when-let* ((buffer (get-buffer lispm-doom-buffer-name)))
      (force-window-update buffer))))

(defun lispm-doom--hear (line)
  "Act on LINE the engine said."
  (pcase (split-string line " ")
    (`("lispm-doom" "size" ,width ,height)
     (lispm-doom--show (string-to-number width) (string-to-number height)))
    (`("lispm-doom" "frame" ,index)
     (lispm-doom--frame (string-to-number index)))))

(defun lispm-doom--filter (process output)
  "Take OUTPUT of the engine, PROCESS, a line at a time.  Of the frames it
tells of, only the last is shown: the others are past already."
  (let ((lines (split-string (concat (or (process-get process 'pending) "") output) "\n"))
        (frame nil))
    (process-put process 'pending (car (last lines)))
    (dolist (line (butlast lines))
      (if (string-prefix-p "lispm-doom frame " line)
          (setq frame line)
        (when frame
          (lispm-doom--hear frame)
          (setq frame nil))
        (lispm-doom--hear line)))
    (when frame
      (lispm-doom--hear frame))))

(defun lispm-doom--log ()
  "Return the buffer of what the engine prints."
  (get-buffer-create " *lispm-doom log*"))

(defun lispm-doom--why-ended ()
  "Return why the engine ended, from what it printed, or nil."
  (with-current-buffer (lispm-doom--log)
    (save-excursion
      (goto-char (point-max))
      (cond ((re-search-backward "Library not loaded: .*/\\([^/]+\\)/lib/" nil t)
             (format "Homebrew's %s is missing; LispM's App Store installs it with lispm-doom"
                     (match-string 1)))
            ((re-search-backward "^\\(?:I_Error\\|Error\\): *\\(.+\\)$" nil t)
             (match-string 1))))))

(defun lispm-doom--ended (buffer)
  "Say in the game's BUFFER that the game has ended, in place of its
frame, before the frames go.  The frame fills the game's window: text
under it, and point there, would be out of sight, and Emacs, never
showing point, redisplays the window without end, answering nothing."
  (setq lispm-doom--image nil)
  (with-current-buffer buffer
    (lispm-doom--say "The game has ended.  g plays again, q buries this buffer.")
    (use-local-map lispm-doom-ended-map)))

(defun lispm-doom--sentinel (process _event)
  "Clean up once the engine, PROCESS, has ended."
  (unless (process-live-p process)
    (when (eq process lispm-doom--process)
      (setq lispm-doom--process nil)
      (lispm-doom--release-all)
      (when (timerp lispm-doom--watch)
        (cancel-timer lispm-doom--watch))
      (setq lispm-doom--watch nil lispm-doom--stopped nil)
      (when-let* ((buffer (get-buffer lispm-doom-buffer-name)))
        (lispm-doom--ended buffer))
      (when (and lispm-doom--frames (file-directory-p lispm-doom--frames))
        (delete-directory lispm-doom--frames t))
      (setq lispm-doom--frames nil)
      (let ((status (process-exit-status process)))
        (unless (zerop status)
          (message "lispm-doom ended: %s" (or (lispm-doom--why-ended)
                                              (format "exit %d; see %s" status (buffer-name (lispm-doom--log))))))))))

;;;; Keys

(defun lispm-doom--doom-key (event)
  "Return the Doom key EVENT stands for, or nil."
  (let ((base (event-basic-type event))
        (modifiers (event-modifiers event)))
    ;; Return, Tab and Escape are control characters, C-m, C-i and C-[.
    (cond ((and (integerp event) (memq event '(13 9 27 127 32))) event)
          ((seq-intersection modifiers '(control meta super hyper alt)) nil)
          ((and (integerp base) (<= 33 base 126)) (downcase base))
          ((symbolp base)
           (pcase base
             ('up #xad) ('down #xaf) ('left #xac) ('right #xae)
             ('return 13) ('tab 9) ('escape 27) ('backspace 127) ('delete #xc8)
             ('home #xc7) ('end #xcf) ('prior #xc9) ('next #xd1) ('insert #xd2)
             ('pause #xff)
             ('f1 #xbb) ('f2 #xbc) ('f3 #xbd) ('f4 #xbe) ('f5 #xbf) ('f6 #xc0)
             ('f7 #xc1) ('f8 #xc2) ('f9 #xc3) ('f10 #xc4) ('f11 #xd7) ('f12 #xd8))))))

(defun lispm-doom--send (string)
  "Send STRING to the engine, when it runs."
  (when (process-live-p lispm-doom--process)
    (process-send-string lispm-doom--process string)))

(defun lispm-doom--release (key)
  "Tell the engine KEY was released."
  (setq lispm-doom--held (assq-delete-all key lispm-doom--held))
  (lispm-doom--send (format "u %d\n" key)))

(defun lispm-doom--release-all ()
  "Release every key held."
  (dolist (entry lispm-doom--held)
    (when (timerp (cdr entry))
      (cancel-timer (cdr entry)))
    (lispm-doom--send (format "u %d\n" (car entry))))
  (setq lispm-doom--held nil))

(defun lispm-doom--press (key)
  "Tell the engine KEY is pressed, or still held, and when Emacs has not
heard it again for a moment, that it was released."
  (let ((entry (assq key lispm-doom--held)))
    (if entry
        (cancel-timer (cdr entry))
      (lispm-doom--send (format "d %d\n" key)))
    (let ((timer (run-at-time (if entry (cdr lispm-doom-release-delay) (car lispm-doom-release-delay))
                              nil #'lispm-doom--release key)))
      (if entry
          (setcdr entry timer)
        (push (cons key timer) lispm-doom--held)))))

(defun lispm-doom-key ()
  "Send the key typed to the game."
  (interactive)
  (when-let* ((key (lispm-doom--doom-key last-input-event)))
    (lispm-doom--press key)))

;;;; Stopping it while it is not seen

(defun lispm-doom--seen-p ()
  "Return non-nil when the game's buffer is shown in a frame in front."
  (when-let* ((buffer (get-buffer lispm-doom-buffer-name)))
    (seq-some (lambda (window)
                (eq (frame-focus-state (window-frame window)) t))
              (get-buffer-window-list buffer nil t))))

(defun lispm-doom--watch ()
  "Stop the engine while its game is not seen; go on once it is."
  (when (process-live-p lispm-doom--process)
    (let ((seen (lispm-doom--seen-p)))
      (cond ((and seen lispm-doom--stopped)
             (signal-process lispm-doom--process 'SIGCONT)
             (setq lispm-doom--stopped nil))
            ((and (not seen) (not lispm-doom--stopped))
             (lispm-doom--release-all)
             (signal-process lispm-doom--process 'SIGSTOP)
             (setq lispm-doom--stopped t))))))

;;;; The game

(defun lispm-doom-quit ()
  "End the game."
  (interactive)
  (when (process-live-p lispm-doom--process)
    (when lispm-doom--stopped
      (signal-process lispm-doom--process 'SIGCONT)
      (setq lispm-doom--stopped nil))
    (lispm-doom--send "q\n")
    (let ((process lispm-doom--process))
      (run-at-time 2 nil (lambda () (when (process-live-p process) (delete-process process)))))))

(defun lispm-doom--buffer-killed ()
  "End the game with its buffer."
  (lispm-doom-quit))

(defvar lispm-doom-mode-map
  (let ((map (make-sparse-keymap)))
    ;; The default binding takes every key no other binding of this map
    ;; does; the map has no parent, whose bindings would come first.
    (define-key map [t] #'lispm-doom-key)
    (keymap-set map "C-x" ctl-x-map)
    (keymap-set map "M-x" #'execute-extended-command)
    (keymap-set map "C-g" #'keyboard-quit)
    (keymap-set map "C-c C-q" #'lispm-doom-quit)
    map)
  "Keymap of the game's buffer: every key goes to the game, but C-x, M-x
and C-c C-q.")

(defvar-keymap lispm-doom-ended-map
  :doc "Keymap of the game's buffer once the game has ended."
  :parent special-mode-map
  "g" #'lispm-doom
  "q" #'quit-window)

(declare-function evil-set-initial-state "ext:evil-core" (mode state))

(define-derived-mode lispm-doom-mode nil "Doom"
  "Major mode of the game's buffer: Doom, every key going to it."
  (setq-local cursor-type nil
              cursor-in-non-selected-windows nil
              buffer-read-only t
              mode-line-process '(:eval (and lispm-doom--stopped " stopped")))
  ;; Vim's keys would take the game's.
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'lispm-doom-mode 'emacs))
  (add-hook 'kill-buffer-hook #'lispm-doom--buffer-killed nil t)
  (add-hook 'window-size-change-functions #'lispm-doom--rescale nil t))

;;;###autoload
(defun lispm-doom ()
  "Play Doom in a buffer: Freedoom, or `lispm-doom-iwad'.
The engine, and Freedoom, are downloaded first when they are not there,
in the background: the buffer says so meanwhile, and Emacs does not wait."
  (interactive)
  (when-let* ((reason (lispm-doom-unsupported-reason)))
    (user-error "%s" reason))
  (unless (display-graphic-p)
    (user-error "lispm-doom shows its game on a graphical display only"))
  (let ((buffer (get-buffer-create lispm-doom-buffer-name)))
    (unless (or (process-live-p lispm-doom--process) lispm-doom--getting)
      (with-current-buffer buffer
        (lispm-doom-mode)
        (lispm-doom--say "Starting Doom…"))
      (setq lispm-doom--getting t)
      (lispm-doom-engine-get
       (lambda (engine why)
         (cond (why (lispm-doom--not-started buffer why))
               (lispm-doom-iwad (lispm-doom--play buffer engine lispm-doom-iwad))
               (t (unless (lispm-doom--freedoom-complete-p)
                    (lispm-doom--say "Downloading Freedoom (24 MB)…" buffer))
                  (lispm-doom-freedoom-get
                   (lambda (iwad why)
                     (if why
                         (lispm-doom--not-started buffer why)
                       (lispm-doom--play buffer engine iwad)))))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'lispm-doom-mode)
        (lispm-doom-mode)))
    (pop-to-buffer-same-window buffer)
    (lispm-doom--rescale)))

(defun lispm-doom--say (text &optional buffer)
  "Show TEXT alone in the game's BUFFER, by default the current one."
  (with-current-buffer (or buffer (current-buffer))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "\n" text "\n"))))

(defun lispm-doom--not-started (buffer why)
  "Say in the game's BUFFER, and in the echo area, WHY the game did not start."
  (setq lispm-doom--getting nil)
  (when (buffer-live-p buffer)
    (lispm-doom--say (format "Doom could not start: %s" why) buffer))
  (message "Doom could not start: %s" why))

(defun lispm-doom--play (buffer engine iwad)
  "Start ENGINE playing IWAD in the game's BUFFER, unless it is gone or a
game runs."
  (setq lispm-doom--getting nil)
  (cond ((not (buffer-live-p buffer)))
        ((process-live-p lispm-doom--process))
        ((not (file-readable-p iwad))
         (lispm-doom--not-started buffer (format "no IWAD at %s" iwad)))
        (t (with-current-buffer buffer
             (lispm-doom--say "Starting Doom…")
             (lispm-doom--start engine iwad))
           (setq lispm-doom--watch (run-at-time 0.5 0.5 #'lispm-doom--watch)))))

(defun lispm-doom--start (engine iwad)
  "Run ENGINE playing IWAD, its frames shown in the game's buffer; return
the process."
  (let* ((frames (make-temp-file "lispm-doom-frames" t))
         (process-environment (cons (concat "LISPM_DOOM_FRAMES=" frames) process-environment)))
    (with-current-buffer (lispm-doom--log) (erase-buffer))
    (setq lispm-doom--frames frames
          lispm-doom--image nil
          lispm-doom--stopped nil
          lispm-doom--process
          (make-process :name "lispm-doom" :buffer nil :noquery t
                        :command (cons engine (lispm-doom--arguments iwad))
                        :connection-type 'pipe
                        :stderr (lispm-doom--log)
                        :filter #'lispm-doom--filter
                        :sentinel #'lispm-doom--sentinel))))

(provide 'lispm-doom)
;;; lispm-doom.el ends here
