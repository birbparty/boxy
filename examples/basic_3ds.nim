## Milestone 5 compile gate — boxy newBoxy → addImage → drawImage on Nintendo 3DS.
##
## Exercises the full high-level boxy API on ds3:
##   1. gfxInitDefault + c3dInit (required before newBoxy)
##   2. Create and wire top-screen citro3d render target
##   3. newBoxy() → allocates citro3d atlas backend
##   4. romfsInit → readImage("romfs:/test.png") → addImage → romfsExit
##   5. Main loop:
##        c3dFrameBegin → c3dFrameDrawOn → c3dRenderTargetClear
##        → bx.beginFrame → bx.drawImage → bx.endFrame
##        → c3dFrameEnd → gfxSwapBuffers
##   6. Exit on START button, cleanup
##
## Design note — GPU state (shader, TEV, projection, atlas bind):
##   The citro3d backend's flush() requires the caller to have bound the render
##   shader, uploaded the projection uniform, configured TEV, and bound the atlas
##   texture. That wiring is not yet in boxy.nim; it is the subject of milestone 5
##   (boxy-c3q). This example validates compilation and API surface only — actual
##   visible rendering is verified in milestone 5.
##
## Build: scripts/build_3ds.sh examples/basic_3ds.nim basic_3ds
## Run:   load build/basic_3ds.3dsx in Azahar (or on hardware); exit via START

when not defined(ds3):
  {.error: "basic_3ds.nim must be compiled with --define:ds3 (use scripts/build_3ds.sh)".}

import pixie
import boxy
import boxy/bindings/libctru_gfx
import boxy/bindings/libctru_hid
import boxy/bindings/citro3d
import vmath

# Minimal RomFS bindings. <3ds/romfs.h> is part of libctru; the devkitARM
# include path is set by nim_3ds.cfg.
proc romfsInit*(): cint {.importc: "romfsInit", header: "<3ds/romfs.h>".}
proc romfsExit*(): cint {.importc: "romfsExit", header: "<3ds/romfs.h>".}

# Transfer flags for 3DS top screen output: RGBA8 framebuffer → RGB8 display.
# Derived from GX_TRANSFER_IN_FORMAT(RGBA8=0) | GX_TRANSFER_OUT_FORMAT(RGB8=1)
# = 0 | (1 << 12) = 0x1000. Standard for devkitPro citro3d examples.
const DISPLAY_TRANSFER_FLAGS = 0x1000'u32

# ---------------------------------------------------------------------------
# Initialise hardware
# ---------------------------------------------------------------------------

gfxInitDefault()

if not c3dInit(C3D_DEFAULT_CMDBUF_SIZE):
  gfxExit()
  quit(1)

# Top screen physical dimensions: 240 wide × 400 tall (portrait orientation).
# depthFmt = -1 → no depth buffer (2D rendering only).
let topScreen = c3dRenderTargetCreate(240, 400, GPU_RB_RGBA8, -1)
if topScreen == nil:
  c3dFini()
  gfxExit()
  quit(1)
c3dRenderTargetSetOutput(topScreen, GFX_TOP, GFX_LEFT, DISPLAY_TRANSFER_FLAGS)

# ---------------------------------------------------------------------------
# Create boxy and load the test image
# ---------------------------------------------------------------------------

# newBoxy initialises the citro3d atlas backend; must follow c3dInit.
let bx = newBoxy()

# addImage must be called outside a beginFrame/endFrame pair on ds3 — atlas
# grow triggers c3dFrameBegin which cannot nest inside an open frame.
if romfsInit() != 0:
  c3dRenderTargetDelete(topScreen)
  c3dFini()
  gfxExit()
  quit(1)

let img = readImage("romfs:/test.png")
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
    # Clear to black (clearBits=1 = color only; RGBA8 packed = 0x000000FF)
    c3dRenderTargetClear(topScreen, 1, 0x000000FF'u32, 0)

    # boxy frame — draw test image at top-left corner.
    # Logical frame size matches the physical screen (400×240 in landscape
    # coordinates; the display hardware applies the tilt).
    bx.beginFrame(ivec2(400, 240))
    bx.drawImage("test", vec2(10, 10))
    bx.endFrame()

    c3dFrameEnd(0)

  gfxSwapBuffers()

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

c3dRenderTargetDelete(topScreen)
c3dFini()
gfxExit()
