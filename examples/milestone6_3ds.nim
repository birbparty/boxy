## Milestone 6 render gate — pushLayer/popLayer NormalBlend round-trip on Nintendo 3DS.
##
## Exercises the full RTT layer path on ds3:
##   1. gfxInitDefault + c3dInit (required before newBoxy)
##   2. Create and wire top-screen citro3d render target
##   3. newBoxy() → allocates citro3d atlas backend
##   4. Wire topScreen into backend via setScreenTarget (required for popLayer→screen)
##   5. romfsInit → readImage("romfs:/test.png") → addImage → romfsExit
##   6. Main loop:
##        c3dFrameBegin → c3dFrameDrawOn(topScreen) → c3dRenderTargetClear
##        → bx.beginFrame
##        → bx.pushLayer()              ← switches RT to layer RTT
##        → bx.drawImage("test", ...)   ← draws into layer RTT (non-tilted ortho)
##        → bx.popLayer(NormalBlend)    ← composites layer→screen (topScreenOrthoProj)
##        → bx.endFrame
##        → c3dFrameEnd
##   7. Exit on START button, cleanup
##
## Success criteria (milestone 6):
##   The composited layer appears correctly over the blue clear: the test image
##   is visible, upright, at the expected position, with no rotation or mirroring.
##
## V-orientation note: compositeLayer UV mapping was verified on Azahar 2026-06-04.
## V=0=bottom is correct (standard GPU convention); do NOT flip V. The triangular-image
## artifact seen during development was caused by the BL→TR quad diagonal (wrong vertex
## order), not by V-axis orientation. Fixed in citro3d_backend.nim (v2=TL, v3=TR).
##
## NOTE: no gfxSwapBuffers — c3dFrameEnd handles the display transfer.
##
## Build: scripts/build_3ds.sh examples/milestone6_3ds.nim milestone6_3ds
## Run:   load build/milestone6_3ds.3dsx in Azahar; exit via START

when not defined(ds3):
  {.error: "milestone6_3ds.nim must be compiled with --define:ds3 (use scripts/build_3ds.sh)".}

import pixie
import boxy
import boxy/bindings/libctru_gfx
import boxy/bindings/libctru_hid
import boxy/bindings/citro3d
import boxy/backends/citro3d_backend

proc romfsInit*(): cint {.importc: "romfsInit", header: "<3ds/romfs.h>".}
proc romfsExit*(): cint {.importc: "romfsExit", header: "<3ds/romfs.h>".}

const DISPLAY_TRANSFER_FLAGS = 0x1000'u32

# ---------------------------------------------------------------------------
# Initialise hardware
# ---------------------------------------------------------------------------

gfxInitDefault()

if not c3dInit(C3D_DEFAULT_CMDBUF_SIZE):
  gfxExit()
  quit(1)

let topScreen = c3dRenderTargetCreate(240, 400, GPU_RB_RGBA8, -1)
if topScreen == nil:
  c3dFini()
  gfxExit()
  quit(1)
c3dRenderTargetSetOutput(topScreen, GFX_TOP, GFX_LEFT, DISPLAY_TRANSFER_FLAGS)

# ---------------------------------------------------------------------------
# Create boxy, wire screen target, load image
# ---------------------------------------------------------------------------

let bx = newBoxy()

# Register the physical screen RT so popLayer can composite the final layer
# onto the screen (compositeLayer uses topScreenOrthoProj for this path).
Citro3dBackend(bx.backend).setScreenTarget(topScreen)

template shutdown() =
  bx.destroy()
  c3dRenderTargetDelete(topScreen)
  c3dFini()
  gfxExit()

if romfsInit() != 0:
  shutdown()
  quit(1)

var img: Image
try:
  img = readImage("romfs:/test.png")
except PixieError, IOError:
  discard romfsExit()
  shutdown()
  quit(1)
bx.addImage("test", img)
discard romfsExit()

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while aptMainLoop():
  hidScanInput()
  if (hidKeysDown() and KEY_START) != 0:
    break

  if c3dFrameBegin(C3D_FRAME_SYNCDRAW):
    discard c3dFrameDrawOn(topScreen)
    # Clear to dark blue — the composited layer should appear over this.
    c3dRenderTargetClear(topScreen, 1, 0x000080FF'u32, 0)

    bx.beginFrame(ivec2(400, 240))

    # RTT layer path (milestone 6):
    #   pushLayer → switch RT to VRAM layer texture (non-tilted ortho for draws)
    #   drawImage  → draw test image into the layer at (50, 50)
    #   popLayer   → flush layer draws, composite layer→screen (topScreenOrthoProj)
    #
    # SINGLE-FLUSH-PER-FRAME: no drawImage calls before pushLayer or after popLayer
    # within this frame — the citro3d quad batch flushes only once (inside popLayer).
    bx.pushLayer()
    bx.drawImage("test", vec2(50, 50))
    bx.popLayer(blendMode = NormalBlend)

    bx.endFrame()

    c3dFrameEnd(0)

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

shutdown()
