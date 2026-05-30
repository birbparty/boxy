## Milestone 4 gate: pixie cross-compilation on Nintendo 3DS.
##
## Verifies that the pixie + nimsimd + zippy stack cross-compiles cleanly
## for ARMv6K under devkitARM + --gc:arc. Tests:
##   1. pixie.newImage(4, 4) — heap allocation via libctru malloc
##   2. img.fill(rgbx(255, 0, 0, 255)) — pure CPU pixel write
##   3. doAssert on the first pixel — runtime check of alloc+fill+read
##      (zippy inflate, PNG decode, and SIMD are compile-proven here, not run)
##   4. Clean exit via aptMainLoop + HOME button
##
## Expected: .3dsx loads and exits cleanly on HOME-button press.
## A compile error here means pixie's ARMv6K path has broken; see
## docs/analysis/pixie-armv6k-compat.md for fallback strategy.
##
## Build: scripts/build_3ds.sh examples/milestone4_3ds.nim milestone4_3ds
## Run:   load build/milestone4_3ds.3dsx in Azahar; exit via HOME button

when not defined(ds3):
  {.error: "milestone4_3ds.nim must be compiled with --define:ds3 (use scripts/build_3ds.sh)".}

import pixie
import boxy/bindings/libctru_gfx

gfxInitDefault()

# Heap-allocate a 4×4 image via pixie.newImage (uses libctru malloc under ARC).
let img = newImage(4, 4)

# CPU pixel write — exercises the non-SIMD portable path on ARMv6K.
img.fill(rgbx(255, 0, 0, 255))

# Verify the first pixel was written correctly (pure CPU, no GPU).
doAssert img[0, 0] == rgbx(255, 0, 0, 255),
  "milestone4: pixie fill/read mismatch — CPU pixel path broken"

# Idle until HOME button is pressed. svcSleepThread yields the ARM11 core
# for ~16.7 ms per iteration (~60 Hz) — avoids 100% CPU spin on a gate that
# renders nothing. Same idiom as milestone2_3ds.nim.
while aptMainLoop():
  svcSleepThread(16_666_667)

gfxExit()
