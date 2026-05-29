## Shared shader type declarations for the 3DS FFI bindings.
##
## ShaderProgram_s and DVLE_s are used by BOTH citro3d.nim (c3dBindProgram)
## and libctru_gfx.nim (shaderProgramInit / shaderProgramSetVsh).
##
## Nim uses nominal typing: two independent `{.importc.} = object` declarations
## for the same C type become TWO distinct Nim types, even if the importc name
## matches. Values from one cannot be passed to procs expecting the other without
## a cast. Declaring them ONCE here and importing from both modules gives a single
## nominal type that flows freely across the two call sites.

when not defined(ds3):
  {.error: "shader_types.nim must be compiled with --define:ds3".}

type
  ## libctru DVLE (shader entry-point within a DVLB binary).
  ## Obtained via dvlb.DVLE[0] after parsing a .shbin with DVLB_ParseFile.
  DVLE_s* {.importc: "DVLE_s", header: "<3ds/gpu/shbin.h>".} = object

  ## libctru shader program. Stack-allocate in the backend, then pass by
  ## pointer to shaderProgramInit → shaderProgramSetVsh → c3dBindProgram.
  ShaderProgram_s* {.importc: "shaderProgram_s",
                     header: "<3ds/gpu/shaderProgram.h>".} = object
