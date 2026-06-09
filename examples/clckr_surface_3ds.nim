## clckr consumer-surface render gate — the full boxy ds3 API clckr leans on.
##
## basic_3ds.nim proves exactly one thing: PNG → addImage → one drawImage at a
## fixed position. clckr's real frame additionally uses drawRect (background +
## button fills), a sprite under a saveTransform/applyTransform camera transform,
## and a CPU-rasterized pixie *text* image via addImage. Those paths flow through
## different ds3 code than basic_3ds, so this example exercises them explicitly,
## in one layer-free, single-flush frame.
##
## Surface exercised (mirrors clckr src/game/render.nim + widgets.nim):
##   atlas build (outside frames):
##     - pixie readFont/typeset/fillText → Image → addImage   (ask #3, highest risk)
##     - PNG readImage("romfs:/test.png") → addImage           (sprite path)
##   frame loop (no layers, one flush at endFrame):
##     - drawRect ×2 (full-screen background + button), white-tile + drawUvRect path
##     - drawImage("sprite") under saveTransform/applyTransform(translate*scale)
##     - drawImage("text", pos) — the pixie text atlas entry
##
## Build: scripts/build_3ds.sh examples/clckr_surface_3ds.nim clckr_surface_3ds
## Run:   load build/clckr_surface_3ds.3dsx in Azahar (or hardware); exit via START
##
## Requires romfs/font.ttf (TTF) and romfs/test.png — build_3ds.sh packs romfs/.

when not defined(ds3):
  {.error: "clckr_surface_3ds.nim must be compiled with --define:ds3 (use scripts/build_3ds.sh)".}

import pixie
import boxy
import boxy/bindings/libctru_gfx
import boxy/bindings/libctru_hid
import boxy/bindings/citro3d
import vmath

# Minimal RomFS bindings (see basic_3ds.nim). devkitARM include path from nim_3ds.cfg.
proc romfsInit*(): cint {.importc: "romfsInit", header: "<3ds/romfs.h>".}
proc romfsExit*(): cint {.importc: "romfsExit", header: "<3ds/romfs.h>".}

# RGBA8 framebuffer → RGB8 display transfer flags (standard devkitPro citro3d value).
const DISPLAY_TRANSFER_FLAGS = 0x1000'u32

# ---------------------------------------------------------------------------
# Initialise hardware
# ---------------------------------------------------------------------------

gfxInitDefault()

if not c3dInit(C3D_DEFAULT_CMDBUF_SIZE):
  gfxExit()
  quit(1)

# Top screen physical dimensions: 240 wide × 400 tall (portrait). depthFmt = -1
# → no depth buffer (2D only). beginFrame uses landscape 400×240 logical coords.
let topScreen = c3dRenderTargetCreate(240, 400, GPU_RB_RGBA8, -1)
if topScreen == nil:
  c3dFini()
  gfxExit()
  quit(1)
c3dRenderTargetSetOutput(topScreen, GFX_TOP, GFX_LEFT, DISPLAY_TRANSFER_FLAGS)

# ---------------------------------------------------------------------------
# Create boxy
# ---------------------------------------------------------------------------

# newBoxy initialises the citro3d atlas backend (must follow c3dInit) and inserts
# the white tile at index 0 — drawRect samples it, so drawRect is safe from init.
let bx = newBoxy()

# Shared teardown — every exit path calls it so they stay in sync.
template shutdown() =
  bx.destroy()
  c3dRenderTargetDelete(topScreen)
  c3dFini()
  gfxExit()

# ---------------------------------------------------------------------------
# Atlas build — all addImage calls happen here, OUTSIDE any beginFrame/endFrame.
# On ds3 atlas grow triggers c3dFrameBegin, which cannot nest inside a frame.
# ---------------------------------------------------------------------------

if romfsInit() != 0:
  shutdown()
  quit(1)

# --- ask #3: CPU pixie text rasterization (font.ttf) → Image → addImage ---
# Mirrors clckr widgets.nim: newFont → typeset → fillText into an Image, then
# addImage. This is the path the request asks boxy to confirm or flag on ds3.
try:
  let typeface = readTypeface("romfs:/font.ttf")
  let font = newFont(typeface)
  font.size = 24
  font.paint = "#FFFFFF"
  let arrangement = typeset(@[newSpan("clckr 3DS", font)], bounds = vec2(360, 40))
  let bounds = arrangement.computeBounds().snapToPixels()
  let textImage = newImage(max(1, bounds.w.int), max(1, bounds.h.int))
  textImage.fillText(arrangement, translate(-bounds.xy))
  bx.addImage("text", textImage)
except PixieError, IOError:
  discard romfsExit()
  shutdown()
  quit(1)

# --- PNG sprite → addImage (mirrors clckr render.nim sprite frames) ---
try:
  let sprite = readImage("romfs:/test.png")
  bx.addImage("sprite", sprite)
except PixieError, IOError:
  discard romfsExit()
  shutdown()
  quit(1)

discard romfsExit()

# ---------------------------------------------------------------------------
# Main loop — one flat, layer-free, single-flush frame per iteration.
# ---------------------------------------------------------------------------

while aptMainLoop():
  hidScanInput()
  if (hidKeysDown() and KEY_START) != 0:
    break

  if c3dFrameBegin(C3D_FRAME_SYNCDRAW):
    discard c3dFrameDrawOn(topScreen)
    c3dRenderTargetClear(topScreen, 1, 0x101820FF'u32, 0)

    bx.beginFrame(ivec2(400, 240))

    # 1. full-screen background rect (white-tile + drawUvRect path).
    bx.drawRect(rect(0, 0, 400, 240), color(0.12, 0.14, 0.18, 1))
    # 2. a "button" rect — second drawRect, different position/color.
    bx.drawRect(rect(20, 40, 160, 48), color(0.20, 0.50, 0.85, 1))

    # 3. sprite under a camera transform (clckr's applyTransform(translate*scale)),
    #    drawn via the rect= overload — exactly how clckr's coin sprite draws.
    bx.saveTransform()
    bx.applyTransform(translate(vec2(240, 60)) * scale(vec2(2.0, 2.0)))
    bx.drawImage("sprite", rect = rect(0, 0, 32, 32))
    bx.restoreTransform()

    # 4. the pixie-text atlas entry (pos overload, as clckr widgets use).
    bx.drawImage("text", vec2(24, 200))

    bx.endFrame()  # single flush — all ~5 quads accumulate into one batch.

    c3dFrameEnd(0)
  # No gfxSwapBuffers — c3dFrameEnd performs the display transfer (see basic_3ds).

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

shutdown()
