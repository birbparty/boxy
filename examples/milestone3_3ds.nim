## Milestone 3 gate: single textured quad renders on Azahar top screen.
##
## Tests the full swizzle/upload/TEV/draw path in isolation, bypassing
## boxy atlas and pixie entirely:
##   1. 16×16 RGBA8 test image (4-quadrant: red/green/blue/yellow) in memory
##   2. Morton-swizzled via swizzleTileIntoAtlas into linearAlloc buffer
##   3. Uploaded to VRAM texture (C3D_TexInitVRAM + C3D_TexUpload)
##   4. TEV stage 0: GPU_REPLACE — texture color pass-through
##   5. C3D_CullFace(GPU_CULL_NONE) — eliminates winding as failure variable
##   6. One C3D_DrawElements call (6 uint16 indices, two CCW triangles)
##   7. Top screen render target (240×400 GPU fb) with OrthoTilt projection
##
## OrthoTilt projection: topScreenOrthoProj(400f, 240f) from citro3d_backend.
##   clip_x = -(2/240)*y + 1   (logical Y drives GPU horizontal)
##   clip_y = -(2/400)*x + 1   (logical X drives GPU vertical)
##   Verified: center(200,120)→clip(0,0); corners→physical screen corners.
##
## Quad: 200×200 logical square centered on the 400×240 screen.
##   BL(100,220) BR(300,220) TR(300,20) TL(100,20)
##   UV: BL=(0,0) BR=(1,0) TR=(1,1) TL=(0,1)
##
## Expected visual: 4-color square on black background.
##   If PICA200 V=0=top: top-left=red, top-right=green, BL=blue, BR=yellow.
##   If PICA200 V=0=bottom: top-left=blue, top-right=yellow, BL=red, BR=green.
##   Either outcome confirms the full path works.
##
## Build: scripts/build_3ds.sh examples/milestone3_3ds.nim milestone3_3ds
## Run:   load build/milestone3_3ds.3dsx in Azahar; exit via HOME button

when not defined(ds3):
  {.error: "milestone3_3ds.nim must be compiled with --define:ds3 (use scripts/build_3ds.sh)".}

import boxy/bindings/libctru_gfx
import boxy/bindings/citro3d
import boxy/backends/citro3d_backend  # swizzleTileIntoAtlas

const shbinRaw = staticRead("../build/render2d.shbin")

# GX transfer flags: RGBA8 framebuffer → RGB8 display output.
# GX_TRANSFER_IN_FORMAT(RGBA8=0)=0 | GX_TRANSFER_OUT_FORMAT(RGB8=1)=0x1000
const DISPLAY_FLAGS = 0x1000'u32

# OrthoTilt projection for 400×240 Y-down logical space, sourced from
# citro3d_backend.topScreenOrthoProj — the single canonical definition for
# the top-screen rotated projection (the compositing and identity matrices in
# the backend are separate, non-rotated projections with different purposes).
# See that function for the full derivation and PICA200 layout details.
let projMat = topScreenOrthoProj(400f, 240f)

# Vertex layout matching render2d.v.pica:
#   v0 = position (x, y)      GPU_FLOAT × 2
#   v1 = UV (u, v)            GPU_FLOAT × 2
#   v2 = color (r, g, b, a)   GPU_UNSIGNED_BYTE × 4
type Vertex {.packed.} = object
  x, y:    float32
  u, v:    float32
  r, g, b, a: uint8

# ---------------------------------------------------------------------------
# Init
# ---------------------------------------------------------------------------

gfxInitDefault()
gfxSet3D(false)

if not c3dInit(C3D_DEFAULT_CMDBUF_SIZE):
  gfxExit(); quit(1)

# Shader: parse embedded render2d.shbin
var shbinBuf = shbinRaw  # mutable copy so we can take addr
let dvlb = dvlbParseFile(cast[ptr uint32](addr shbinBuf[0]), shbinBuf.len.uint32)
if dvlb == nil or dvlb.numDVLE < 1:
  c3dFini(); gfxExit(); quit(1)

var prog: ShaderProgram_s
if shaderProgramInit(addr prog) != 0 or
   shaderProgramSetVsh(addr prog, dvlb.DVLE) != 0:
  dvlbFree(dvlb); c3dFini(); gfxExit(); quit(1)

let projReg = dvleGetUniformRegister(dvlb.DVLE, "projection")
if projReg < 0:
  discard shaderProgramFree(addr prog)
  dvlbFree(dvlb); c3dFini(); gfxExit(); quit(1)

# Top screen render target: 240 wide × 400 tall in GPU framebuffer coordinates.
# C3D_RenderTargetSetOutput wires it to the physical 400×240 LCD via 90° rotation.
let topTarget = c3dRenderTargetCreate(240, 400, GPU_RB_RGBA8, -1)
if topTarget == nil:
  discard shaderProgramFree(addr prog)
  dvlbFree(dvlb); c3dFini(); gfxExit(); quit(1)
c3dRenderTargetSetOutput(topTarget, GFX_TOP, GFX_LEFT, DISPLAY_FLAGS)

# ---------------------------------------------------------------------------
# 16×16 RGBA8 test texture: 4-quadrant color pattern
#
# Pixie ColorRGBX uint32 layout (as read by swizzleTileIntoAtlas):
#   bits 31-24 = alpha, 23-16 = blue, 15-8 = green, 7-0 = red
#   i.e. uint32 = (a << 24) | (b << 16) | (g << 8) | r
#
# Quadrants (sx = column 0–15, sy = row 0–15, y=0 at top of source image):
#   top-left  (sx<8,  sy<8):  red    0xFF0000FF
#   top-right (sx≥8,  sy<8):  green  0xFF00FF00
#   bot-left  (sx<8,  sy≥8):  blue   0xFFFF0000
#   bot-right (sx≥8,  sy≥8):  yellow 0xFF00FFFF
# ---------------------------------------------------------------------------

var linSrc: array[16 * 16, uint32]
for sy in 0 ..< 16:
  for sx in 0 ..< 16:
    linSrc[sy * 16 + sx] =
      if   sx < 8 and sy < 8:  0xFF0000FF'u32  # red
      elif sx >= 8 and sy < 8: 0xFF00FF00'u32  # green
      elif sx < 8 and sy >= 8: 0xFFFF0000'u32  # blue
      else:                    0xFF00FFFF'u32  # yellow

# Morton-encode into linearAlloc (DMA-accessible, kept for program lifetime).
# swizzleTileIntoAtlas reads linSrc as Pixie uint32s and writes Morton/ABGR.
let mortonBuf = linearAlloc(csize_t(16 * 16 * 4))
if mortonBuf == nil:
  discard shaderProgramFree(addr prog)
  dvlbFree(dvlb); c3dFini(); gfxExit(); quit(1)
zeroMem(mortonBuf, 16 * 16 * 4)
swizzleTileIntoAtlas(
  cast[ptr uint8](addr linSrc[0]), 16, 16,
  cast[ptr uint8](mortonBuf),
  16, 2,  # atlasW=16, atlasStride=16/8=2
  0, 0)
discard gspgpuFlushDataCache(mortonBuf, csize_t(16 * 16 * 4))

var tex: C3D_Tex
if not c3dTexInitVram(addr tex, 16, 16, GPU_RGBA8):
  linearFree(mortonBuf)
  discard shaderProgramFree(addr prog)
  dvlbFree(dvlb); c3dFini(); gfxExit(); quit(1)
c3dTexUpload(addr tex, mortonBuf)
# mortonBuf kept alive: avoids risk if C3D_TexUpload DMA is async

# ---------------------------------------------------------------------------
# Vertex + index buffers in linearAlloc
#
# Vertex order: 0=BL, 1=BR, 2=TR, 3=TL (boxy convention, same as initQuadBufs)
# Indices [3,0,1, 2,3,1] = (TL,BL,BR) + (TR,TL,BR)
#   Both triangles are CCW in clip space (verified analytically).
# ---------------------------------------------------------------------------

let vtxBuf = linearAlloc(csize_t(4 * sizeof(Vertex)))
let idxBuf = linearAlloc(csize_t(6 * 2))
if vtxBuf == nil or idxBuf == nil:
  if vtxBuf != nil: linearFree(vtxBuf)
  if idxBuf != nil: linearFree(idxBuf)
  c3dTexDelete(addr tex); linearFree(mortonBuf)
  discard shaderProgramFree(addr prog)
  dvlbFree(dvlb); c3dFini(); gfxExit(); quit(1)

let verts = cast[ptr UncheckedArray[Vertex]](vtxBuf)
# 200×200 logical pixel quad, centered on the 400×240 top screen
verts[0] = Vertex(x: 100f, y: 220f, u: 0f, v: 0f, r: 255, g: 255, b: 255, a: 255)  # BL
verts[1] = Vertex(x: 300f, y: 220f, u: 1f, v: 0f, r: 255, g: 255, b: 255, a: 255)  # BR
verts[2] = Vertex(x: 300f, y:  20f, u: 1f, v: 1f, r: 255, g: 255, b: 255, a: 255)  # TR
verts[3] = Vertex(x: 100f, y:  20f, u: 0f, v: 1f, r: 255, g: 255, b: 255, a: 255)  # TL

let idxs = cast[ptr UncheckedArray[uint16]](idxBuf)
idxs[0] = 3; idxs[1] = 0; idxs[2] = 1  # TL, BL, BR
idxs[3] = 2; idxs[4] = 3; idxs[5] = 1  # TR, TL, BR

discard gspgpuFlushDataCache(vtxBuf, csize_t(4 * sizeof(Vertex)))
discard gspgpuFlushDataCache(idxBuf, csize_t(6 * 2))

# Attribute layout: v0=pos(xy float), v1=uv(xy float), v2=color(rgba ubyte)
var attrInfo: C3D_AttrInfo
attrInfoInit(addr attrInfo)
discard attrInfoAddLoader(addr attrInfo, 0, GPU_FLOAT_FORMAT, 2)
discard attrInfoAddLoader(addr attrInfo, 1, GPU_FLOAT_FORMAT, 2)
discard attrInfoAddLoader(addr attrInfo, 2, GPU_UNSIGNED_BYTE, 4)

var bufInfo: C3D_BufInfo
bufInfoInit(addr bufInfo)
discard bufInfoAdd(addr bufInfo, vtxBuf, sizeof(Vertex), 3, 0x210'u64)

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while aptMainLoop():
  if not c3dFrameBegin(C3D_FRAME_SYNCDRAW):
    continue

  discard c3dFrameDrawOn(topTarget)
  c3dRenderTargetClear(topTarget, 1, 0x00000000'u32, 0)  # black background

  c3dDepthTest(false, 0, 0)
  c3dCullFace(GPU_CULL_NONE)
  c3dAlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD,
                GPU_ONE, GPU_ZERO, GPU_ONE, GPU_ZERO)

  # TEV stage 0: pass texture color through unchanged
  let env = c3dGetTexEnv(0)
  c3dTexEnvInit(env)
  c3dTexEnvSrc(env, C3D_BOTH_MODE, GPU_TEXTURE0, GPU_TEXTURE0, GPU_TEXTURE0)
  c3dTexEnvFunc(env, C3D_BOTH_MODE, GPU_REPLACE)
  c3dDirtyTexEnv(env)

  c3dTexBind(0, addr tex)

  c3dBindProgram(addr prog)
  c3dFVUnifMtx4x4(GPU_VERTEX_SHADER_TYPE, projReg.int32,
                   cast[ptr C3D_Mtx](addr projMat[0]))

  c3dSetAttrInfo(addr attrInfo)
  c3dSetBufInfo(addr bufInfo)

  c3dDrawElements(GPU_TRIANGLES, 6, C3D_UNSIGNED_SHORT, idxBuf)

  c3dFrameEnd(0)

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

linearFree(vtxBuf)
linearFree(idxBuf)
c3dTexDelete(addr tex)
linearFree(mortonBuf)
discard shaderProgramFree(addr prog)
dvlbFree(dvlb)
c3dFini()
gfxExit()
