## Nim FFI bindings for libctru GFX, DVLB shader loading, APT, and SVC.
##
## Binds:
##   libctru GFX:    gfxInitDefault, gfxSwapBuffers, gfxExit, gfxSet3D
##   DVLB/shader:    DVLB_ParseFile, DVLE_GetUniformRegister, shaderProgramInit,
##                   shaderProgramSetVsh, shaderProgramBind, shaderProgramFree
##   APT:            aptMainLoop
##   OS/SVC:         svcSleepThread
##
## Header paths: <3ds/gfx.h>, <3ds/gpu/shbin.h>, <3ds/gpu/shaderProgram.h>,
##               <3ds/services/apt.h>, <3ds/svc.h>
## The -I/opt/devkitpro/libctru/include path is set by nim_3ds.cfg.
##
## Usage: import only when --define:ds3 is active.
## Milestone 2 (boxy-5xs) uses these bindings to load render2d.shbin and call C3D_Init.

when not defined(ds3):
  {.error: "libctru_gfx.nim must be compiled with --define:ds3 (use scripts/build_3ds.sh)".}

# ---------------------------------------------------------------------------
# DVLB / DVLE shader binary types (from <3ds/gpu/shbin.h>)
#
# Opaque structs — all interactions go through C functions.
# DVLP_s and DVLE_s are nested inside DVLB_s; we expose only what callers need.
# ---------------------------------------------------------------------------

type
  DVLP_s* {.importc: "DVLP_s", header: "<3ds/gpu/shbin.h>".} = object
  DVLE_s* {.importc: "DVLE_s", header: "<3ds/gpu/shbin.h>".} = object
  DVLB_s* {.importc: "DVLB_s", header: "<3ds/gpu/shbin.h>".} = object

  ## Full shaderProgram_s — also forward-declared in citro3d.nim.
  ## If both modules are imported, the importc pragma guarantees they map to
  ## the same C type; Nim type-checks them as the same symbol.
  ShaderProgram_s* {.importc: "shaderProgram_s",
                     header: "<3ds/gpu/shaderProgram.h>".} = object

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
# The returned pointer is heap-allocated; free with DVLB_Free when done.
# shbinData must remain valid for the lifetime of the DVLB_s.
# ---------------------------------------------------------------------------

proc dvlbParseFile*(shbinData: ptr uint32, shbinSize: uint32): ptr DVLB_s
  {.importc: "DVLB_ParseFile", header: "<3ds/gpu/shbin.h>".}

proc dvlbFree*(dvlb: ptr DVLB_s)
  {.importc: "DVLB_Free", header: "<3ds/gpu/shbin.h>".}

## Returns the index of a uniform register by name, or -1 if not found.
proc dvleGetUniformRegister*(dvle: ptr DVLE_s, name: cstring): int8
  {.importc: "DVLE_GetUniformRegister", header: "<3ds/gpu/shbin.h>".}

# ---------------------------------------------------------------------------
# Shader program management (from <3ds/gpu/shaderProgram.h>)
#
# Typical usage:
##   var prog: ShaderProgram_s
##   discard shaderProgramInit(prog.addr)
##   discard shaderProgramSetVsh(prog.addr, dvlb.DVLE)   # first DVLE entry
##   shaderProgramBind(prog.addr)   # via c3dBindProgram
##   ...
##   discard shaderProgramFree(prog.addr)
# ---------------------------------------------------------------------------

## Returns a libctru Result code (0 = success).
proc shaderProgramInit*(sp: ptr ShaderProgram_s): int32
  {.importc: "shaderProgramInit", header: "<3ds/gpu/shaderProgram.h>".}

proc shaderProgramFree*(sp: ptr ShaderProgram_s): int32
  {.importc: "shaderProgramFree", header: "<3ds/gpu/shaderProgram.h>".}

proc shaderProgramSetVsh*(sp: ptr ShaderProgram_s, dvle: ptr DVLE_s): int32
  {.importc: "shaderProgramSetVsh", header: "<3ds/gpu/shaderProgram.h>".}

## shaderProgramUse = shaderProgramConfigure(true, true) + upload DVLE consts.
## Equivalent to what C3D_BindProgram does internally for the active program.
proc shaderProgramUse*(sp: ptr ShaderProgram_s): int32
  {.importc: "shaderProgramUse", header: "<3ds/gpu/shaderProgram.h>".}

# ---------------------------------------------------------------------------
# APT (Application Manager) — from <3ds/services/apt.h>
#
# aptMainLoop returns false when the HOME button closes the app; the main
# loop should exit when it returns false.
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
