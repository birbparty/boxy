## Milestone 2 gate: C3D_Init + .shbin load + shader program bind.
##
## Verifies:
##   - citro3d links (-lcitro3d / -lctru are resolved at link time)
##   - render2d.shbin embeds and parses via DVLB_ParseFile
##   - shaderProgramInit / shaderProgramSetVsh / c3dBindProgram return success
##
## No render output.  Exit via HOME button (or Azahar auto-terminates on aptMainLoop=false).
##
## Build:  scripts/build_3ds.sh examples/milestone2_3ds.nim milestone2_3ds
## Run:    load build/milestone2_3ds.3dsx in Azahar

when not defined(ds3):
  {.error: "milestone2_3ds.nim must be compiled with --define:ds3 (use scripts/build_3ds.sh)".}

import boxy/bindings/libctru_gfx
import boxy/bindings/citro3d

# Embed render2d.shbin at compile time.  Shader is compiled in stage 1 of build_3ds.sh,
# so the file exists before Nim compilation begins.
# Path is relative to this source file's directory (examples/).
const shbinRaw = staticRead("../build/render2d.shbin")

proc fail(dvlb: ptr DVLB_s = nil, prog: ptr ShaderProgram_s = nil) {.noreturn.} =
  if prog != nil: discard shaderProgramFree(prog)
  if dvlb != nil: dvlbFree(dvlb)
  c3dFini()
  gfxExit()
  quit(1)

gfxInitDefault()

let ok = c3dInit(C3D_DEFAULT_CMDBUF_SIZE)
if not ok:
  # c3dInit failed before c3dFini is valid; call gfxExit directly.
  gfxExit()
  quit(1)

# Parse the embedded shader binary.
# staticRead returns a string; we need a mutable copy so we can take an addr.
var shbinBuf = shbinRaw
if shbinBuf.len < 4:
  fail()
let dvlb = dvlbParseFile(cast[ptr uint32](addr shbinBuf[0]),
                          shbinBuf.len.uint32)
if dvlb == nil or dvlb.numDVLE < 1:
  fail(dvlb)

var prog: ShaderProgram_s
if shaderProgramInit(addr prog) != 0:
  fail(dvlb)
if shaderProgramSetVsh(addr prog, dvlb.DVLE) != 0:  # dvlb.DVLE is ptr DVLE_s (first entry)
  fail(dvlb, addr prog)
c3dBindProgram(addr prog)

# Idle until the user/emulator requests exit (HOME button, or Azahar).
# svcSleepThread avoids pegging the CPU; this gate renders nothing.
while aptMainLoop():
  svcSleepThread(16_666_667)  # ~1/60 s

discard shaderProgramFree(addr prog)
dvlbFree(dvlb)
c3dFini()
gfxExit()
