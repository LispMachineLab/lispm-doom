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
;; engine/), as a program Emacs runs, and nobody has to build it.
;; lispm-prebuilt downloads the engine the repository's engine workflow
;; built for this computer from these sources, in the background, and
;; keeps it only when its SHA-256 is the one pinned beside this file, in
;; lispm-doom-engine-sums.eld: those checksums come with the Lisp, from
;; the repository's signed history.
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

(require 'lispm-prebuilt)

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

(lispm-prebuilt-define 'lispm-doom-engine
  :title "lispm-doom's engine"
  :noun "engine"
  :root lispm-doom-engine-root
  ;; The build script, the pin of dsda-doom's release, and the window
  ;; that is an Emacs buffer.
  :sources '("scripts/build-engine.sh" "engine/DSDA" ("engine" "\\.[ch]\\'" flat))
  :targets lispm-doom-engine-targets
  :url 'lispm-doom-engine-prebuilt-url
  :source 'lispm-doom-engine-source
  :release "engine-%v"
  :asset "lispm-doom-engine-%t.tar.gz"
  :files '("lispm-doom-engine" "dsda-doom.wad")
  :prebuilt (expand-file-name "engine/prebuilt" lispm-doom-engine-root)
  :sums (expand-file-name "lispm-doom-engine-sums.eld" lispm-doom-engine-lisp-directory)
  :key :engines
  :build '("/bin/sh" "scripts/build-engine.sh")
  :build-needs "cmake"
  :built "build/lispm-doom-engine"
  :pin-check "LISPM_DOOM_PIN_CHECK")

(defun lispm-doom-engine-source-version ()
  "Return the version of the engine's sources, or nil without them: the
first 16 digits of the SHA-256 of what sha256sum writes for them at the
repository's root."
  (lispm-prebuilt-source-version 'lispm-doom-engine))

(defun lispm-doom-engine-file ()
  "Return the engine to run, current for the sources, or nil: when
building, the one CMake built unless a source is newer; else the one
downloaded and checked for them."
  (lispm-prebuilt-file 'lispm-doom-engine))

(defun lispm-doom-engine-why-not ()
  "Return why no engine can be had, a sentence."
  (lispm-prebuilt-why-not 'lispm-doom-engine))

(defun lispm-doom-engine-build ()
  "Build the engine with scripts/build-engine.sh, Emacs waiting; return it,
or signal why there is none."
  (interactive)
  (message "Building lispm-doom's engine takes a few minutes the first time")
  (lispm-prebuilt-build 'lispm-doom-engine))

(defun lispm-doom-engine-download ()
  "Download the engine built for this computer from the sources there are,
Emacs waiting, check it against the SHA-256 pinned for it, and unpack it;
return it, or signal why there is none."
  (interactive)
  (lispm-prebuilt-download 'lispm-doom-engine))

(defun lispm-doom-engine-get (callback)
  "Get the engine, then call CALLBACK with it and nil, or with nil and why
there is none: at once when it is there, else downloaded in the
background, Emacs not waiting.  See `lispm-prebuilt-get'."
  (lispm-prebuilt-get 'lispm-doom-engine callback))

(defun lispm-doom-engine-ensure ()
  "Return the engine to run, getting it first when it is not there, Emacs
waiting; signal why when it cannot be had."
  (lispm-prebuilt-ensure 'lispm-doom-engine))

(defun lispm-doom-engine-batch-pin ()
  "Pin the published engines of these sources, for Emacs in batch.
See `lispm-prebuilt-batch-pin'; LISPM_DOOM_PIN_CHECK set asks it only
to check the pins against the release."
  (lispm-prebuilt-batch-pin 'lispm-doom-engine))

(provide 'lispm-doom-engine)
;;; lispm-doom-engine.el ends here
