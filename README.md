# lispm-doom

Doom in an Emacs buffer, drawn with OpenGL: [dsda-doom](https://github.com/dsda-org/dsda-doom),
its window an Emacs buffer, playing [Freedoom](https://freedoom.github.io), with sound
and music. For [LispM](https://lispm.ai), whose App Store installs it.

`M-x lispm-doom` starts the game. W A S D or the arrows move, Q and E turn, F or J fires, Space
opens doors, Tab shows the map, 1 to 7 choose a weapon, Escape opens the menu; `C-c C-q` quits,
and `C-x` and `M-x` work as anywhere. The game stops while its buffer is not shown or Emacs is
not in front.

## How it works

The engine is dsda-doom 0.30.1 (`vendor/dsda-doom`, a submodule pinned to the release) with its
SDL window replaced by [engine/](engine/): it runs as a process of Emacs's, and its OpenGL renderer
draws in a context of OpenGL 2.1's legacy profile into a framebuffer object that stands for the
window. Each frame goes to Emacs as a PPM file, two files taking turns, which Emacs shows as an
image filling the window and reloads on each frame the engine announces; the keys go back on
the engine's standard input. A crash of the engine never takes Emacs with it. (A canvas image
would be cheaper, but Emacs on macOS drops a canvas's scale whenever it is refreshed.)

The game draws at Doom's own 320x200, stretched to 4:3 and scaled up to fill the window, at 35
frames a second (`lispm-doom-resolution`, `lispm-doom-scale`, `lispm-doom-frame-rate`): Emacs on
macOS copies a frame's pixels one at a time, about 10 ms a frame at 320x200, while scaling costs
next to nothing.

Emacs tells of keys pressed and repeated, never of keys released: a key counts as held until it
has not repeated for a moment (`lispm-doom-release-delay`).

## Emacs 32 only

In Emacs 30 and 31 `M-x lispm-doom` says it needs Emacs 32 and runs nothing, and LispM's App
Store lists lispm-doom as needing Emacs 32. LispM's Kernel panel switches LispM to
Emacs 32, or install the experimental LispM:

```sh
curl -fsSL https://lispm.ai/install.sh | LISPM_EMACS=32 sh
```

## The engine and the game

Nobody has to build the engine. The one the `engine` workflow built for your Mac from these
sources is downloaded the first time, and kept only when its SHA-256 is the one
`lisp/lispm-doom-engine-sums.eld` pins. It links with Homebrew's `sdl2_mixer`, `libsndfile`
and `libzip`, which LispM's App Store installs with it. Set `lispm-doom-engine-source` to
`build` to build it yourself (CMake, Xcode's command line tools and those formulas).

Freedoom 0.13.0 is downloaded the first time and checked against its signed checksums;
`lispm-doom-iwad` names another IWAD, as your own `doom.wad`.

```sh
git submodule update --init
make            # build the engine, build/lispm-doom-engine
make test       # with LISPM_DOOM_IWAD naming freedoom1.wad, the engine plays into a buffer
make compile    # byte-compile, warnings failing it
```

## License

lispm-doom is under the GNU Affero General Public License, version 3 or later
([LICENSE](LICENSE)). dsda-doom is under the GNU General Public License, version 2 or later;
the engine, dsda-doom and engine/ together, is under the AGPL, version 3 or later. Freedoom is
under the BSD 3-clause licence, kept with it as COPYING.txt.
