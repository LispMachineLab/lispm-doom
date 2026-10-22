;;; lispm-doom-engine.el --- lispm-doom's engine, downloaded and checked -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
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

;; The game is dsda-doom, built with its window an Emacs buffer (see
;; engine/), as a program Emacs runs, and nobody has to build it.  The
;; engine the repository's engine workflow built for this computer from
;; these sources is downloaded, and kept only when its SHA-256 is the one
;; pinned beside this file, in lispm-doom-engine-sums.eld: those checksums
;; come with the Lisp, from the repository's signed history.
;;
;; CMake builds it only when asked to:
;; `lispm-doom-engine-source' set to `build' builds it with
;; scripts/build-engine.sh, and again when one of its sources is newer.
;;
;;   download   engine/prebuilt/VERSION/   the default
;;   build      build/
;;
;; Either holds lispm-doom-engine and dsda-doom.wad, the engine's own
;; data.  VERSION is `lispm-doom-engine-source-version', a digest of the
;; engine's sources, which name the release of dsda-doom it is made of
;; (engine/DSDA).  The workflow publishes the engines of each version as
;; the release engine-VERSION, a tar.gz for each computer;
;; `lispm-doom-engine-batch-pin' writes their SHA-256 here, in the release
;; of lispm-doom that ships them.
;;
;; The engine links with SDL2, SDL2_mixer, libsndfile and libzip, as
;; Homebrew has them: LispM's App Store installs those first.

;;; Code:

(require 'seq)
(require 'subr-x)

(defgroup lispm-doom nil
  "Doom, in an Emacs buffer, drawn with OpenGL."
  :group 'games
  :prefix "lispm-doom-")

(defcustom lispm-doom-engine-source 'download
  "Where lispm-doom's engine comes from.
`download', the default, downloads the engine the repository's workflow
built for this computer from these sources, and keeps it only when its
SHA-256 is the one pinned in lispm-doom-engine-sums.eld.  `build' builds
it with CMake instead, from the sources there are, and again when one is
newer than the engine CMake built; nothing is downloaded then."
  :type '(choice (const :tag "Download it, checked" download)
                 (const :tag "Build it with CMake" build))
  :group 'lispm-doom)

(defcustom lispm-doom-engine-prebuilt-url
  "https://github.com/LispMachineLab/lispm-doom/releases/download"
  "Where the prebuilt engines are.
The engines of the sources whose version is VERSION, see
`lispm-doom-engine-source-version', are under engine-VERSION there:
lispm-doom-engine-TARGET.tar.gz for each TARGET.  Whatever the URL, an
engine is kept only when its SHA-256 is the one
lispm-doom-engine-sums.eld pins."
  :type 'string :group 'lispm-doom)

(defconst lispm-doom-engine-lisp-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of lispm-doom's Emacs Lisp.")

(defconst lispm-doom-engine-root
  (file-name-directory (directory-file-name lispm-doom-engine-lisp-directory))
  "Root of lispm-doom's repository.")

(defconst lispm-doom-engine-targets '("aarch64-apple-darwin" "x86_64-apple-darwin")
  "The computers an engine is published for.")

;;;; Sources and their version

(defun lispm-doom-engine--source-files ()
  "Return the engine's sources, sorted: the build script, the pin of
dsda-doom's release, and the window that is an Emacs buffer."
  (let ((root lispm-doom-engine-root))
    (sort (seq-filter
           #'file-regular-p
           (append (list (expand-file-name "scripts/build-engine.sh" root)
                         (expand-file-name "engine/DSDA" root))
                   (and (file-directory-p (expand-file-name "engine" root))
                        (directory-files (expand-file-name "engine" root) t "\\.[ch]\\'"))))
          #'string<)))

(defun lispm-doom-engine--sha256 (file)
  "Return the SHA-256 of FILE's bytes, in hex."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun lispm-doom-engine-source-version ()
  "Return the version of the engine's sources, or nil without them: the
first 16 digits of the SHA-256 of what sha256sum writes for them at the
repository's root."
  (when-let* ((files (lispm-doom-engine--source-files)))
    (substring (secure-hash 'sha256
                            (mapconcat (lambda (file)
                                         (format "%s  %s\n" (lispm-doom-engine--sha256 file)
                                                 (file-relative-name file lispm-doom-engine-root)))
                                       files ""))
               0 16)))

;;;; Pinned checksums

(defun lispm-doom-engine--sums-file ()
  "Return the file pinning the SHA-256 of the engines to download."
  (expand-file-name "lispm-doom-engine-sums.eld" lispm-doom-engine-lisp-directory))

(defun lispm-doom-engine--pins ()
  "Return what lispm-doom-engine-sums.eld pins: a plist whose :version is
the version of the sources pinned and :engines an alist of a SHA-256 for
each target; nil when nothing is pinned."
  (let ((file (lispm-doom-engine--sums-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((pins (ignore-errors (read (current-buffer)))))
          (and (listp pins) pins))))))

(defun lispm-doom-engine--pinned-sha256 (&optional target)
  "Return the SHA-256 pinned for the engine of these sources for TARGET,
by default this computer's, or nil when none is pinned for them."
  (when-let* ((target (or target (lispm-doom-engine--target)))
              (version (lispm-doom-engine-source-version))
              (pins (lispm-doom-engine--pins))
              ((equal (plist-get pins :version) version))
              (sha256 (cdr (assoc target (plist-get pins :engines)))))
    (and (stringp sha256) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256) sha256)))

;;;; Engines

(defun lispm-doom-engine--target (&optional configuration)
  "Return the target of the prebuilt engine for a computer Emacs was built
for as CONFIGURATION, by default this one's `system-configuration', or nil
when none is published for it."
  (let ((configuration (or configuration system-configuration)))
    (cond ((string-match-p "\\`\\(?:aarch64\\|arm64\\)-apple-darwin" configuration) "aarch64-apple-darwin")
          ((string-match-p "\\`x86_64-apple-darwin" configuration) "x86_64-apple-darwin"))))

(defun lispm-doom-engine--asset (target)
  "Return the name the engine for TARGET is published under."
  (format "lispm-doom-engine-%s.tar.gz" target))

(defun lispm-doom-engine--built-directory ()
  "Return where scripts/build-engine.sh builds the engine."
  (expand-file-name "build" lispm-doom-engine-root))

(defun lispm-doom-engine--prebuilt-directory (&optional version)
  "Return where the engine downloaded for VERSION, by default these
sources', is kept, or nil without sources."
  (when-let* ((version (or version (lispm-doom-engine-source-version))))
    (expand-file-name version (expand-file-name "engine/prebuilt" lispm-doom-engine-root))))

(defun lispm-doom-engine--complete-p (directory)
  "Return non-nil when DIRECTORY holds an engine and its data."
  (and directory
       (file-executable-p (expand-file-name "lispm-doom-engine" directory))
       (file-readable-p (expand-file-name "dsda-doom.wad" directory))))

(defun lispm-doom-engine--stale-p ()
  "Return non-nil when a source is newer than the engine CMake built."
  (let ((engine (expand-file-name "lispm-doom-engine" (lispm-doom-engine--built-directory))))
    (and (file-exists-p engine)
         (seq-some (lambda (file) (file-newer-than-file-p file engine))
                   (lispm-doom-engine--source-files)))))

(defun lispm-doom-engine-file ()
  "Return the engine to run, current for the sources, or nil: when
building, the one CMake built unless a source is newer; else the one
downloaded and checked for them."
  (let ((directory (if (eq lispm-doom-engine-source 'build)
                       (and (not (lispm-doom-engine--stale-p)) (lispm-doom-engine--built-directory))
                     (lispm-doom-engine--prebuilt-directory))))
    (and (lispm-doom-engine--complete-p directory)
         (expand-file-name "lispm-doom-engine" directory))))

(defun lispm-doom-engine-why-not ()
  "Return why no engine can be had, a sentence."
  (let ((version (lispm-doom-engine-source-version)))
    (cond ((not (lispm-doom-engine--target))
           (format "no engine is published for %s" system-configuration))
          ((not version) "the engine's sources, which name the engine to download, are not there")
          ((eq lispm-doom-engine-source 'build)
           (if (executable-find "cmake") "CMake built no engine: see *lispm-doom build*"
             "building the engine needs CMake"))
          ((not (lispm-doom-engine--pinned-sha256))
           (format "no engine is pinned for these sources (version %s); set `lispm-doom-engine-source' to `build' to build one"
                   version))
          ((not (executable-find "curl")) "downloading the engine needs curl")
          (t "no engine is there"))))

;;;; Building, when asked to

(defun lispm-doom-engine-build ()
  "Build the engine with scripts/build-engine.sh, Emacs waiting; return it,
or signal why there is none.  The output is in *lispm-doom build*."
  (interactive)
  (unless (executable-find "cmake")
    (user-error "Building lispm-doom's engine needs CMake"))
  (let ((default-directory (file-name-as-directory lispm-doom-engine-root))
        (buffer (get-buffer-create "*lispm-doom build*")))
    (with-current-buffer buffer (erase-buffer))
    (message "Building lispm-doom's engine (a few minutes the first time)…")
    (unless (and (zerop (call-process "/bin/sh" nil buffer nil "scripts/build-engine.sh"))
                 (lispm-doom-engine--complete-p (lispm-doom-engine--built-directory)))
      (error "The engine could not be built: see %s" (buffer-name buffer)))
    (message "Building lispm-doom's engine…done")
    (expand-file-name "lispm-doom-engine" (lispm-doom-engine--built-directory))))

;;;; Downloading, checked

(defun lispm-doom-engine--fetch (url file)
  "Download URL into FILE with curl, or signal an error."
  (unless (zerop (call-process "curl" nil nil nil "--fail" "--silent" "--show-error" "--location"
                               "--retry" "2" "--max-time" "300" "--output" file url))
    (error "Could not download %s" url)))

(defun lispm-doom-engine-download ()
  "Download the engine built for this computer from the sources there are,
Emacs waiting, check it against the SHA-256 pinned for it, and unpack it;
return it, or signal why there is none."
  (interactive)
  (let ((target (lispm-doom-engine--target))
        (sha256 (lispm-doom-engine--pinned-sha256))
        (directory (lispm-doom-engine--prebuilt-directory)))
    (unless (and target sha256 directory (executable-find "curl"))
      (error "No lispm-doom engine can be downloaded: %s" (lispm-doom-engine-why-not)))
    (let* ((asset (lispm-doom-engine--asset target))
           (url (format "%s/engine-%s/%s" (string-trim-right lispm-doom-engine-prebuilt-url "/+")
                        (lispm-doom-engine-source-version) asset))
           (temporary (make-temp-file "lispm-doom" t))
           (archive (expand-file-name asset temporary))
           (unpacked (expand-file-name "engine" temporary)))
      (unwind-protect
          (progn
            (message "Downloading lispm-doom's engine…")
            (lispm-doom-engine--fetch url archive)
            (unless (equal (lispm-doom-engine--sha256 archive) sha256)
              (error "%s is not the engine pinned for these sources: its SHA-256 differs, so it was refused" asset))
            (make-directory unpacked)
            (unless (zerop (call-process "tar" nil nil nil "-xzf" archive "-C" unpacked))
              (error "%s could not be unpacked" asset))
            (unless (lispm-doom-engine--complete-p unpacked)
              (error "%s holds no engine" asset))
            ;; Renamed into place, so the engine is there whole or not at all;
            ;; the engines of other versions go.
            (let ((parent (file-name-directory (directory-file-name directory))))
              (make-directory parent t)
              (when (file-directory-p directory)
                (delete-directory directory t))
              (rename-file unpacked directory)
              (dolist (old (directory-files parent t "\\`[^.]"))
                (unless (string= (directory-file-name old) (directory-file-name directory))
                  (delete-directory old t))))
            (message "Downloading lispm-doom's engine…done")
            (expand-file-name "lispm-doom-engine" directory))
        (delete-directory temporary t)))))

(defun lispm-doom-engine-ensure ()
  "Return the engine to run, getting it first when it is not there, Emacs
waiting; signal why when it cannot be had."
  (or (lispm-doom-engine-file)
      (if (eq lispm-doom-engine-source 'build)
          (lispm-doom-engine-build)
        (lispm-doom-engine-download))))

;;;; In batch: a workflow's

(defun lispm-doom-engine-published (url version)
  "Return the alist of target and SHA-256 of the release of VERSION under
URL, each engine downloaded and found to be the one its SHA256SUMS lists,
and one there for every target in `lispm-doom-engine-targets'.  Signal an
error otherwise."
  (let* ((release (format "%s/engine-%s/" (string-trim-right url "/+") version))
         (directory (make-temp-file "lispm-doom-pin" t))
         (sums (expand-file-name "SHA256SUMS" directory))
         (engines nil))
    (unwind-protect
        (progn
          (lispm-doom-engine--fetch (concat release "SHA256SUMS") sums)
          (dolist (line (split-string (with-temp-buffer (insert-file-contents sums) (buffer-string))
                                      "\n" t "[ \t\r]+"))
            (unless (string-match "\\`\\([0-9a-f]\\{64\\}\\) [ *]lispm-doom-engine-\\(.+\\)\\.tar\\.gz\\'" line)
              (error "SHA256SUMS of engine-%s lists %S, not an engine" version line))
            (let* ((sha256 (match-string 1 line))
                   (target (match-string 2 line))
                   (file (expand-file-name (lispm-doom-engine--asset target) directory)))
              (lispm-doom-engine--fetch (concat release (lispm-doom-engine--asset target)) file)
              (unless (equal (lispm-doom-engine--sha256 file) sha256)
                (error "%s is not the engine SHA256SUMS lists: refusing to pin it"
                       (lispm-doom-engine--asset target)))
              (push (cons target sha256) engines)))
          (let ((missing (seq-remove (lambda (target) (assoc target engines)) lispm-doom-engine-targets)))
            (when missing
              (error "engine-%s has no engine for %s" version (string-join missing ", "))))
          (sort engines (lambda (a b) (string< (car a) (car b)))))
      (delete-directory directory t))))

(defun lispm-doom-engine-batch-pin ()
  "Pin the published engines of these sources, for Emacs in batch: write
lispm-doom-engine-sums.eld from the release engine-VERSION.  With
LISPM_DOOM_PIN_CHECK set, write nothing and exit with 1 when the file pins
these sources otherwise than the release has them."
  (let ((version (or (lispm-doom-engine-source-version) (error "No sources here")))
        (pins (lispm-doom-engine--pins))
        (file (lispm-doom-engine--sums-file)))
    (condition-case error
        (if (getenv "LISPM_DOOM_PIN_CHECK")
            (cond ((not (equal (plist-get pins :version) version))
                   (message "::notice::%s pins %s, not the sources' %s: pin it once engine-%s is published"
                            (file-name-nondirectory file)
                            (if (plist-get pins :version) (format "engine-%s" (plist-get pins :version)) "nothing")
                            version version))
                  ((equal (lispm-doom-engine-published lispm-doom-engine-prebuilt-url version)
                          (sort (copy-sequence (plist-get pins :engines)) (lambda (a b) (string< (car a) (car b)))))
                   (message "%s pins engine-%s as published" (file-name-nondirectory file) version))
                  (t (error "%s differs from the release engine-%s" (file-name-nondirectory file) version)))
          (let ((engines (lispm-doom-engine-published lispm-doom-engine-prebuilt-url version)))
            (with-temp-file file
              (insert ";;; lispm-doom-engine-sums.eld --- The engines lispm-doom downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each engine of the release engine-VERSION, as published:
;; the engine lispm-doom-engine.el downloads for these sources.  One whose
;; SHA-256 is not the one here is refused.  `lispm-doom-engine-batch-pin'
;; writes it once the engine workflow has published that release.

"
                      (format "(:version %S\n :engines (%s))\n" version
                              (mapconcat (lambda (engine) (format "(%S . %S)" (car engine) (cdr engine)))
                                         engines "\n           ")))))
          (message "%s pins engine-%s" (file-name-nondirectory file) version))
      (error (message "%s" (error-message-string error))
             (kill-emacs 1)))
    (kill-emacs 0)))

(provide 'lispm-doom-engine)
;;; lispm-doom-engine.el ends here
