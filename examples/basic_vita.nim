## basic_vita.nim — boxy drawing a real sprite on the Sony PS Vita.
##
## The first real render example for the Vita port (after the Phase 0 probes proved
## shady's glslES1 output links on hardware). It:
##   - creates a GLES context with vitaGL (vglInit),
##   - newBoxy() — which builds + LINKS all 7 of boxy's shaders via the glslES1 path
##     (atlas/mask/blend/spreadX/spreadY direct, blurX/Y via the Es1 constant-loop
##     variants). This is itself the on-device link test for blend/spread/blur.
##   - addImage() a procedurally-built pixie image, then drawImage() each frame.
##
## Breadcrumbs are written to ux0:data/boxy_vita_basic.txt BEFORE each major step
## (newlib flushes on close), so a native crash leaves the last reached step on disk.
##
## Build: scripts/build_vita.sh examples/basic_vita.nim
## Read:  ux0:data/boxy_vita_basic.txt   (START exits cleanly)

import std/[os, strutils]
import boxy, opengl, vmath, pixie

when not defined(vita):
  {.error: "vita-only; build via scripts/build_vita.sh".}

# --- vitaGL + SceCtrl FFI (minimal) ----------------------------------------------
# Use the PROVEN-on-hardware init (from clicky/raylib vita-debugging): a legacy-pool
# vglInit() starves the CDRAM that the patched vitaGL needs for *dedicated* display
# memblocks, so display alloc falls back to suballocation -> sceDisplaySetFrameBuf
# rejects it -> black screen even though rendering is correct. vglInitWithCustomThreshold
# with pool_size=0 + explicit thresholds reserves that CDRAM.
proc vglSetSemanticBindingMode(mode: GLenum) {.importc, header: "vitaGL.h".}
proc vglSetDisplayBufferCount(count: cint) {.importc, header: "vitaGL.h".}
proc vglInitWithCustomThreshold(poolSize, width, height, ramThreshold,
  cdramThreshold, phycontThreshold, cdlgThreshold: cint, msaa: cint): GLboolean
  {.importc, header: "vitaGL.h", discardable.}
let VGL_MODE_POSTPONED {.importc, header: "vitaGL.h".}: GLenum
proc vglSwapBuffers(hasCommonDialog: GLboolean) {.importc, header: "vitaGL.h".}

# Display-scanout probe: what framebuffer is vitaGL actually handing the display
# controller? Dedicated-CDRAM base (e.g. 0x6x000000, 1MiB-aligned) = patched path OK;
# a suballocated/odd base, or a non-zero return, = the rejected-scanout failure mode.
type SceDisplayFrameBuf {.importc, header: "psp2/display.h", bycopy.} = object
  size: uint32
  base: pointer
  pitch: uint32
  pixelformat: uint32
  width: uint32
  height: uint32
proc sceDisplayGetFrameBuf(pParam: ptr SceDisplayFrameBuf, sync: cint): cint
  {.importc, header: "psp2/display.h".}
proc sceKernelExitProcess(res: cint): cint
  {.importc, header: "psp2/kernel/processmgr.h", discardable.}

type SceCtrlData {.importc: "SceCtrlData", header: "psp2/ctrl.h", bycopy.} = object
  timeStamp: uint32
  buttons: uint32
proc sceCtrlPeekBufferPositive(port: cint, data: ptr SceCtrlData, count: cint): cint
  {.importc, header: "psp2/ctrl.h".}
proc sceCtrlSetSamplingMode(mode: cint): cint
  {.importc, header: "psp2/ctrl.h", discardable.}
const SCE_CTRL_MODE_ANALOG = 1            # populate the button buffer
const SCE_CTRL_START = 0x0008'u32         # correct mask (0x0800 was wrong)

const VitaW = 960
const VitaH = 544

var crumbs: seq[string]
proc crumb(s: string) =
  crumbs.add s
  try:
    createDir("ux0:data")
    writeFile("ux0:data/boxy_vita_basic.txt", crumbs.join("\n") & "\n")
  except CatchableError: discard

proc main() =
  crumb("start; vglInit ...")
  vglSetSemanticBindingMode(VGL_MODE_POSTPONED)
  vglSetDisplayBufferCount(2)
  vglInitWithCustomThreshold(0, VitaW.cint, VitaH.cint,
    8*1024*1024, 8*1024*1024, 0, 26*1024*1024, 0)   # msaa = SCE_GXM_MULTISAMPLE_NONE (0)
  crumb("vglInit OK; newBoxy (links all 7 glslES1 shaders) ...")

  let bxy = newBoxy()
  crumb("newBoxy OK — all shaders linked; building image ...")

  # A procedurally-built sprite (no asset file needed). pixie cross-compiles to Vita.
  let img = newImage(200, 200)
  img.fill(rgba(40, 120, 220, 255))
  let ctx = newContext(img)
  ctx.fillStyle = rgba(240, 220, 40, 255)
  ctx.fillRect(rect(vec2(40, 40), vec2(120, 120)))
  bxy.addImage("sprite", img)
  crumb("addImage OK; entering frame loop ...")

  sceCtrlSetSamplingMode(SCE_CTRL_MODE_ANALOG)
  var pad: SceCtrlData
  var frame = 0
  while true:
    discard sceCtrlPeekBufferPositive(0, pad.addr, 1)
    if (pad.buttons and SCE_CTRL_START) != 0:
      crumb("START pressed; exiting at frame " & $frame)
      break

    bxy.beginFrame(ivec2(VitaW, VitaH))
    bxy.drawImage("sprite", vec2(380, 170))     # roughly centered
    bxy.endFrame()

    # Readback BEFORE swap: did boxy actually draw? (glReadPixels works on vitaGL.)
    # This separates "boxy rendered, display scanout is black" from "boxy drew nothing".
    if frame == 1:
      var px: array[4, uint8]                    # center, over the sprite
      glReadPixels(480, 272, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px[0].addr)
      var corner: array[4, uint8]                # (5,5), outside the sprite
      glReadPixels(5, 5, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, corner[0].addr)
      crumb("frame 1 readback center(480,272) RGBA=" &
        $px[0] & "," & $px[1] & "," & $px[2] & "," & $px[3] &
        "  corner(5,5)=" & $corner[0] & "," & $corner[1] & "," & $corner[2] & "," & $corner[3] &
        "  glErr=" & $glGetError().int)

    vglSwapBuffers(GL_FALSE)

    if frame == 1:
      var fb: SceDisplayFrameBuf
      fb.size = sizeof(SceDisplayFrameBuf).uint32
      let r = sceDisplayGetFrameBuf(fb.addr, 1)   # 1 = NEXTFRAME
      crumb("display fb: base=0x" & toHex(cast[uint](fb.base)) &
        " w=" & $fb.width & " h=" & $fb.height & " pitch=" & $fb.pitch &
        " fmt=0x" & toHex(fb.pixelformat) & " getRet=0x" & toHex(r))

    inc frame
    if frame == 120: crumb("120 frames presented OK (steady state)")

  sceKernelExitProcess(0)

main()
