## Smoke test: OpenGL backend wiring and popLayer correctness.
##
## Verifies:
##   1. newBoxy() instantiates a non-nil OpenGLBackend on desktop.
##   2. enterRawOpenGLMode / exitRawOpenGLMode complete without error and
##      restore the framebuffer binding to the expected value (tests the
##      restoreState path added in this change).
##   3. popLayer with a tint and with a shader-blend mode render without
##      segfault — popLayer itself remains on the inline GL path (not
##      backend-routed); these assertions confirm the inline path still works
##      after the backend field was added to newBoxy.
##
## NOTE: popLayer does NOT route through backend.compositeLayer; it still
## issues GL calls directly. This file does NOT test "1:1 equivalence with
## the pre-backend inline path" in a pixel-comparison sense.
##
## Requires a real OpenGL context — run interactively, not in CI.
## The test exits with return code 0 if all assertions pass.
##
## Usage:
##   nim c -r tests/test_opengl_backend.nim
##
## Expected output:
##   PASS: backend wired
##   PASS: exitRawOpenGLMode: framebuffer binding restored to 0
##   PASS: tinted popLayer (NormalBlend): red pixels present
##   PASS: shader-blend popLayer (OverlayBlend): red pixels present
##   ALL TESTS PASSED

import boxy, opengl, windy, chroma, vmath

proc assertMsg(cond: bool, msg: string) =
  if not cond:
    echo "FAIL: ", msg
    quit(1)
  echo "PASS: ", msg

let window = newWindow("boxy backend regression test", ivec2(256, 256),
                       visible = false)
makeContextCurrent(window)
loadExtensions()

let bxy = newBoxy()

# --- 1. Backend is wired ---
assertMsg(bxy.backend != nil, "backend wired")

# --- 2. enterRawOpenGLMode / exitRawOpenGLMode: verify restoreState ran ---
# After exitRawOpenGLMode with no active layer, restoreState should bind FBO 0.
bxy.beginFrame(window.size)
bxy.enterRawOpenGLMode()
glClearColor(0, 0, 0, 1)  # harmless raw GL call
bxy.exitRawOpenGLMode()
bxy.endFrame()

var fbo: GLint
glGetIntegerv(GL_FRAMEBUFFER_BINDING, fbo.addr)
assertMsg(fbo == 0, "exitRawOpenGLMode: framebuffer binding restored to 0")

# --- 3a. Tinted popLayer (NormalBlend) ---
# Draw a solid red rect inside a layer, pop with 50% alpha tint.
# Reads back pixels to confirm something rendered (smoke test for inline popLayer
# still working with the new backend field present).
block:
  let img = newImage(128, 128)
  img.fill(color(1, 0, 0, 1))
  bxy.addImage("red_solid", img)

bxy.beginFrame(window.size)
glClearColor(0, 0, 0, 1)
glClear(GL_COLOR_BUFFER_BIT)

bxy.pushLayer()
bxy.drawImage("red_solid", rect(vec2(0, 0), vec2(128, 128)))
bxy.popLayer(tint = color(1, 1, 1, 0.5))  # 50% opacity tint

bxy.endFrame()

# glReadPixels reads the backbuffer (no swapBuffers needed — hidden window,
# backbuffer preserved after endFrame on most drivers).
var pixels = newSeq[uint8](256 * 256 * 4)
glReadBuffer(GL_BACK)
glReadPixels(0, 0, 256, 256, GL_RGBA, GL_UNSIGNED_BYTE, pixels[0].addr)

var hasRed = false
for i in countup(0, pixels.high, 4):
  if pixels[i] > 0:  # R channel
    hasRed = true
    break
assertMsg(hasRed, "tinted popLayer (NormalBlend): red pixels present")

# --- 3b. Shader-blend popLayer (OverlayBlend) ---
# Push 2 layers: outer (destination) gets red, inner (source) also gets red.
# OverlayBlend of red-on-red produces red (R=1 >= 0.5: 1-2*(0)*(0)=1).
# Outer layer then pops to screen; check R channel non-zero in drawn region.
bxy.beginFrame(window.size)
glClearColor(0, 0, 0, 1)
glClear(GL_COLOR_BUFFER_BIT)

bxy.pushLayer()  # outer (destination for OverlayBlend)
bxy.drawImage("red_solid", rect(vec2(0, 0), vec2(128, 128)))

bxy.pushLayer()  # inner (source for OverlayBlend)
bxy.drawImage("red_solid", rect(vec2(0, 0), vec2(128, 128)))
bxy.popLayer(blendMode = OverlayBlend)  # blend inner onto outer

bxy.popLayer()  # pop outer to screen

bxy.endFrame()

glReadBuffer(GL_BACK)
glReadPixels(0, 0, 256, 256, GL_RGBA, GL_UNSIGNED_BYTE, pixels[0].addr)

var hasRedOverlay = false
for i in countup(0, pixels.high, 4):
  if pixels[i] > 0:  # R channel in drawn region
    hasRedOverlay = true
    break
assertMsg(hasRedOverlay, "shader-blend popLayer (OverlayBlend): red pixels present")

echo "ALL TESTS PASSED"
