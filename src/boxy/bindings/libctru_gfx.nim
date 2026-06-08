## Nim FFI bindings for libctru GFX, DVLB shader loading, APT, and SVC.
##
## Binds:
##   libctru GFX:    gfxInitDefault, gfxSwapBuffers, gfxExit, gfxSet3D
##   DVLB/shader:    DVLB_ParseFile, DVLE_GetUniformRegister, shaderProgramInit,
##                   shaderProgramSetVsh, shaderProgramUse, shaderProgramFree
##   APT:            aptMainLoop
##   OS/SVC:         svcSleepThread
##
## Header paths: <3ds/gfx.h>, <3ds/gpu/shbin.h>, <3ds/gpu/shaderProgram.h>,
##               <3ds/services/apt.h>, <3ds/svc.h>
## The -I/opt/devkitpro/libctru/include path is set by nim_3ds.cfg.
##
## Usage: import only when --define:ds3 is active.
## Milestone 2 (boxy-5xs) uses these bindings to load the inline-assembled
## render2d shader (render2d_pica.render2dShbin) and call C3D_Init.

when not defined(ds3):
  {.error: "libctru_gfx.nim must be compiled with --define:ds3 (use scripts/build_3ds.sh)".}

import shader_types
export shader_types

# ---------------------------------------------------------------------------
# DVLB / DVLE shader binary types (from <3ds/gpu/shbin.h>)
#
# DVLB_s is declared with the DVLE and numDVLE fields exposed so the backend
# pass dvlb.DVLE to retrieve the vertex-shader DVLE_s ptr. DVLP_s
# (the program binary container) is left opaque — callers never access it.
# ---------------------------------------------------------------------------

type
  DVLP_s* {.importc: "DVLP_s", header: "<3ds/gpu/shbin.h>".} = object

  ## DVLB shader binary. Obtain via dvlbParseFile; free with dvlbFree.
  ## dvlb.DVLE is ptr DVLE_s pointing at the first (vertex) shader entry.
  DVLB_s* {.importc: "DVLB_s", header: "<3ds/gpu/shbin.h>".} = object
    numDVLE* {.importc: "numDVLE".}: uint32    ## number of DVLE entries
    DVLE* {.importc: "DVLE".}: ptr DVLE_s      ## pointer to the DVLE array

# ShaderProgram_s and DVLE_s are imported from shader_types.nim — the single
# nominal type declaration shared by both this module and citro3d.nim.
# This ensures that a ShaderProgram_s from shaderProgramInit can be passed
# directly to c3dBindProgram without a cast.

# ---------------------------------------------------------------------------
# GFX lifecycle (from <3ds/gfx.h>)
# ---------------------------------------------------------------------------

proc gfxInitDefault*()
  {.importc: "gfxInitDefault", header: "<3ds/gfx.h>".}

proc gfxSwapBuffers*()
  {.importc: "gfxSwapBuffers", header: "<3ds/gfx.h>".}

proc gfxExit*()
  {.importc: "gfxExit", header: "<3ds/gfx.h>".}

proc gfxSet3D*(enable: bool)
  {.importc: "gfxSet3D", header: "<3ds/gfx.h>".}

# ---------------------------------------------------------------------------
# DVLB shader binary parsing (from <3ds/gpu/shbin.h>)
#
# DVLB_ParseFile parses a .shbin blob produced by picasso into a DVLB_s.
# The returned pointer is heap-allocated; free with dvlbFree when done.
# shbinData must remain valid for the lifetime of the DVLB_s.
# ---------------------------------------------------------------------------

proc dvlbParseFile*(shbinData: ptr uint32, shbinSize: uint32): ptr DVLB_s
  {.importc: "DVLB_ParseFile", header: "<3ds/gpu/shbin.h>".}

proc dvlbFree*(dvlb: ptr DVLB_s)
  {.importc: "DVLB_Free", header: "<3ds/gpu/shbin.h>".}

## Returns the uniform register index by name, or -1 if not found.
proc dvleGetUniformRegister*(dvle: ptr DVLE_s, name: cstring): int8
  {.importc: "DVLE_GetUniformRegister", header: "<3ds/gpu/shbin.h>".}

# ---------------------------------------------------------------------------
# Shader program management (from <3ds/gpu/shaderProgram.h>)
#
# Typical usage:
#   var dvlb = dvlbParseFile(shbinData, shbinSize)
#   var prog: ShaderProgram_s
#   discard shaderProgramInit(prog.addr)
#   discard shaderProgramSetVsh(prog.addr, dvlb.DVLE)  # ptr to first DVLE entry
#   c3dBindProgram(prog.addr)   # citro3d.nim proc, same ShaderProgram_s type
#   ...
#   discard shaderProgramFree(prog.addr)
#   dvlbFree(dvlb)
#
# All procs return a libctru Result code (0 = success). Callers should check
# the return value rather than discarding it in production code.
# ---------------------------------------------------------------------------

proc shaderProgramInit*(sp: ptr ShaderProgram_s): int32
  {.importc: "shaderProgramInit", header: "<3ds/gpu/shaderProgram.h>".}

proc shaderProgramFree*(sp: ptr ShaderProgram_s): int32
  {.importc: "shaderProgramFree", header: "<3ds/gpu/shaderProgram.h>".}

proc shaderProgramSetVsh*(sp: ptr ShaderProgram_s, dvle: ptr DVLE_s): int32
  {.importc: "shaderProgramSetVsh", header: "<3ds/gpu/shaderProgram.h>".}

## shaderProgramUse = shaderProgramConfigure(true, true) + upload DVLE constants.
## Alternative to c3dBindProgram when the program is not yet active.
proc shaderProgramUse*(sp: ptr ShaderProgram_s): int32
  {.importc: "shaderProgramUse", header: "<3ds/gpu/shaderProgram.h>".}

# ---------------------------------------------------------------------------
# APT (Application Manager) — from <3ds/services/apt.h>
#
# aptMainLoop returns false when the HOME button requests app exit; the main
# loop should terminate when it returns false.
# ---------------------------------------------------------------------------

proc aptMainLoop*(): bool
  {.importc: "aptMainLoop", header: "<3ds/services/apt.h>".}

# ---------------------------------------------------------------------------
# SVC (System-call wrappers) — from <3ds/svc.h>
#
# svcSleepThread sleeps for the specified number of nanoseconds.
# ---------------------------------------------------------------------------

proc svcSleepThread*(ns: int64)
  {.importc: "svcSleepThread", header: "<3ds/svc.h>".}
