## Milestone 5 render gate — boxy newBoxy → addImage → drawImage on Nintendo 3DS.
##
## Exercises the full high-level boxy API on ds3 and renders a visible image:
##   1. gfxInitDefault + c3dInit (required before newBoxy)
##   2. Create and wire top-screen citro3d render target
##   3. newBoxy() → allocates citro3d atlas backend
##   4. romfsInit → readImage("romfs:/test.png") → addImage → romfsExit
##   5. Main loop:
##        c3dFrameBegin → c3dFrameDrawOn → c3dRenderTargetClear
##        → bx.beginFrame → bx.drawImage → bx.endFrame → c3dFrameEnd
##   6. Exit on START button, cleanup
##
## NOTE: no gfxSwapBuffers — c3dFrameEnd performs the display transfer (see the
## inline comment at the end of the main loop for why calling it would blank).
##
## Verified on Azahar: the test image renders upright at (50,50) over a dark-blue
## clear, with NormalBlend. Rendering relies on two PICA200 fixes landed alongside
## this example: the color write mask (c3dDepthTest's 3rd arg must be GPU_WRITE_ALL,
## not 0) and the texture V-flip in boxy.nim's ds3 drawUvRect.
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

# Shared teardown helper — called from every exit path so they stay in sync.
# destroy() releases VRAM atlas and quad buffers; must precede c3dFini().
# destroy() is idempotent and safe to call before addImage completes.
template shutdown() =
  bx.destroy()
  c3dRenderTargetDelete(topScreen)
  c3dFini()
  gfxExit()

# addImage must be called outside a beginFrame/endFrame pair on ds3 — atlas
# grow triggers c3dFrameBegin which cannot nest inside an open frame.
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
    # Clear to dark blue so the drawn image is visible against the background.
    c3dRenderTargetClear(topScreen, 1, 0x000080FF'u32, 0)

    # boxy frame — draw test image near the top-left.
    # Logical frame size matches the physical screen (400×240 in landscape
    # coordinates; the display hardware applies the tilt).
    bx.beginFrame(ivec2(400, 240))
    bx.drawImage("test", vec2(50, 50))
    bx.endFrame()

    c3dFrameEnd(0)
  # Note: gfxSwapBuffers is intentionally absent — citro3d's c3dFrameEnd
  # handles the DMA transfer to the display framebuffer internally.
  # Calling gfxSwapBuffers after c3dFrameEnd would swap to the OTHER
  # (empty) framebuffer and produce a black screen.

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

shutdown()
