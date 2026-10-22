#!/bin/sh
# build-engine.sh --- build lispm-doom's engine: dsda-doom, its window an
# Emacs buffer
#
# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
#
#   sh scripts/build-engine.sh [BUILD]
#
# dsda-doom's sources (vendor/dsda-doom, a submodule pinned to a release)
# are copied to BUILD/src, by default build/src, with its SDL window
# replaced by engine/: i_video.c, dsda-doom's own with the window taken
# out, and lispm_window.c, the window that is an Emacs buffer.  The
# submodule is left as it is.  dsda-doom's CMake builds the copy, without
# the optional libraries; what it needs is SDL2, SDL2_mixer, libsndfile,
# libzip and zlib.  The engine and dsda-doom.wad end up in BUILD.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${1:-$ROOT/build}
VENDOR=$ROOT/vendor/dsda-doom/prboom2

[ -f "$VENDOR/CMakeLists.txt" ] ||
  { echo "build-engine.sh: no dsda-doom in $VENDOR; run git submodule update --init" >&2; exit 1; }

# The release engine/DSDA names, and no other: the engine's version, and
# its prebuilt engines, are made of that file.
WANTED=$(cut -d' ' -f2 "$ROOT/engine/DSDA")
HAVE=$(git -C "$ROOT/vendor/dsda-doom" rev-parse HEAD)
[ "$WANTED" = "$HAVE" ] ||
  { echo "build-engine.sh: vendor/dsda-doom is at $HAVE, not engine/DSDA's $WANTED" >&2; exit 1; }

mkdir -p "$BUILD/src"
# Copied keeping times, so that make rebuilds only what changed.
rsync -a --delete --exclude /src/SDL/lispm_window.c --exclude /src/SDL/lispm_window.h "$VENDOR/" "$BUILD/src/"

# A file is replaced only when it differs, for the same reason.
put() {
  if ! cmp -s "$1" "$2"; then
    cp "$1" "$2"
  fi
}
put "$ROOT/engine/i_video.c" "$BUILD/src/src/SDL/i_video.c"
put "$ROOT/engine/lispm_window.c" "$BUILD/src/src/SDL/lispm_window.c"
put "$ROOT/engine/lispm_window.h" "$BUILD/src/src/SDL/lispm_window.h"
perl -pe 's|^(\s*)SDL/i_video\.c$|$1SDL/i_video.c\n$1SDL/lispm_window.c|' \
  "$VENDOR/src/CMakeLists.txt" > "$BUILD/cmakelists.tmp"
put "$BUILD/cmakelists.tmp" "$BUILD/src/src/CMakeLists.txt"
rm -f "$BUILD/cmakelists.tmp"

# Homebrew's SDL2 is sdl2-compat, SDL2 on SDL3, which its SDL2_mixer links
# with: the engine must link with the same.
PREFIX=
SDL2_DIR=
if command -v brew >/dev/null 2>&1; then
  PREFIX=$(brew --prefix)
  if [ -d "$PREFIX/opt/sdl2-compat/lib/cmake/SDL2" ]; then
    SDL2_DIR=$PREFIX/opt/sdl2-compat/lib/cmake/SDL2
  fi
fi

cmake -S "$BUILD/src" -B "$BUILD/obj" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}" \
  ${PREFIX:+-DCMAKE_PREFIX_PATH="$PREFIX"} ${SDL2_DIR:+-DSDL2_DIR="$SDL2_DIR"} \
  -DWITH_FLUIDSYNTH=OFF -DWITH_IMAGE=OFF -DWITH_MAD=OFF -DWITH_PORTMIDI=OFF \
  -DWITH_VORBISFILE=OFF -DWITH_XMP=OFF -DENABLE_PACKAGING=OFF >"$BUILD/configure.log"
cmake --build "$BUILD/obj" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

cp "$BUILD/obj/dsda-doom" "$BUILD/lispm-doom-engine"
cp "$BUILD/obj/dsda-doom.wad" "$BUILD/dsda-doom.wad"
echo "$BUILD/lispm-doom-engine"
