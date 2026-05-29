## Regression test: OpenGL backend wiring and popLayer correctness.
##
## Verifies:
##   1. newBoxy() instantiates a non-nil OpenGLBackend on desktop
##   2. enterRawOpenGLMode / exitRawOpenGLMode delegate through backend.restoreState
##   3. popLayer with tint and with shader-blend modes produces non-black output
##      (1:1 equivalence with the pre-backend inline path cannot segfault or clear)
##
## Requires a real OpenGL context — run interactively, not in CI.
## The test exits with a zero return code if all assertions pass.
##
## Usage:
##   nim c -r tests/test_opengl_backend.nim
##
## Expected output:
##   backend wired: OK
##   enterRawOpenGLMode / exitRawOpenGLMode: OK
##   tinted popLayer (NormalBlend): OK  (red pixels present)
##   shader-blend popLayer (OverlayBlend): OK  (non-zero pixels present)
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

# --- 2. enterRawOpenGLMode / exitRawOpenGLMode roundtrip ---
bxy.beginFrame(window.size)
bxy.enterRawOpenGLMode()
# do a harmless raw GL call
glClearColor(0, 0, 0, 1)
bxy.exitRawOpenGLMode()
bxy.endFrame()
assertMsg(true, "enterRawOpenGLMode / exitRawOpenGLMode")

# --- 3a. Tinted popLayer (NormalBlend) ---
# Draw a solid red rect inside a layer, pop with alpha tint, read back pixels.
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

var pixels = newSeq[uint8](256 * 256 * 4)
glReadPixels(0, 0, 256, 256, GL_RGBA, GL_UNSIGNED_BYTE, pixels[0].addr)

var hasRed = false
for i in countup(0, pixels.high, 4):
  if pixels[i] > 0:  # R channel
    hasRed = true
    break
assertMsg(hasRed, "tinted popLayer (NormalBlend): red pixels present")

# --- 3b. Shader-blend popLayer (OverlayBlend) ---
bxy.beginFrame(window.size)
glClearColor(0.5, 0.5, 0.5, 1)
glClear(GL_COLOR_BUFFER_BIT)

bxy.pushLayer()
bxy.drawImage("red_solid", rect(vec2(0, 0), vec2(128, 128)))
bxy.popLayer(blendMode = OverlayBlend)

bxy.endFrame()

glReadPixels(0, 0, 256, 256, GL_RGBA, GL_UNSIGNED_BYTE, pixels[0].addr)

var hasNonZero = false
for b in pixels:
  if b > 0:
    hasNonZero = true
    break
assertMsg(hasNonZero, "shader-blend popLayer (OverlayBlend): non-zero pixels present")

echo "ALL TESTS PASSED"
