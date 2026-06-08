version     = "0.7.0"
author      = "Andre von Houck and Ryan Oldenburg"
description = "2D GPU rendering with a tiling atlas."
license     = "MIT"

srcDir = "src"

requires "nim >= 1.2.2"
# shady: pinned to the birbparty fork (PR #3, branch matt.spurlin/retro-targets) which
# adds the `glslES1` (GLSL ES 1.00) target boxy needs for the PS Vita port — vitaGL's
# SceShaccCg crashes linking `300 es` but accepts `100`. Also carries the 3DS/PICA200
# targets. Revert to "shady >= 0.1.6" once the PR merges + a release is tagged.
requires "https://github.com/birbparty/shady#2550b934f0a59d19ef6aebed9eb47d35314565e1"
requires "bitty >= 0.1.4"
requires "windy >= 0.4.4"
