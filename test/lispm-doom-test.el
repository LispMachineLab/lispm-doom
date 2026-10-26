;;; lispm-doom-test.el --- Tests of lispm-doom -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; On Emacs 30 and 31 these check that lispm-doom refuses, fetching and
;; running nothing.  On Emacs 32 they play: the engine CMake built (make)
;; with the IWAD LISPM_DOOM_IWAD names, as Freedoom's freedoom1.wad; the
;; game's frames must reach the buffer.  Without either they are skipped.

;;; Code:

(require 'ert)
(require 'lispm-doom)

(ert-deftest lispm-doom-refuses-before-emacs-32 ()
  (skip-unless (< emacs-major-version 32))
  (should-not (lispm-doom-supported-p))
  (should (string-match-p "needs Emacs 32" (lispm-doom-unsupported-reason)))
  (cl-letf (((symbol-function 'lispm-prebuilt-get) (lambda (&rest _) (error "The engine was fetched")))
            ((symbol-function 'lispm-doom-freedoom-get) (lambda (&rest _) (error "Freedoom was fetched")))
            ((symbol-function 'make-process) (lambda (&rest _) (error "Something was run"))))
    (should (string-match-p "needs Emacs 32" (cadr (should-error (lispm-doom) :type 'user-error)))))
  (should-not (get-buffer lispm-doom-buffer-name)))

(ert-deftest lispm-doom-keys ()
  (should (eql (lispm-doom--doom-key ?w) ?w))
  (should (eql (lispm-doom--doom-key ?W) ?w))
  (should (eql (lispm-doom--doom-key 'up) #xad))
  (should (eql (lispm-doom--doom-key 'left) #xac))
  (should (eql (lispm-doom--doom-key 27) 27))
  (should (eql (lispm-doom--doom-key 'escape) 27))
  (should (eql (lispm-doom--doom-key 13) 13))
  (should (eql (lispm-doom--doom-key 'return) 13))
  (should (eql (lispm-doom--doom-key 32) 32))
  (should (eql (lispm-doom--doom-key 'f1) #xbb))
  (should-not (lispm-doom--doom-key ?\C-w))
  (should-not (lispm-doom--doom-key ?\M-w))
  (should-not (lispm-doom--doom-key '(mouse-1 nil))))

(ert-deftest lispm-doom-holds-keys-until-they-stop-repeating ()
  (let ((sent nil)
        (lispm-doom--held nil)
        (lispm-doom-release-delay '(0.2 . 0.05)))
    (cl-letf (((symbol-function 'lispm-doom--send) (lambda (string) (push string sent))))
      (lispm-doom--press ?w)
      (lispm-doom--press ?w)
      (should (equal sent '("d 119\n")))
      (let ((deadline (+ (float-time) 2)))
        (while (and lispm-doom--held (< (float-time) deadline))
          (accept-process-output nil 0.02)))
      (should (equal sent '("u 119\n" "d 119\n")))
      (should-not lispm-doom--held))))

(ert-deftest lispm-doom-shows-the-last-frame-told ()
  (let ((shown nil))
    (cl-letf (((symbol-function 'lispm-doom--frame) (lambda (index) (push index shown)))
              ((symbol-function 'lispm-doom--show) (lambda (w h) (push (list w h) shown))))
      (with-temp-buffer
        (let ((process (start-process "sleep" nil "sleep" "5")))
          (unwind-protect
              (progn
                (lispm-doom--filter process "lispm-doom frame 0\nlispm-doom frame 1\nlispm-doom fra")
                (lispm-doom--filter process "me 0\nlispm-doom size 320 240\nlispm-doom frame 1\n")
                (should (equal (nreverse shown) '(1 0 (320 240) 1))))
            (delete-process process)))))))

(ert-deftest lispm-doom-engine-names-its-sources ()
  (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" (lispm-doom-engine-source-version)))
  (should (equal (lispm-prebuilt-target 'lispm-doom-engine "aarch64-apple-darwin25.0.0") "aarch64-apple-darwin"))
  (should-not (lispm-prebuilt-target 'lispm-doom-engine "x86_64-pc-linux-gnu"))
  (should (equal (lispm-prebuilt-asset 'lispm-doom-engine "x86_64-apple-darwin")
                 "lispm-doom-engine-x86_64-apple-darwin.tar.gz"))
  (should (member (expand-file-name "engine/DSDA" lispm-doom-engine-root)
                  (lispm-prebuilt-source-files 'lispm-doom-engine)))
  (let ((system-configuration "aarch64-apple-darwin25.0.0"))
    (should (equal (lispm-prebuilt-prebuilt-file 'lispm-doom-engine)
                   (expand-file-name (format "engine/prebuilt/%s/lispm-doom-engine" (lispm-doom-engine-source-version))
                                     lispm-doom-engine-root)))
    (should (equal (lispm-prebuilt-built-file 'lispm-doom-engine)
                   (expand-file-name "build/lispm-doom-engine" lispm-doom-engine-root))))
  ;; Pinned for these sources, for every computer it is published for.
  (dolist (target lispm-doom-engine-targets)
    (should (lispm-prebuilt-pinned-sha256 'lispm-doom-engine target))))

(ert-deftest lispm-doom-starts-once-it-has-what-it-needs ()
  "The game's buffer says Doom is starting while the engine and Freedoom
come in the background; the game starts once both are there, or the
buffer says why it did not."
  (let ((engine-callback nil) (freedoom-callback nil) (started nil)
        (lispm-doom--getting nil) (lispm-doom--process nil) (lispm-doom-iwad nil)
        (wad (make-temp-file "lispm-doom-test-wad")))
    (unwind-protect
        (cl-letf (((symbol-function 'lispm-doom-unsupported-reason) #'ignore)
                  ((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'lispm-doom-engine-get) (lambda (callback) (setq engine-callback callback)))
                  ((symbol-function 'lispm-doom--freedoom-complete-p) #'ignore)
                  ((symbol-function 'lispm-doom-freedoom-get) (lambda (callback) (setq freedoom-callback callback)))
                  ((symbol-function 'lispm-doom--start) (lambda (engine iwad) (push (list engine iwad) started)))
                  ((symbol-function 'run-at-time) #'ignore))
          (lispm-doom)
          (with-current-buffer lispm-doom-buffer-name
            (should (string-match-p "Starting Doom" (buffer-string))))
          ;; Asked again meanwhile: still one start under way.
          (let ((first engine-callback))
            (lispm-doom)
            (should (eq engine-callback first)))
          (funcall engine-callback "/engine" nil)
          (with-current-buffer lispm-doom-buffer-name
            (should (string-match-p "Downloading Freedoom" (buffer-string))))
          (should-not started)
          (funcall freedoom-callback wad nil)
          (should (equal started (list (list "/engine" wad))))
          (should-not lispm-doom--getting)
          ;; An engine that cannot be had says why.
          (lispm-doom)
          (funcall engine-callback nil "no engine is pinned")
          (with-current-buffer lispm-doom-buffer-name
            (should (string-match-p "could not start: no engine is pinned" (buffer-string))))
          (should-not lispm-doom--getting)
          (should (= (length started) 1)))
      (delete-file wad)
      (when (get-buffer lispm-doom-buffer-name)
        (kill-buffer lispm-doom-buffer-name)))))

(ert-deftest lispm-doom-says-it-ended-in-place-of-the-frame ()
  "Once the engine has ended, by itself as at a demo's end, the game's
buffer says so in place of the frame.  The frame fills the window: text
under it, and point there, would be out of sight, and Emacs, never
showing point, redisplays without end.  Nor does the buffer name the
frames' files, which go."
  (let ((lispm-doom--process nil) (lispm-doom--image nil) (lispm-doom--size nil)
        (lispm-doom--held nil) (lispm-doom--watch nil) (lispm-doom--stopped nil)
        (lispm-doom--frames (make-temp-file "lispm-doom-test-frames" t))
        (frames nil))
    (setq frames lispm-doom--frames)
    (unwind-protect
        (progn
          (with-current-buffer (get-buffer-create lispm-doom-buffer-name)
            (lispm-doom-mode))
          (lispm-doom--show 2 2)
          (let ((coding-system-for-write 'binary))
            (write-region (concat "P6\n2 2\n255\n" (apply #'unibyte-string (make-list 12 200)))
                          nil (lispm-doom--frame-file 1)))
          (plist-put (cdr lispm-doom--image) :file (lispm-doom--frame-file 1))
          (with-current-buffer lispm-doom-buffer-name
            (should (text-property-not-all (point-min) (point-max) 'display nil)))
          (setq lispm-doom--process (make-process :name "lispm-doom-test" :command '("true")
                                                  :noquery t :sentinel #'lispm-doom--sentinel))
          (let ((deadline (+ (float-time) 10)))
            (while (and lispm-doom--process (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should-not lispm-doom--process)
          (should-not lispm-doom--frames)
          (should-not (file-exists-p frames))
          (should-not lispm-doom--image)
          (with-current-buffer lispm-doom-buffer-name
            (should (string-match-p "\\`\nThe game has ended\\." (buffer-string)))
            (should-not (text-property-not-all (point-min) (point-max) 'display nil))
            (should (eq (current-local-map) lispm-doom-ended-map))))
      (when (file-directory-p frames)
        (delete-directory frames t))
      (when (get-buffer lispm-doom-buffer-name)
        (let ((kill-buffer-hook nil)) (kill-buffer lispm-doom-buffer-name))))))

(ert-deftest lispm-doom-writes-its-settings-once ()
  (let ((lispm-doom-directory (make-temp-file "lispm-doom-test" t)))
    (unwind-protect
        (let ((file (lispm-doom--settings-file)))
          (should (string-match-p "videomode +\"OpenGL\"" (with-temp-buffer (insert-file-contents file) (buffer-string))))
          (with-temp-file file (insert "kept 1\ndsda_fps_limit 0\n"))
          (let ((lispm-doom-frame-rate 60))
            (lispm-doom--settings-file))
          ;; What the menus changed stays; the frame rate is the option's.
          (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (should (string-match-p "^kept 1$" text))
            (should (string-match-p "^dsda_fps_limit +60$" text))
            (should (string-match-p "^uncapped_framerate +1$" text))
            (should-not (string-match-p "dsda_fps_limit 0" text)))
          (should (member "-vidmode" (lispm-doom--arguments "/x/doom.wad"))))
      (delete-directory lispm-doom-directory t))))

(ert-deftest lispm-doom-plays-into-the-buffer ()
  "The engine starts, draws with OpenGL, and its frames reach the buffer;
it quits when told."
  (skip-unless (lispm-doom-supported-p))
  (let* ((lispm-doom-engine-source 'build)
         (engine (lispm-doom-engine-file))
         (iwad (getenv "LISPM_DOOM_IWAD"))
         (lispm-doom-directory (make-temp-file "lispm-doom-test" t))
         ;; Nothing is heard from a test.
         (lispm-doom-arguments '("-nosound"))
         (frames 0))
    (skip-unless (and engine iwad (file-readable-p iwad)))
    (unwind-protect
        (cl-letf* ((frame (symbol-function 'lispm-doom--frame))
                   ((symbol-function 'lispm-doom--frame)
                    (lambda (index) (setq frames (1+ frames)) (funcall frame index))))
          (get-buffer-create lispm-doom-buffer-name)
          (let ((process (lispm-doom--start engine iwad))
                (deadline (+ (float-time) 30)))
            (while (and (< frames 20) (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.1))
            (should (>= frames 20))
            ;; Doom's own 320x200, stretched to 4:3, scaled up by Emacs.
            (should (equal lispm-doom--size '(320 . 240)))
            (should (eq (plist-get (cdr lispm-doom--image) :type) 'pbm))
            (should (numberp (plist-get (cdr lispm-doom--image) :scale)))
            ;; The frame shown is no black screen.
            (let ((bytes (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally (plist-get (cdr lispm-doom--image) :file))
                           (buffer-string))))
              (should (string-prefix-p "P6\n320 240\n255\n" bytes))
              (should (= (length bytes) (+ 15 (* 320 240 3))))
              (should (seq-some (lambda (i) (> (aref bytes i) 16)) (number-sequence 15 (1- (length bytes)) 997))))
            (with-current-buffer lispm-doom-buffer-name
              (should (text-property-any (point-min) (point-max) 'display lispm-doom--image)))
            (lispm-doom-quit)
            ;; Until the sentinel has run, after the process is gone.
            (let ((deadline (+ (float-time) 10)))
              (while (and lispm-doom--process (< (float-time) deadline))
                (accept-process-output nil 0.1)))
            (should-not (process-live-p process))
            (should-not lispm-doom--frames)
            ;; The buffer says so in place of the frame.
            (should-not lispm-doom--image)
            (with-current-buffer lispm-doom-buffer-name
              (should (string-match-p "The game has ended" (buffer-string)))
              (should-not (text-property-not-all (point-min) (point-max) 'display nil)))))
      (when (process-live-p lispm-doom--process)
        (delete-process lispm-doom--process))
      (when (get-buffer lispm-doom-buffer-name)
        (let ((kill-buffer-hook nil)) (kill-buffer lispm-doom-buffer-name)))
      (delete-directory lispm-doom-directory t))))

(provide 'lispm-doom-test)
;;; lispm-doom-test.el ends here
