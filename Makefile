# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
#
#   make              build the engine, build/lispm-doom-engine
#   make test         the tests: refusals before Emacs 32, the engine's frames on it
#   make compile      byte-compile the Emacs Lisp, warnings failing it
#   make pin          pin the published engines of these sources
#   make check-pins   check the pins against the release

EMACS ?= emacs
# lispm-prebuilt, which downloads the engine: a checkout beside this one.
LISPM_PREBUILT ?= ../lispm-prebuilt
EMACS_BATCH = $(EMACS) -Q --batch -L lisp -L $(LISPM_PREBUILT)

.PHONY: all engine test compile pin check-pins clean

all: engine

engine:
	sh scripts/build-engine.sh

test:
	$(EMACS_BATCH) -l test/lispm-doom-test.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile lisp/*.el
	/bin/rm -f lisp/*.elc

pin:
	$(EMACS_BATCH) -l lispm-doom-engine -f lispm-doom-engine-batch-pin

check-pins:
	LISPM_DOOM_PIN_CHECK=1 $(EMACS_BATCH) -l lispm-doom-engine -f lispm-doom-engine-batch-pin

clean:
	/bin/rm -rf build
