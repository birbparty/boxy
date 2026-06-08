## ABI guard for boxy's PICA200 render2d vertex shader.
##
## Under Architecture B the shader is assembled inline at Nim-compile time
## (Shady toPicaShbin) — there is no committed artifact to diff. This test
## instead asserts the GENERATED assembly still carries the exact ABI tokens the
## citro3d backend binds to, so a change to render2dVert (e.g. a parameter
## reorder, which silently remaps the v0/v1/v2 attribute registers) is caught
## before it corrupts rendering on hardware.
##
## Gated behind -d:ds3 because it needs Shady's toPica (the pinned PICA branch)
## on --path. Default `nim c -r tests/test_render2d_pica.nim` (no -d:ds3) is a
## no-op pass, so CI and fresh clones — which have neither the Shady branch nor
## picasso — are unaffected.
##
## Run (from repo root, with the pinned Shady fetched by build_3ds.sh):
##   nim c -r -d:ds3 -d:shadyNoPixie --path:build/shady-pin/src \
##     tests/test_render2d_pica.nim
## (build_3ds.sh populates build/shady-pin; or point --path at any checkout of
##  the pinned commit.)

when defined(ds3):
  import std/strutils                 # `in` (contains) for strings
  import boxy/backends/render2d_pica  # render2dShbin, render2dPicaSrc

  let src = render2dPicaSrc
  var failures = 0
  proc check(cond: bool, msg: string) =
    if cond:
      echo "PASS: ", msg
    else:
      echo "FAIL: ", msg
      inc failures

  # Uniform bound by name.
  check(".fvec projection[4]" in src, "uniform: projection")
  # Attribute registers in render2dVert parameter order: inPos->v0, inUv->v1,
  # inColor->v2. A param reorder would change these and is caught here.
  check(".alias inPos v0" in src, "attribute: inPos -> v0 (position)")
  check(".alias inUv v1" in src, "attribute: inUv -> v1 (uv)")
  check(".alias inColor v2" in src, "attribute: inColor -> v2 (color)")
  # Output semantics.
  check(".out outpos position" in src, "output: outpos position")
  check(".out outtc0 texcoord0" in src, "output: outtc0 texcoord0")
  check(".out outclr color" in src, "output: outclr color")
  # The .shbin actually assembled to a valid DVLB container.
  check(render2dShbin.len > 0 and render2dShbin[0 .. 3] == "DVLB",
    "render2dShbin is a DVLB .shbin (" & $render2dShbin.len & " bytes)")

  if failures > 0:
    echo failures, " ABI check(s) FAILED"
    quit(1)
  echo "render2d.v.pica ABI guard passed."
else:
  echo "render2d ABI guard skipped (compile with -d:ds3 + --path:<pinned shady>/src)."
