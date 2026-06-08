## Guards boxy's hand-wired PICA200 TEV stages against Shady's toTev model.
##
## boxy configures the texture-environment (TEV) combiner by hand in
## citro3d_backend.nim — two stages:
##   modulate: texture * vertex-color  -> GPU_MODULATE(GPU_TEXTURE0, GPU_PRIMARY_COLOR)
##   replace:  texture                 -> GPU_REPLACE(GPU_TEXTURE0)
## Shady's `toTev` can derive the same fixed-function descriptor from a Nim
## fragment proc. This test asserts the two stay in agreement, so neither the
## backend's constants nor the Nim model can drift unnoticed.
##
## Two tiers (mirrors tests/test_render2d_pica.nim):
##
##  1. ALWAYS (no Shady, CI-safe): the backend source still contains the exact
##     c3dTexEnvSrc/Func argument lists for modulate and replace. Catches an
##     accidental change to the hand-wired constants.
##
##  2. -d:ds3 (needs the pinned Shady on --path): toTev over the modulate/replace
##     fragment procs yields TevStage descriptors whose GPU_* constants match the
##     backend's. Only the operands each function CONSUMES are compared — toTev
##     returns tevPrevious for unused slots while boxy passes a filler
##     GPU_TEXTURE0 there (modulate uses src0*src1; replace uses src0), so those
##     filler slots are don't-cares and asserting them would false-fail.
##
## Run:
##   nim c -r tests/test_tev_config.nim                       # tier 1
##   nim c -r -d:ds3 -d:shadyNoPixie --path:build/shady-pin/src \
##     tests/test_tev_config.nim                              # tier 1 + 2

import std/[os, strutils]

const repoRoot = currentSourcePath.parentDir.parentDir
let backend = readFile(repoRoot / "src" / "boxy" / "backends" / "citro3d_backend.nim")

var failures = 0
proc check(cond: bool, msg: string) =
  if cond:
    echo "PASS: ", msg
  else:
    echo "FAIL: ", msg
    inc failures

# --- tier 1: backend hand-wired constants present (env-var-agnostic substrings) ---
check("C3D_BOTH_MODE, GPU_TEXTURE0, GPU_PRIMARY_COLOR, GPU_TEXTURE0)" in backend,
  "backend modulate sources: GPU_TEXTURE0 x GPU_PRIMARY_COLOR")
check("C3D_BOTH_MODE, GPU_MODULATE)" in backend,
  "backend modulate function: GPU_MODULATE")
check("C3D_BOTH_MODE, GPU_TEXTURE0, GPU_TEXTURE0, GPU_TEXTURE0)" in backend,
  "backend replace sources: GPU_TEXTURE0")
check("C3D_BOTH_MODE, GPU_REPLACE)" in backend,
  "backend replace function: GPU_REPLACE")

# --- tier 2: toTev model matches the consumed operands ---
when defined(ds3):
  import shady, vmath

  # texture * vertex-color -> Modulate. Param names map to TEV sources by Shady's
  # convention: tex* -> texture0, vert*/col* -> primary (vertex) color.
  proc modulateFrag(fragColor: var Vec4, texColor: Vec4, vertColor: Vec4) =
    fragColor = texColor * vertColor

  # texture -> Replace.
  proc replaceFrag(fragColor: var Vec4, texColor: Vec4) =
    fragColor = texColor

  const modStage = toTev(modulateFrag)
  const repStage = toTev(replaceFrag)

  # Modulate consumes fn, src0, src1 (src2 is a don't-care filler slot).
  check(modStage.fn.gpuFunc == "GPU_MODULATE", "toTev modulate fn -> GPU_MODULATE")
  check(modStage.src0.gpuSource == "GPU_TEXTURE0", "toTev modulate src0 -> GPU_TEXTURE0")
  check(modStage.src1.gpuSource == "GPU_PRIMARY_COLOR", "toTev modulate src1 -> GPU_PRIMARY_COLOR")
  # Replace consumes fn, src0 only (src1/src2 are don't-care filler slots).
  check(repStage.fn.gpuFunc == "GPU_REPLACE", "toTev replace fn -> GPU_REPLACE")
  check(repStage.src0.gpuSource == "GPU_TEXTURE0", "toTev replace src0 -> GPU_TEXTURE0")
  echo "toTev model agrees with boxy's hand-wired TEV constants."
else:
  echo "toTev model check skipped (compile with -d:ds3 + --path:<pinned shady>/src)."

if failures > 0:
  echo failures, " TEV check(s) FAILED"
  quit(1)
echo "TEV config guard passed."
