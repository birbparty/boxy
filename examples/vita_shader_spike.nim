## vita_shader_spike.nim — Phase 0 decision spike for boxy on Sony PS Vita.
##
## THE QUESTION THIS ANSWERS: does our vitaGL build accept boxy's existing GLES
## shaders (`"300 es"`, the emscripten path)? The answer decides the whole port:
##   - compiles + links  -> REUSE the emscripten shader path  (plan Phase 1A, easy)
##   - rejected          -> need GLSL ES 1.00 variants         (plan Phase 1B + shady)
##
## It deliberately does NOT touch boxy's src or call newBoxy. It generates boxy's
## REAL shader sources at compile time via shady.toGLSL (the exact strings
## src/boxy.nim's emscripten branch would feed to the GPU) and compiles them through
## vitaGL with raw GL calls, reporting per-shader status. This is throwaway — once
## the result is recorded in .agents/plans/vita-support/RESULTS.md, the real
## examples/basic_vita.nim (newBoxy render loop) follows in Phase 1A.
##
## Build:  scripts/build_vita.sh examples/vita_shader_spike.nim
## Run:    Vita3K (weaker — hides -Wl,-q reloc bugs) AND real hardware (gold).
## Result: printed to stdout (Vita3K log) AND written to
##         ux0:data/boxy_vita_shader_spike.txt (read off the card / ux0 dir).

import std/[os, strformat, strutils]
import opengl
import shady
# boxy's real shader DSL procs (each module imports only `shady, vmath` — pure):
import boxy/blends   # atlasVert, atlasMain, maskMain, blendingMain
import boxy/blurs    # blurXMain, blurYMain
import boxy/spreads  # spreadXMain, spreadYMain

when not defined(vita):
  {.error: "vita_shader_spike is a -d:vita-only harness; build via scripts/build_vita.sh".}

# --- minimal vitaGL / Sce FFI (only what the spike needs) ------------------------
proc vglInit(legacyPoolSize: cint) {.importc, header: "vitaGL.h".}
proc vglSwapBuffers(hasCommonDialog: GLboolean) {.importc, header: "vitaGL.h".}
proc sceKernelExitProcess(res: cint): cint
  {.importc, header: "psp2/kernel/processmgr.h", discardable.}

type ShaderCase = object
  name: string
  vert: string
  frag: string

# All 7 programs boxy builds, in the same vert+main pairing as the emscripten block.
# NOTE: shady.toGLSL reads `version.strVal`/`extra.strVal` off the AST node passed,
# so the "300 es" and precision args MUST be inline string LITERALS — a `const`
# identifier is taken literally as its name ("ES"), silently emitting `#version ES`
# AND selecting the desktop dialect (`"es" in "ES"` is false). Match src/boxy.nim.
const cases = @[
  ShaderCase(name: "atlas",   vert: toGLSL(atlasVert, "300 es", "precision highp float;\n"), frag: toGLSL(atlasMain, "300 es", "precision highp float;\n")),
  ShaderCase(name: "mask",    vert: toGLSL(atlasVert, "300 es", "precision highp float;\n"), frag: toGLSL(maskMain, "300 es", "precision highp float;\n")),
  ShaderCase(name: "blend",   vert: toGLSL(atlasVert, "300 es", "precision highp float;\n"), frag: toGLSL(blendingMain, "300 es", "precision highp float;\n")),
  ShaderCase(name: "blurX",   vert: toGLSL(atlasVert, "300 es", "precision highp float;\n"), frag: toGLSL(blurXMain, "300 es", "precision highp float;\n")),
  ShaderCase(name: "blurY",   vert: toGLSL(atlasVert, "300 es", "precision highp float;\n"), frag: toGLSL(blurYMain, "300 es", "precision highp float;\n")),
  ShaderCase(name: "spreadX", vert: toGLSL(atlasVert, "300 es", "precision highp float;\n"), frag: toGLSL(spreadXMain, "300 es", "precision highp float;\n")),
  ShaderCase(name: "spreadY", vert: toGLSL(atlasVert, "300 es", "precision highp float;\n"), frag: toGLSL(spreadYMain, "300 es", "precision highp float;\n")),
]

var report: seq[string]
proc note(s: string) =
  report.add s
  echo s

proc glStr(name: GLenum): string =
  let p = glGetString(name)
  if p == nil: "<nil>" else: $cast[cstring](p)

proc compileStage(src: string, stage: GLenum): tuple[id: GLuint, ok: bool, log: string] =
  let id = glCreateShader(stage)
  var arr = allocCStringArray([src])
  glShaderSource(id, 1.GLsizei, arr, nil)
  deallocCStringArray(arr)
  glCompileShader(id)
  var status: GLint
  glGetShaderiv(id, GL_COMPILE_STATUS, status.addr)
  var logBuf = newString(2048)
  var n: GLsizei
  glGetShaderInfoLog(id, logBuf.len.GLsizei, n.addr, cast[cstring](logBuf[0].addr))
  logBuf.setLen(n.int)
  (id, status != 0, logBuf.strip())

proc linkProgram(vs, fs: GLuint): tuple[ok: bool, log: string] =
  let prog = glCreateProgram()
  glAttachShader(prog, vs)
  glAttachShader(prog, fs)
  glLinkProgram(prog)
  var status: GLint
  glGetProgramiv(prog, GL_LINK_STATUS, status.addr)
  var logBuf = newString(2048)
  var n: GLsizei
  glGetProgramInfoLog(prog, logBuf.len.GLsizei, n.addr, cast[cstring](logBuf[0].addr))
  logBuf.setLen(n.int)
  (status != 0, logBuf.strip())

proc main() =
  vglInit(0x800000)   # 8 MiB GPU command pool; creates the GLES context

  note "=== boxy Vita shader spike (300 es) ==="
  note &"GL_VENDOR   : {glStr(GL_VENDOR)}"
  note &"GL_RENDERER : {glStr(GL_RENDERER)}"
  note &"GL_VERSION  : {glStr(GL_VERSION)}"
  note &"GLSL_VERSION: {glStr(GL_SHADING_LANGUAGE_VERSION)}"

  # VAO probe — boxy uses glGenVertexArrays/glBindVertexArray (core GLES2 lacks VAOs;
  # vitaGL implements them). Confirm a VAO can be created without a GL error.
  var vao: GLuint
  glGenVertexArrays(1, vao.addr)
  let vaoErr = glGetError()
  note &"VAO probe   : id={vao} glGetError={vaoErr.int} (0 == GL_NO_ERROR == VAOs OK)"

  var allOk = true
  for c in cases:
    let v = compileStage(c.vert, GL_VERTEX_SHADER)
    let f = compileStage(c.frag, GL_FRAGMENT_SHADER)
    var line = &"[{c.name}] vert={v.ok} frag={f.ok}"
    if v.ok and f.ok:
      let l = linkProgram(v.id, f.id)
      line &= &" link={l.ok}"
      if not l.ok: line &= &"\n  LINK LOG: {l.log}"
    if not v.ok: line &= &"\n  VERT LOG: {v.log}"
    if not f.ok: line &= &"\n  FRAG LOG: {f.log}"
    if not (v.ok and f.ok): allOk = false
    note line

  note(if allOk: "RESULT: PASS — vitaGL accepts boxy's 300 es shaders. Take Phase 1A (reuse)."
       else:     "RESULT: FAIL — at least one shader rejected. Take Phase 1B (GLSL ES 1.00).")

  # Persist a machine-readable marker (newlib reaches ux0: with no shim — proven by
  # configy). Read it off the memory card / Vita3K's ux0 dir.
  try:
    createDir("ux0:data")
    writeFile("ux0:data/boxy_vita_shader_spike.txt", report.join("\n") & "\n")
  except CatchableError as e:
    echo "could not write ux0:data marker: ", e.msg

  # Visual signal + keep the window up briefly: green = all passed, red = a failure.
  if allOk: glClearColor(0, 0.6, 0, 1) else: glClearColor(0.6, 0, 0, 1)
  for _ in 0 ..< 600:           # ~10s at 60fps, then exit cleanly
    glClear(GL_COLOR_BUFFER_BIT)
    vglSwapBuffers(GL_FALSE)
  sceKernelExitProcess(0)

main()
