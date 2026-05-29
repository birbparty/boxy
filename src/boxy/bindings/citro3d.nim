## Nim FFI bindings for citro3d — 3DS hardware-accelerated 3D rendering library.
##
## Binds: C3D_Init/Fini, texture management (C3D_Tex), render targets,
## TEV stage configuration, attribute/buffer info, alpha blending, draw calls.
##
## Header: <citro3d.h> (at /opt/devkitpro/libctru/include/citro3d.h).
## The -I path is injected by nim_3ds.cfg which scripts/build_3ds.sh copies to nim.cfg.
##
## Usage: import only when --define:ds3 is active.
## FFI style follows /Users/punk1290/git/raylib-nim-multiplatform/src/bindings/raylib_console.nim.

when not defined(ds3):
  {.error: "citro3d.nim must be compiled with --define:ds3 (use scripts/build_3ds.sh)".}

# ---------------------------------------------------------------------------
# GPU enum types and constants
#
# C uses C-enums that decay to int in function calls.
# Nim models them as distinct int32 so callers get type safety without casts
# at the call sites (Nim accepts same distinct type at matching params).
# Values are copied verbatim from /opt/devkitpro/libctru/include/3ds/gpu/enums.h.
# ---------------------------------------------------------------------------

type
  GpuTexColor*       = distinct int32
  GpuColorBuf*       = distinct int32
  GpuDepthBuf*       = distinct int32
  GpuPrimitive*      = distinct int32
  GpuTexFace*        = distinct int32
  GpuFormats*        = distinct int32
  GpuTevSrc*         = distinct int32
  GpuCombineFunc*    = distinct int32
  GpuBlendEquation*  = distinct int32
  GpuBlendFactor*    = distinct int32
  GpuShaderType*     = distinct int32
  GfxScreen*         = distinct int32
  Gfx3dSide*         = distinct int32

const
  # GPU_TEXCOLOR
  GPU_RGBA8*    = GpuTexColor(0x0)
  GPU_RGB8*     = GpuTexColor(0x1)
  GPU_RGBA5551* = GpuTexColor(0x2)
  GPU_RGB565*   = GpuTexColor(0x3)
  GPU_RGBA4*    = GpuTexColor(0x4)

  # GPU_COLORBUF
  GPU_RB_RGBA8*    = GpuColorBuf(0x0)
  GPU_RB_BGR8*     = GpuColorBuf(0x1)
  GPU_RB_RGBA5551* = GpuColorBuf(0x2)
  GPU_RB_RGB565*   = GpuColorBuf(0x3)
  GPU_RB_RGBA4*    = GpuColorBuf(0x4)

  # GPU_DEPTHBUF
  GPU_RB_DEPTH24*          = GpuDepthBuf(0x2)
  GPU_RB_DEPTH24_STENCIL8* = GpuDepthBuf(0x3)

  # GPU_Primitive_t
  GPU_TRIANGLES*      = GpuPrimitive(0x0000)
  GPU_TRIANGLE_STRIP* = GpuPrimitive(0x0100)
  GPU_TRIANGLE_FAN*   = GpuPrimitive(0x0200)

  # GPU_TEXFACE
  GPU_TEXFACE_2D* = GpuTexFace(0)

  # GPU_FORMATS
  GPU_BYTE_FORMAT*     = GpuFormats(0)
  GPU_UNSIGNED_BYTE*   = GpuFormats(1)
  GPU_SHORT_FORMAT*    = GpuFormats(2)
  GPU_FLOAT_FORMAT*    = GpuFormats(4)

  # GPU_TEVSRC
  GPU_PRIMARY_COLOR* = GpuTevSrc(0x00)
  GPU_TEXTURE0*      = GpuTevSrc(0x03)
  GPU_TEXTURE1*      = GpuTevSrc(0x04)
  GPU_TEXTURE2*      = GpuTevSrc(0x05)
  GPU_CONSTANT_TEV*  = GpuTevSrc(0x0E)
  GPU_PREVIOUS*      = GpuTevSrc(0x0F)

  # GPU_COMBINEFUNC
  GPU_REPLACE*      = GpuCombineFunc(0x00)
  GPU_MODULATE*     = GpuCombineFunc(0x01)
  GPU_ADD*          = GpuCombineFunc(0x02)
  GPU_ADD_SIGNED*   = GpuCombineFunc(0x03)
  GPU_INTERPOLATE*  = GpuCombineFunc(0x04)
  GPU_SUBTRACT*     = GpuCombineFunc(0x05)

  # GPU_BLENDEQUATION
  GPU_BLEND_ADD*              = GpuBlendEquation(0)
  GPU_BLEND_SUBTRACT*         = GpuBlendEquation(1)
  GPU_BLEND_REVERSE_SUBTRACT* = GpuBlendEquation(2)
  GPU_BLEND_MIN*              = GpuBlendEquation(3)
  GPU_BLEND_MAX*              = GpuBlendEquation(4)

  # GPU_BLENDFACTOR
  GPU_ZERO*                    = GpuBlendFactor(0)
  GPU_ONE*                     = GpuBlendFactor(1)
  GPU_SRC_COLOR*               = GpuBlendFactor(2)
  GPU_ONE_MINUS_SRC_COLOR*     = GpuBlendFactor(3)
  GPU_DST_COLOR*               = GpuBlendFactor(4)
  GPU_ONE_MINUS_DST_COLOR*     = GpuBlendFactor(5)
  GPU_SRC_ALPHA*               = GpuBlendFactor(6)
  GPU_ONE_MINUS_SRC_ALPHA*     = GpuBlendFactor(7)
  GPU_DST_ALPHA*               = GpuBlendFactor(8)
  GPU_ONE_MINUS_DST_ALPHA*     = GpuBlendFactor(9)
  GPU_CONSTANT_COLOR_BF*       = GpuBlendFactor(10)
  GPU_ONE_MINUS_CONSTANT_COLOR* = GpuBlendFactor(11)
  GPU_CONSTANT_ALPHA*          = GpuBlendFactor(12)
  GPU_ONE_MINUS_CONSTANT_ALPHA* = GpuBlendFactor(13)
  GPU_SRC_ALPHA_SATURATE*      = GpuBlendFactor(14)

  # GPU_SHADER_TYPE
  GPU_VERTEX_SHADER_TYPE*   = GpuShaderType(0)
  GPU_GEOMETRY_SHADER_TYPE* = GpuShaderType(1)

  # gfxScreen_t
  GFX_TOP*    = GfxScreen(0)
  GFX_BOTTOM* = GfxScreen(1)

  # gfx3dSide_t
  GFX_LEFT*  = Gfx3dSide(0)
  GFX_RIGHT* = Gfx3dSide(1)

  # C3D_TexEnvMode bit flags (used as int params, not enum)
  C3D_RGB_MODE*   = 1
  C3D_ALPHA_MODE* = 2
  C3D_BOTH_MODE*  = 3

  C3D_DEFAULT_CMDBUF_SIZE* = 0x40000

# ---------------------------------------------------------------------------
# Opaque struct types
#
# Declared with {.importc, header.} so the C compiler resolves sizeof from
# the included header. Do NOT access struct fields directly from Nim — use
# the bound C functions for all interactions.
# ---------------------------------------------------------------------------

type
  C3D_Tex* {.importc: "C3D_Tex", header: "citro3d.h".} = object
  C3D_TexCube* {.importc: "C3D_TexCube", header: "citro3d.h".} = object
  C3D_TexInitParams* {.importc: "C3D_TexInitParams", header: "citro3d.h", bycopy.} = object
  C3D_TexEnv* {.importc: "C3D_TexEnv", header: "citro3d.h".} = object
  C3D_AttrInfo* {.importc: "C3D_AttrInfo", header: "citro3d.h".} = object
  C3D_BufInfo* {.importc: "C3D_BufInfo", header: "citro3d.h".} = object
  C3D_RenderTarget* {.importc: "C3D_RenderTarget", header: "citro3d.h".} = object
  C3D_FVec* {.importc: "C3D_FVec", header: "citro3d.h", bycopy.} = object
  C3D_Mtx* {.importc: "C3D_Mtx", header: "citro3d.h".} = object

  ## C3D_DEPTHTYPE is a transparent union (int | GPU_DEPTHBUF). Since GCC
  ## transparent_union allows passing int where this type is expected, we bind
  ## the parameter as int32. Pass -1 for "no depth buffer".
  ## Callers: cast GpuDepthBuf to int32, or pass -1.

  ## shaderProgram_s forward declaration for C3D_BindProgram.
  ## Full definition lives in libctru_gfx.nim; forward-declare to avoid import cycle.
  ShaderProgram_s* {.importc: "shaderProgram_s",
                     header: "<3ds/gpu/shaderProgram.h>".} = object

# ---------------------------------------------------------------------------
# C3D_Init / Fini
# ---------------------------------------------------------------------------

proc c3dInit*(cmdBufSize: int): bool
  {.importc: "C3D_Init", header: "citro3d.h".}

proc c3dFini*()
  {.importc: "C3D_Fini", header: "citro3d.h".}

# ---------------------------------------------------------------------------
# Shader binding
# ---------------------------------------------------------------------------

proc c3dBindProgram*(program: ptr ShaderProgram_s)
  {.importc: "C3D_BindProgram", header: "citro3d.h".}

# ---------------------------------------------------------------------------
# Texture management
#
# C3D_TexInit and C3D_TexInitVRAM are static inline wrappers around
# C3D_TexInitWithParams. All three are importable — GCC inlines the static ones.
# ---------------------------------------------------------------------------

proc c3dTexInitWithParams*(tex: ptr C3D_Tex, cube: ptr C3D_TexCube,
                            p: C3D_TexInitParams): bool
  {.importc: "C3D_TexInitWithParams", header: "citro3d.h".}

proc c3dTexInit*(tex: ptr C3D_Tex, width, height: uint16,
                 format: GpuTexColor): bool
  {.importc: "C3D_TexInit", header: "citro3d.h".}

## VRAM-resident texture — required for atlas textures that serve as both
## render target and sample source in grow().
proc c3dTexInitVram*(tex: ptr C3D_Tex, width, height: uint16,
                     format: GpuTexColor): bool
  {.importc: "C3D_TexInitVRAM", header: "citro3d.h".}

## C3D_TexLoadImage is the real upload function; C3D_TexUpload is a static
## inline convenience that calls it with face=GPU_TEXFACE_2D, level=0.
proc c3dTexLoadImage*(tex: ptr C3D_Tex, data: pointer,
                      face: GpuTexFace, level: int32)
  {.importc: "C3D_TexLoadImage", header: "citro3d.h".}

proc c3dTexUpload*(tex: ptr C3D_Tex, data: pointer)
  {.importc: "C3D_TexUpload", header: "citro3d.h".}

proc c3dTexFlush*(tex: ptr C3D_Tex)
  {.importc: "C3D_TexFlush", header: "citro3d.h".}

proc c3dTexDelete*(tex: ptr C3D_Tex)
  {.importc: "C3D_TexDelete", header: "citro3d.h".}

proc c3dTexBind*(unitId: int32, tex: ptr C3D_Tex)
  {.importc: "C3D_TexBind", header: "citro3d.h".}

# ---------------------------------------------------------------------------
# Render targets and frame management
#
# depthFmt: pass -1 for no depth buffer; cast GpuDepthBuf.int32 for depth.
# See C3D_DEPTHTYPE note above — transparent union accepts int directly.
# ---------------------------------------------------------------------------

proc c3dRenderTargetCreate*(width, height: int32,
                             colorFmt: GpuColorBuf,
                             depthFmt: int32): ptr C3D_RenderTarget
  {.importc: "C3D_RenderTargetCreate", header: "citro3d.h".}

proc c3dRenderTargetCreateFromTex*(tex: ptr C3D_Tex, face: GpuTexFace,
                                   level: int32,
                                   depthFmt: int32): ptr C3D_RenderTarget
  {.importc: "C3D_RenderTargetCreateFromTex", header: "citro3d.h".}

proc c3dRenderTargetDelete*(target: ptr C3D_RenderTarget)
  {.importc: "C3D_RenderTargetDelete", header: "citro3d.h".}

proc c3dRenderTargetSetOutput*(target: ptr C3D_RenderTarget,
                                screen: GfxScreen, side: Gfx3dSide,
                                transferFlags: uint32)
  {.importc: "C3D_RenderTargetSetOutput", header: "citro3d.h".}

proc c3dFrameBegin*(flags: uint8): bool
  {.importc: "C3D_FrameBegin", header: "citro3d.h".}

proc c3dFrameDrawOn*(target: ptr C3D_RenderTarget): bool
  {.importc: "C3D_FrameDrawOn", header: "citro3d.h".}

proc c3dFrameEnd*(flags: uint8)
  {.importc: "C3D_FrameEnd", header: "citro3d.h".}

# ---------------------------------------------------------------------------
# Draw calls
# ---------------------------------------------------------------------------

proc c3dDrawElements*(primitive: GpuPrimitive, count: int32,
                      typ: int32, indices: pointer)
  {.importc: "C3D_DrawElements", header: "citro3d.h".}

proc c3dDrawArrays*(primitive: GpuPrimitive, first: int32, size: int32)
  {.importc: "C3D_DrawArrays", header: "citro3d.h".}

# ---------------------------------------------------------------------------
# TEV stage configuration
#
# C3D_TexEnvSrc and C3D_TexEnvFunc are static inline — GCC inlines them.
# mode parameter: C3D_RGB_MODE (1), C3D_ALPHA_MODE (2), or C3D_BOTH_MODE (3).
# ---------------------------------------------------------------------------

proc c3dGetTexEnv*(id: int32): ptr C3D_TexEnv
  {.importc: "C3D_GetTexEnv", header: "citro3d.h".}

proc c3dSetTexEnv*(id: int32, env: ptr C3D_TexEnv)
  {.importc: "C3D_SetTexEnv", header: "citro3d.h".}

proc c3dDirtyTexEnv*(env: ptr C3D_TexEnv)
  {.importc: "C3D_DirtyTexEnv", header: "citro3d.h".}

proc c3dTexEnvInit*(env: ptr C3D_TexEnv)
  {.importc: "C3D_TexEnvInit", header: "citro3d.h".}

proc c3dTexEnvSrc*(env: ptr C3D_TexEnv, mode: int32,
                   s1: GpuTevSrc, s2: GpuTevSrc, s3: GpuTevSrc)
  {.importc: "C3D_TexEnvSrc", header: "citro3d.h".}

proc c3dTexEnvFunc*(env: ptr C3D_TexEnv, mode: int32, param: GpuCombineFunc)
  {.importc: "C3D_TexEnvFunc", header: "citro3d.h".}

proc c3dTexEnvColor*(env: ptr C3D_TexEnv, color: uint32)
  {.importc: "C3D_TexEnvColor", header: "citro3d.h".}

proc c3dTexEnvBufColor*(color: uint32)
  {.importc: "C3D_TexEnvBufColor", header: "citro3d.h".}

# ---------------------------------------------------------------------------
# Alpha blending and depth test
# ---------------------------------------------------------------------------

proc c3dAlphaBlend*(colorEq: GpuBlendEquation, alphaEq: GpuBlendEquation,
                    srcClr: GpuBlendFactor, dstClr: GpuBlendFactor,
                    srcAlpha: GpuBlendFactor, dstAlpha: GpuBlendFactor)
  {.importc: "C3D_AlphaBlend", header: "citro3d.h".}

proc c3dDepthTest*(enable: bool, function: int32, writemask: int32)
  {.importc: "C3D_DepthTest", header: "citro3d.h".}

# ---------------------------------------------------------------------------
# Attribute and buffer info
# ---------------------------------------------------------------------------

proc attrInfoInit*(info: ptr C3D_AttrInfo)
  {.importc: "AttrInfo_Init", header: "citro3d.h".}

proc attrInfoAddLoader*(info: ptr C3D_AttrInfo, regId: int32,
                        format: GpuFormats, count: int32): int32
  {.importc: "AttrInfo_AddLoader", header: "citro3d.h".}

proc attrInfoAddFixed*(info: ptr C3D_AttrInfo, regId: int32): int32
  {.importc: "AttrInfo_AddFixed", header: "citro3d.h".}

proc c3dGetAttrInfo*(): ptr C3D_AttrInfo
  {.importc: "C3D_GetAttrInfo", header: "citro3d.h".}

proc c3dSetAttrInfo*(info: ptr C3D_AttrInfo)
  {.importc: "C3D_SetAttrInfo", header: "citro3d.h".}

proc bufInfoInit*(info: ptr C3D_BufInfo)
  {.importc: "BufInfo_Init", header: "citro3d.h".}

## stride: bytes between consecutive vertex records.
## permutation: u64 that maps buffer slots to vertex attributes; see BufInfo_Add docs.
proc bufInfoAdd*(info: ptr C3D_BufInfo, data: pointer,
                 stride: int, attribCount: int32, permutation: uint64): int32
  {.importc: "BufInfo_Add", header: "citro3d.h".}

proc c3dGetBufInfo*(): ptr C3D_BufInfo
  {.importc: "C3D_GetBufInfo", header: "citro3d.h".}

proc c3dSetBufInfo*(info: ptr C3D_BufInfo)
  {.importc: "C3D_SetBufInfo", header: "citro3d.h".}

# ---------------------------------------------------------------------------
# Fixed vertex attributes
# ---------------------------------------------------------------------------

proc c3dFixedAttribGetWritePtr*(id: int32): ptr C3D_FVec
  {.importc: "C3D_FixedAttribGetWritePtr", header: "citro3d.h".}

proc c3dFixedAttribSet*(id: int32, x, y, z, w: float32)
  {.importc: "C3D_FixedAttribSet", header: "citro3d.h".}

# ---------------------------------------------------------------------------
# Projection / uniform upload
# ---------------------------------------------------------------------------

proc c3dFVUnifMtx4x4*(typ: GpuShaderType, id: int32, mtx: ptr C3D_Mtx)
  {.importc: "C3D_FVUnifMtx4x4", header: "citro3d.h".}
