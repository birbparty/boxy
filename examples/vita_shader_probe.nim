## vita_shader_probe.nim — link ALL 7 of boxy's real shaders via glslES1, breadcrumbed.
##
## basic_vita.nim crashed inside newBoxy (vitaGL custom_shaders.c / std::map walk during
## a glLinkProgram). atlas+mask are proven (probe #5); newBoxy also links blend, blurX/Y
## (Es1), spreadX/Y. This probe links each — in newBoxy's order — writing a breadcrumb
## BEFORE each link, so the LAST line of ux0:data/boxy_vita_probe.txt names the shader
## whose link crashes vitaGL.
##
## Build: scripts/build_vita.sh examples/vita_shader_probe.nim
## Read:  ux0:data/boxy_vita_probe.txt

import std/[os, strformat, strutils]
import opengl
import shady                       # birbparty fork: glslES1
import boxy/blends                 # atlasVert, atlasMain, maskMain, blendingMain
import boxy/blurs                  # blurXMainEs1, blurYMainEs1
import boxy/spreads                # spreadXMain, spreadYMain

when not defined(vita):
  {.error: "vita-only; build via scripts/build_vita.sh".}

proc vglInit(legacyPoolSize: cint) {.importc, header: "vitaGL.h".}
proc vglSwapBuffers(hasCommonDialog: GLboolean) {.importc, header: "vitaGL.h".}
proc sceKernelExitProcess(res: cint): cint
  {.importc, header: "psp2/kernel/processmgr.h", discardable.}

var crumbs: seq[string]
proc crumb(s: string) =
  crumbs.add s
  try:
    createDir("ux0:data")
    writeFile("ux0:data/boxy_vita_probe.txt", crumbs.join("\n") & "\n")
  except CatchableError: discard

proc shaderLog(id: GLuint): string =
  var n: GLsizei
  var buf = newString(2048)
  glGetShaderInfoLog(id, buf.len.GLsizei, n.addr, cast[cstring](buf[0].addr))
  buf.setLen(n.int)
  buf

proc tryCompile(src: string, stage: GLenum): tuple[id: GLuint, ok: bool, log: string] =
  let id = glCreateShader(stage)
  var arr = allocCStringArray([src])
  glShaderSource(id, 1.GLsizei, arr, nil)
  deallocCStringArray(arr)
  glCompileShader(id)
  var status: GLint
  glGetShaderiv(id, GL_COMPILE_STATUS, status.addr)
  (id, status != 0, shaderLog(id).strip())

proc tryLink(vs, fs: GLuint): bool =
  let p = glCreateProgram()
  glAttachShader(p, vs)
  glAttachShader(p, fs)
  glLinkProgram(p)
  var status: GLint
  glGetProgramiv(p, GL_LINK_STATUS, status.addr)
  status != 0

# boxy's 7 programs, in newBoxy order, all from the real glslES1 target. Each pairs a
# fragment main with the shared atlasVert (same as newBoxy).
const vertSrc = toGLSL(atlasVert, glslES1)
const frags = @[
  ("atlas",   toGLSL(atlasMain,    glslES1)),
  ("mask",    toGLSL(maskMain,     glslES1)),
  ("blend",   toGLSL(blendingMain, glslES1)),
  ("blurX",   toGLSL(blurXMainEs1, glslES1)),
  ("blurY",   toGLSL(blurYMainEs1, glslES1)),
  ("spreadX", toGLSL(spreadXMain,  glslES1)),
  ("spreadY", toGLSL(spreadYMain,  glslES1)),
]

proc main() =
  crumb("start; vglInit ...")
  vglInit(0x800000)
  crumb("vglInit OK; compiling shared atlasVert ...")
  let vs = tryCompile(vertSrc, GL_VERTEX_SHADER)
  crumb(&"  atlasVert: ok={vs.ok}" & (if vs.log.len>0: " log="&vs.log else: ""))

  var allOk = vs.ok
  for i, (name, src) in frags:
    crumb(&"START {i+1}/7 compile FRAG {name} ({src.len} ch)")
    let fs = tryCompile(src, GL_FRAGMENT_SHADER)
    crumb(&"  {name} frag: ok={fs.ok}" & (if fs.log.len>0: " log="&fs.log else: ""))
    crumb(&"START {i+1}/7 LINK {name} — if this is the last line, LINK CRASHED here")
    let linked = vs.ok and fs.ok and tryLink(vs.id, fs.id)
    crumb(&"  {name} link: ok={linked}")
    if not linked: allOk = false

  crumb(if allOk: "ALL 7 LINK ok — newBoxy's shaders are fine; crash is elsewhere."
        else:     "DONE with failures — see per-shader lines.")

  glClearColor(0, 0.5, 0, 1)
  for _ in 0 ..< 300:
    glClear(GL_COLOR_BUFFER_BIT)
    vglSwapBuffers(GL_FALSE)
  sceKernelExitProcess(0)

main()
