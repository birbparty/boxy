## vita_clear.nim — minimal raw-vitaGL display test (NO boxy). Isolates vitaGL's
## display/scanout from boxy. Clears red and swaps; logs the display framebuffer.
##   screen RED        -> vitaGL display works with this init; boxy usage is the gap.
##   screen BLACK + base=0 -> sysroot vitaGL's display path is broken -> rebuild patched vitaGL.
## Build: scripts/build_vita.sh examples/vita_clear.nim

import std/[os, strutils]
import opengl

when not defined(vita):
  {.error: "vita-only".}

proc vglSetDisplayBufferCount(count: cint) {.importc, header: "vitaGL.h".}
proc vglInitWithCustomThreshold(poolSize, width, height, ramThreshold,
  cdramThreshold, phycontThreshold, cdlgThreshold: cint, msaa: cint): GLboolean
  {.importc, header: "vitaGL.h", discardable.}
proc vglInit(legacyPoolSize: cint) {.importc, header: "vitaGL.h".}
proc vglSwapBuffers(hasCommonDialog: GLboolean) {.importc, header: "vitaGL.h".}
proc sceKernelExitProcess(res: cint): cint
  {.importc, header: "psp2/kernel/processmgr.h", discardable.}
type SceCtrlData {.importc: "SceCtrlData", header: "psp2/ctrl.h", bycopy.} = object
  timeStamp: uint32
  buttons: uint32
proc sceCtrlPeekBufferPositive(port: cint, data: ptr SceCtrlData, count: cint): cint
  {.importc, header: "psp2/ctrl.h".}
proc sceCtrlSetSamplingMode(mode: cint): cint {.importc, header: "psp2/ctrl.h", discardable.}
type SceDisplayFrameBuf {.importc, header: "psp2/display.h", bycopy.} = object
  size: uint32
  base: pointer
  pitch: uint32
  pixelformat: uint32
  width: uint32
  height: uint32
proc sceDisplayGetFrameBuf(pParam: ptr SceDisplayFrameBuf, sync: cint): cint
  {.importc, header: "psp2/display.h".}

const SCE_CTRL_START = 0x0008'u32

proc log(s: string) =
  try:
    createDir("ux0:data")
    let f = open("ux0:data/boxy_vita_clear.txt", fmAppend)
    f.writeLine(s); f.close()
  except CatchableError: discard

proc main() =
  # Try the threshold init first (proven recipe); also leave a marker.
  log "clear test start; vglInitWithCustomThreshold ..."
  vglSetDisplayBufferCount(2)
  vglInitWithCustomThreshold(0, 960, 544, 8*1024*1024, 8*1024*1024, 0, 26*1024*1024, 0)
  log "init done"

  sceCtrlSetSamplingMode(1)
  var pad: SceCtrlData
  var frame = 0
  while true:
    discard sceCtrlPeekBufferPositive(0, pad.addr, 1)
    if (pad.buttons and SCE_CTRL_START) != 0: break
    glClearColor(1.0, 0.0, 0.0, 1.0)             # RED
    glClear(GL_COLOR_BUFFER_BIT)
    vglSwapBuffers(GL_FALSE)
    if frame == 1:
      var fb: SceDisplayFrameBuf
      fb.size = sizeof(SceDisplayFrameBuf).uint32
      let r = sceDisplayGetFrameBuf(fb.addr, 1)
      log "display fb: base=0x" & toHex(cast[uint](fb.base)) & " w=" & $fb.width &
        " h=" & $fb.height & " pitch=" & $fb.pitch & " getRet=0x" & toHex(r) &
        " glErr=0x" & toHex(glGetError().int)
    inc frame
  log "exited at frame " & $frame
  sceKernelExitProcess(0)

main()
