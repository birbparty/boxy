version     = "0.7.0"
author      = "Andre von Houck and Ryan Oldenburg"
description = "2D GPU rendering with a tiling atlas."
license     = "MIT"

srcDir = "src"

requires "nim >= 1.2.2"
requires "shady >= 0.1.4"
requires "bitty >= 0.1.4"
requires "windy >= 0.4.4"
# NOTE — Nintendo 3DS (--define:ds3) builds:
#   Do NOT use 'nimble build' for ds3 targets. nimble resolves the 'windy'
#   dependency above, which does not cross-compile for ARMv6K. Use the
#   provided build script instead:
#     scripts/build_3ds.sh <target.nim>
#   The script calls 'nim compile --define:ds3' directly, bypassing nimble
#   dependency resolution. bitty and shady must be pre-installed in the
#   nimble cache (~/.nimble/pkgs); windy is NOT required for ds3 builds.
#   Examples that import windy (basic_windy.nim, multiple_windows.nim, etc.)
#   cannot be built for ds3 — pass only ds3-guarded sources to build_3ds.sh.
