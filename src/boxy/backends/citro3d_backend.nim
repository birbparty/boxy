## citro3d backend for boxy — PICA200 Nintendo 3DS rendering backend.
##
## Provides:
##   - swizzleTileIntoAtlas: Morton/Z-order tile writer for GPU_RGBA8 uploads
##   - mortonIdx, pixieRgbaToGpuAbgr: exported helpers (unit-testable on host)
##   - Citro3dBackend: Backend subtype implementing atlas texture management
##
## The swizzle utility has no citro3d dependency and compiles on any platform.
## The Citro3dBackend type requires --define:ds3.
##
## Morton convention (verified against devkitPro/tex3ds source/swizzle.cpp):
##   x bits occupy even positions, y bits odd positions.
##   Morton(x, y) = mortonTable[x & 7] | (mortonTable[y & 7] << 1)
##
## Byte-order convention (verified against devkitPro/tex3ds source/encode.cpp):
##   GPU_RGBA8 stores bytes as A, B, G, R (ABGR) at increasing addresses.
##   Pixie's ColorRGBX stores R, G, B, A. Conversion = bswap32.

import backend_interface
export backend_interface

# ---------------------------------------------------------------------------
# Morton / Z-order swizzle utility
#
# The PICA200 GPU requires textures in 8×8 Z-order (Morton) block layout.
# Each 8×8 block occupies 64 consecutive uint32 slots in the atlas buffer.
# Blocks are tiled left-to-right, top-to-bottom across the full atlas width.
#
# atlasStride parameter: number of 8×8-block columns = atlasW / 8.
# Callers must pass atlasW / 8 — not atlasW. Confusing this silently garbles
# the atlas in a way that looks like an offset bug, not a geometry bug.
# ---------------------------------------------------------------------------

const mortonTable = [0, 1, 4, 5, 16, 17, 20, 21]
  ## Spread table: mortonTable[i] deposits bit-0 of i at bit-0, bit-1 at bit-2,
  ## bit-2 at bit-4 (leaving odd positions zero for the y-axis interleave).
  ## Values verified against the cycle table in tex3ds source/swizzle.cpp.

func mortonIdx*(x, y: int): int {.inline.} =
  ## Morton index for pixel (x, y) within an 8×8 block.
  ## x, y in [0, 7]; returns a value in [0, 63].
  ## x bits land in even positions, y bits in odd (tex3ds convention).
  mortonTable[x and 7] or (mortonTable[y and 7] shl 1)

func pixieRgbaToGpuAbgr*(rgba: uint32): uint32 {.inline.} =
  ## Convert Pixie ColorRGBX uint32 (bytes R,G,B,A) to PICA200 GPU_RGBA8
  ## uint32 (bytes A,B,G,R). The value-level byte-significance reversal with
  ## same-endian read and write produces an in-memory byte reversal on any host.
  ## Reference: tex3ds source/encode.cpp rgba8888() outputs Alpha first.
  ((rgba and 0xFF000000'u32) shr 24) or
  ((rgba and 0x00FF0000'u32) shr  8) or
  ((rgba and 0x0000FF00'u32) shl  8) or
  ((rgba and 0x000000FF'u32) shl 24)

proc swizzleTileIntoAtlas*(
    src: ptr uint8, srcW, srcH: int,
    dstAtlas: ptr uint8,
    atlasW, atlasStride, dstX, dstY: int) =
  ## Copy a linear Pixie RGBA8 source image into a Morton-tiled GPU_RGBA8 atlas.
  ##
  ## src        : source pixel data (Pixie ColorRGBX, R at byte 0); must be
  ##              tightly packed — row stride == srcW (sub-image views not supported)
  ## srcW/srcH  : source dimensions in pixels
  ## dstAtlas   : destination atlas buffer in PICA200 GPU_RGBA8 Morton layout
  ## atlasW     : atlas width in pixels (power of 2, multiple of 8, ≤ 1024)
  ## atlasStride: block columns per row = atlasW / 8 (caller precomputes for the loop)
  ## dstX/dstY  : destination top-left in atlas pixel coordinates (need not be
  ##              multiples of 8; block and within-block indices computed per pixel)
  ##
  ## Each pixel is Morton-placed and byte-swapped (Pixie RGBA → PICA200 ABGR).
  assert atlasStride == atlasW div 8,
    "atlasStride must equal atlasW div 8; mismatch silently garbles block layout"
  assert dstX >= 0 and dstY >= 0 and srcW > 0 and srcH > 0
  assert dstX + srcW <= atlasW,
    "tile right edge overruns atlas width: " & $(dstX + srcW) & " > " & $atlasW
  assert dstY + srcH <= atlasStride * 8,
    "tile bottom edge overruns atlas height: " & $(dstY + srcH) & " > " & $(atlasStride * 8)
  let src32 = cast[ptr UncheckedArray[uint32]](src)
  let dst32 = cast[ptr UncheckedArray[uint32]](dstAtlas)

  for sy in 0 ..< srcH:
    for sx in 0 ..< srcW:
      let px = dstX + sx       # destination x in atlas
      let py = dstY + sy       # destination y in atlas

      let blockX = px shr 3   # block column (px / 8)
      let blockY = py shr 3   # block row    (py / 8)
      let withinX = px and 7  # x within 8×8 block
      let withinY = py and 7  # y within 8×8 block

      let pixelInBlock = mortonIdx(withinX, withinY)
      let blockIndex   = blockY * atlasStride + blockX
      let dstIdx       = blockIndex * 64 + pixelInBlock

      dst32[dstIdx] = pixieRgbaToGpuAbgr(src32[sy * srcW + sx])

# ---------------------------------------------------------------------------
# Citro3dBackend — Backend implementation for Nintendo 3DS
#
# Only compiled when --define:ds3 is active.
# Atlas texture management (boxy-avl): implemented here.
# Render targets, quad batching, TEV: follow-on tasks (boxy-z5d and beyond).
# ---------------------------------------------------------------------------

when defined(ds3):
  import pixie, vmath             # Image, BlendMode, Color (pixie re-exports chroma), IVec2
  import ../bindings/citro3d
  import ../bindings/libctru_gfx
  export citro3d

  # ---------------------------------------------------------------------------
  # VRAM budget for the PICA200 GPU:
  #
  #   PICA200 VRAM total:                          ≈6 MB (6,291,456 bytes)
  #   GPU_RGBA8 atlas at 512×512:                   1 MB (1,048,576 bytes)
  #   GPU_RGBA8 atlas at 1024×1024:                 4 MB (4,194,304 bytes)
  #   RTT layer pair, top screen (512×256 POT):     0.5 MB × 2 = 1 MB
  #   RTT layer pair, bottom screen (512×256 POT):  0.5 MB × 2 = 1 MB
  #
  # Cap: maxAtlasSize = 1024.
  #   Worst-case: 1024² atlas (4 MB) + two RTT pairs (2 MB) = 6 MB total.
  #   The boxy atlas starts at 512×512 and grows by doubling; a third grow
  #   to 2048² would require 16 MB and is disallowed by this cap.
  # ---------------------------------------------------------------------------

  const maxAtlasSize* = 1024
    ## Maximum atlas side length enforced by createAtlasTexture.
    ## See VRAM budget comment above.

  const maxTexSlots = 16

  const quadLimit* = 10_921
    ## Maximum quads per draw batch. Matches OpenGL QuadLimit in boxy.nim.
    ## Derivation: 4 vertices × 10921 = 43684 < 65536 (uint16 index range).

  # Shared render vertex layout for all citro3d draw calls, matching
  # render2d.v.pica register assignment:
  #   v0 = position (x, y) as GPU_FLOAT × 2
  #   v1 = UV (u, v) as GPU_FLOAT × 2
  #   v2 = color (r, g, b, a) as GPU_UNSIGNED_BYTE × 4
  #
  # PICA200 does NOT auto-normalize GPU_UNSIGNED_BYTE to [0, 1]; the shader
  # multiplies by 1/255 explicitly. Do NOT also normalize on the CPU side —
  # double-normalization yields near-black tints. Total: 20 bytes, no padding.
  type RenderVtx {.packed.} = object
    x, y: float32
    u, v: float32
    r, g, b, a: uint8

  # Keep the original name available for the blit code.
  type BlitVtx* = RenderVtx

  type
    TexSlot = object
      tex: C3D_Tex
      mirror: pointer   ## linearAlloc buffer; size = sideLen*sideLen*4 bytes
      sideLen: int
      used: bool

    Citro3dBackend* = ref object of Backend
      ## Nintendo 3DS citro3d rendering backend.
      ## Atlas management, GPU atlas blit, and quad batch draw pipeline implemented.
      ##
      ## Handle lifetime: handles are not validated against slot reuse. Never retain
      ## a TextureHandle past the matching deleteTexture call — a freed-then-reallocated
      ## slot will have the same id (ABA hazard).
      texSlots: array[maxTexSlots, TexSlot]
      ## Atlas blit shader state (lazy-initialised on first blitAtlasToNewAtlas call).
      dvlb: ptr DVLB_s
      shaderProg: ShaderProgram_s
      projReg: int8          ## uniform register index for "projection" in render2d.shbin
      blitVtxBuf: pointer    ## linearAlloc; 4 × sizeof(RenderVtx) = 80 bytes
      blitIdxBuf: pointer    ## linearAlloc; 6 × uint8 = 6 bytes
      shaderReady: bool
      ## Quad batch pipeline (lazy-initialised on first addQuad call).
      quadVtxBuf: pointer    ## linearAlloc; quadLimit × 4 × sizeof(RenderVtx)
      quadIdxBuf: pointer    ## linearAlloc; quadLimit × 6 × sizeof(uint16)
      quadAttrInfo: C3D_AttrInfo
      quadBufInfo: C3D_BufInfo
      quadCount: int         ## quads accumulated since last flush()
      quadBufsReady: bool

  proc newCitro3dBackend*(): Citro3dBackend =
    Citro3dBackend()

  proc allocTexSlot(b: Citro3dBackend): int =
    for i in 0 ..< maxTexSlots:
      if not b.texSlots[i].used:
        return i
    raise newException(BackendError,
      "no free texture slots (maxTexSlots=" & $maxTexSlots & ")")

  proc slotIndex(b: Citro3dBackend, handle: TextureHandle): int =
    ## Validate `handle` and return its slot index, or -1 for any invalid input.
    ## Guards against: zero id, out-of-range id, freed slot.
    let i = handle.id - 1
    if i < 0 or i >= maxTexSlots or not b.texSlots[i].used:
      return -1
    i

  # ---------------------------------------------------------------------------
  # createAtlasTexture
  # ---------------------------------------------------------------------------

  method createAtlasTexture*(b: Citro3dBackend, size: int): TextureHandle =
    ## Allocate a square GPU_RGBA8 atlas texture of `size` pixels per side in
    ## VRAM. `size` must be a power-of-two value in [512, maxAtlasSize].
    ##
    ## VRAM is required (not C3D_TexInit) because the atlas must serve as both
    ## a sample source and a render target for blitAtlasToNewAtlas (boxy-z5d).
    doAssert (size and (size - 1)) == 0 and size >= 512 and size <= maxAtlasSize,
      "atlas size must be a power-of-two in [512, " & $maxAtlasSize & "], got " & $size
    let i = b.allocTexSlot()
    if not c3dTexInitVram(addr b.texSlots[i].tex, uint16(size), uint16(size), GPU_RGBA8):
      raise newException(BackendError,
        "C3D_TexInitVRAM failed for " & $size & "×" & $size)
    let bytes = csize_t(size * size * 4)
    b.texSlots[i].mirror = linearAlloc(bytes)
    if b.texSlots[i].mirror == nil:
      c3dTexDelete(addr b.texSlots[i].tex)   # roll back the VRAM allocation
      raise newException(BackendError,
        "linearAlloc failed for atlas mirror (" & $bytes & " bytes)")
    zeroMem(b.texSlots[i].mirror, bytes)
    b.texSlots[i].sideLen = size
    b.texSlots[i].used    = true
    TextureHandle(id: i + 1, width: int32(size), height: int32(size))

  # ---------------------------------------------------------------------------
  # deleteTexture
  # ---------------------------------------------------------------------------

  method deleteTexture*(b: Citro3dBackend, handle: TextureHandle) =
    let i = b.slotIndex(handle)
    if i < 0: return
    c3dTexDelete(addr b.texSlots[i].tex)
    linearFree(b.texSlots[i].mirror)
    b.texSlots[i].mirror  = nil
    b.texSlots[i].sideLen = 0
    b.texSlots[i].used    = false

  # ---------------------------------------------------------------------------
  # uploadTile
  # ---------------------------------------------------------------------------

  method uploadTile*(b: Citro3dBackend, handle: TextureHandle,
      x, y: int, image: Image, level: int) =
    ## Swizzle `image` into the atlas CPU mirror at (x, y), then DMA the full
    ## mirror into VRAM via C3D_TexUpload.
    ##
    ## level > 0 is intentionally a no-op: PICA200 atlas textures are single-level.
    ## Boxy's mip-walking loop calls all levels; levels above 0 carry no atlas data
    ## on this backend and are safely discarded.
    ##
    ## DMA note: the mirror is in linearAlloc memory so the GX DMA engine can read
    ## it. GSPGPU_FlushDataCache is called before the upload to flush the ARM11
    ## write-back cache; without this the DMA reads stale physical RAM.
    ##
    ## Whole-mirror DMA on every call: blitAtlasToNewAtlas (boxy-z5d) keeps the
    ## new atlas CPU mirror in sync with the GPU blit result via a block-copy, so
    ## this DMA correctly includes old content plus the newly added tile.
    if level != 0: return
    if image.width == 0 or image.height == 0: return
    let i = b.slotIndex(handle)
    if i < 0:
      raise newException(BackendError, "uploadTile: invalid or freed handle")
    let side = b.texSlots[i].sideLen
    swizzleTileIntoAtlas(
      cast[ptr uint8](unsafeAddr image.data[0]),
      image.width, image.height,
      cast[ptr uint8](b.texSlots[i].mirror),
      side, side div 8, x, y)
    # Flush CPU cache so the GX DMA reads the bytes just written, not stale
    # cache lines. Required: the ARM11 write-back cache is not snooped by GX.
    discard gspgpuFlushDataCache(b.texSlots[i].mirror, csize_t(side * side * 4))
    c3dTexUpload(addr b.texSlots[i].tex, b.texSlots[i].mirror)

  # ---------------------------------------------------------------------------
  # initBlitShader — lazy one-time setup for blitAtlasToNewAtlas
  # ---------------------------------------------------------------------------

  proc initBlitShader(b: Citro3dBackend) =
    ## Load render2d.shbin at compile time, parse it, initialise the shader
    ## program, and allocate the blit quad vertex/index buffers in linearAlloc.
    ## Called once on the first blitAtlasToNewAtlas invocation.
    const shbinBytes = staticRead("../../../build/render2d.shbin")
    b.dvlb = dvlbParseFile(
      cast[ptr uint32](unsafeAddr shbinBytes[0]),
      uint32(shbinBytes.len))
    if b.dvlb == nil:
      raise newException(BackendError,
        "initBlitShader: DVLB_ParseFile failed — is render2d.shbin valid?")
    if shaderProgramInit(addr b.shaderProg) != 0:
      raise newException(BackendError, "initBlitShader: shaderProgramInit failed")
    if shaderProgramSetVsh(addr b.shaderProg, b.dvlb.DVLE) != 0:
      raise newException(BackendError, "initBlitShader: shaderProgramSetVsh failed")
    b.projReg = dvleGetUniformRegister(b.dvlb.DVLE, "projection")
    if b.projReg < 0:
      raise newException(BackendError,
        "initBlitShader: 'projection' uniform not found in render2d.shbin")

    # Blit quad vertex buffer: 4 vertices in clip space, full-UV coverage.
    # shbinBytes is a const (staticRead → read-only binary data); it stays live for the
    # process lifetime so the DVLB_s can safely reference it. If the shbin source is
    # ever moved to a non-const heap buffer, ensure it outlives the DVLB_s.
    b.blitVtxBuf = linearAlloc(csize_t(4 * sizeof(BlitVtx)))
    if b.blitVtxBuf == nil:
      raise newException(BackendError,
        "initBlitShader: linearAlloc failed for blit vertex buffer")
    b.blitIdxBuf = linearAlloc(csize_t(6))
    if b.blitIdxBuf == nil:
      linearFree(b.blitVtxBuf)
      b.blitVtxBuf = nil
      raise newException(BackendError,
        "initBlitShader: linearAlloc failed for blit index buffer")

    # Quad covering the bottom-left quadrant of the new atlas render target:
    #   clip(-1,-1)→(0,0), sampling old atlas UV (0,0)→(1,1).
    #
    # Orientation assumption: PICA200 RTT V=0 = clip Y=-1 (same as OpenGL;
    # V=0 = first block row written by swizzleTileIntoAtlas = image Y=0).
    # If grow() output is vertically mirrored on device, swap the v values below (0↔1).
    #
    # CRITICAL COUPLING: the CPU mirror block-copy (above) places old content in block
    # rows 0..oldStride-1 of the new mirror. The first post-grow uploadTile DMAs the
    # ENTIRE new mirror to VRAM, overwriting the GPU blit. Both paths must agree on
    # where old content lands or content will visibly jump on the first tile upload.
    # On-device acceptance test: content must NOT move when the first tile is added
    # after a grow. A static blit-looks-right test alone is insufficient.
    let vtx = cast[ptr UncheckedArray[BlitVtx]](b.blitVtxBuf)
    vtx[0] = BlitVtx(x: -1f, y: -1f, u: 0f, v: 0f, r: 255, g: 255, b: 255, a: 255)
    vtx[1] = BlitVtx(x:  0f, y: -1f, u: 1f, v: 0f, r: 255, g: 255, b: 255, a: 255)
    vtx[2] = BlitVtx(x: -1f, y:  0f, u: 0f, v: 1f, r: 255, g: 255, b: 255, a: 255)
    vtx[3] = BlitVtx(x:  0f, y:  0f, u: 1f, v: 1f, r: 255, g: 255, b: 255, a: 255)

    # Two CCW triangles: (BL,BR,TL) then (BR,TR,TL).
    let idx = cast[ptr UncheckedArray[uint8]](b.blitIdxBuf)
    idx[0] = 0; idx[1] = 1; idx[2] = 2
    idx[3] = 1; idx[4] = 3; idx[5] = 2

    # Flush ARM11 caches so the GX DMA sees the just-written buffer contents.
    discard gspgpuFlushDataCache(b.blitVtxBuf, csize_t(4 * sizeof(BlitVtx)))
    discard gspgpuFlushDataCache(b.blitIdxBuf, csize_t(6))
    b.shaderReady = true

  # ---------------------------------------------------------------------------
  # blitAtlasToNewAtlas
  # ---------------------------------------------------------------------------

  method blitAtlasToNewAtlas*(b: Citro3dBackend, old, `new`: TextureHandle) =
    ## Copy old atlas content into the new (2×) atlas via two complementary paths:
    ##
    ## 1. CPU mirror block-copy: remaps old atlas CPU mirror into new mirror layout.
    ##    Both mirrors are Morton-encoded but with different block strides, so each
    ##    8×8 block is copied individually to its correct offset in the new mirror.
    ##    This ensures future uploadTile DMA calls include the blitted content.
    ##
    ## 2. GPU blit: draws old atlas VRAM → new atlas VRAM via C3D_DrawElements.
    ##    Required so the new atlas VRAM is valid immediately after grow(), before
    ##    the first uploadTile (which DMAes the mirror and would overwrite a stale
    ##    VRAM if the mirror weren't also copied in step 1).
    ##
    ## Caller is responsible for save/restore of proj, activeShader, and the active
    ## render target per the Backend interface contract.
    let oldI = b.slotIndex(old)
    let newI = b.slotIndex(`new`)
    if oldI < 0 or newI < 0:
      raise newException(BackendError, "blitAtlasToNewAtlas: invalid texture handle")
    let oldSide = b.texSlots[oldI].sideLen
    let newSide = b.texSlots[newI].sideLen

    # -------------------------------------------------------------------------
    # 1. CPU mirror block-copy.
    #
    # Block stride (columns per row) = atlasWidth / 8. Copy each 8×8 block
    # (64 × uint32 = 256 bytes) from old stride to new stride. The pixel
    # coordinate mapping is preserved: block (bx, by) in old atlas → same
    # (bx, by) in new atlas.
    # -------------------------------------------------------------------------
    let oldStride = oldSide div 8
    let newStride = newSide div 8
    let oldMirror = cast[int](b.texSlots[oldI].mirror)
    let newMirror = cast[int](b.texSlots[newI].mirror)
    for by in 0 ..< oldStride:
      for bx in 0 ..< oldStride:
        let oldOff = (by * oldStride + bx) * 64 * 4
        let newOff = (by * newStride + bx) * 64 * 4
        copyMem(cast[pointer](newMirror + newOff),
                cast[pointer](oldMirror + oldOff),
                64 * 4)

    # -------------------------------------------------------------------------
    # 2. GPU blit.
    # -------------------------------------------------------------------------
    if not b.shaderReady:
      b.initBlitShader()

    # Temporary render target backed by the new atlas VRAM texture.
    # depthFmt = -1 (no depth buffer).
    let rt = c3dRenderTargetCreateFromTex(
      addr b.texSlots[newI].tex, GPU_TEXFACE_2D, 0, -1)
    if rt == nil:
      raise newException(BackendError,
        "blitAtlasToNewAtlas: C3D_RenderTargetCreateFromTex failed")

    # Open a self-contained mini-frame for the offscreen blit. This matches the
    # GL path (synchronous glBlitFramebuffer) and ensures:
    #   1. c3dDrawElements actually submits to the GPU.
    #   2. c3dFrameEnd(0) flushes all commands before c3dRenderTargetDelete frees the RT.
    # PRECONDITION: must NOT be called while a frame is already open.
    if not c3dFrameBegin(C3D_FRAME_SYNCDRAW):
      c3dRenderTargetDelete(rt)
      raise newException(BackendError,
        "blitAtlasToNewAtlas: C3D_FrameBegin failed (already inside a frame?)")
    if not c3dFrameDrawOn(rt):
      c3dFrameEnd(0)
      c3dRenderTargetDelete(rt)
      raise newException(BackendError,
        "blitAtlasToNewAtlas: C3D_FrameDrawOn failed")

    # Clear all four quadrants of the new atlas to transparent black, matching the
    # GL path (glClearColor(0,0,0,0) + glClear at boxy.nim:459-460). Ensures the
    # three uncopied quadrants are not undefined VRAM between grow() and the first
    # uploadTile. clearBits=1 = color only; clearColor=0x00000000 = transparent black.
    c3dRenderTargetClear(rt, 1, 0x00000000'u32, 0)

    c3dDepthTest(false, 0, 0)

    # No blending — copy source pixels verbatim.
    c3dAlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD,
                  GPU_ONE, GPU_ZERO, GPU_ONE, GPU_ZERO)

    # TEV stage 0: REPLACE with TEXTURE0 (pass-through for both RGB and alpha).
    let env = c3dGetTexEnv(0)
    c3dTexEnvInit(env)
    c3dTexEnvSrc(env, C3D_BOTH_MODE, GPU_TEXTURE0, GPU_TEXTURE0, GPU_TEXTURE0)
    c3dTexEnvFunc(env, C3D_BOTH_MODE, GPU_REPLACE)
    c3dDirtyTexEnv(env)

    # Bind old atlas VRAM texture as the sample source.
    c3dTexBind(0, addr b.texSlots[oldI].tex)

    # Bind blit shader; upload identity projection (vertices are pre-computed in
    # clip space, so no coordinate transform is needed).
    c3dBindProgram(addr b.shaderProg)
    var identMat = [
      1f, 0f, 0f, 0f,
      0f, 1f, 0f, 0f,
      0f, 0f, 1f, 0f,
      0f, 0f, 0f, 1f]
    c3dFVUnifMtx4x4(GPU_VERTEX_SHADER_TYPE, b.projReg.int32,
                     cast[ptr C3D_Mtx](addr identMat[0]))

    # Attribute layout matching render2d.v.pica (v0=pos, v1=uv, v2=color).
    var attrInfo: C3D_AttrInfo
    attrInfoInit(addr attrInfo)
    discard attrInfoAddLoader(addr attrInfo, 0, GPU_FLOAT_FORMAT, 2)
    discard attrInfoAddLoader(addr attrInfo, 1, GPU_FLOAT_FORMAT, 2)
    discard attrInfoAddLoader(addr attrInfo, 2, GPU_UNSIGNED_BYTE, 4)
    c3dSetAttrInfo(addr attrInfo)

    # Vertex buffer binding. stride = 20 bytes (sizeof BlitVtx).
    # Permutation 0x210: buffer position i → AttrInfo loader i (sequential).
    var bufInfo: C3D_BufInfo
    bufInfoInit(addr bufInfo)
    discard bufInfoAdd(addr bufInfo, b.blitVtxBuf, sizeof(BlitVtx), 3, 0x210'u64)
    c3dSetBufInfo(addr bufInfo)

    # Draw two triangles (6 u8 indices) forming the blit quad.
    c3dDrawElements(GPU_TRIANGLES, 6, C3D_UNSIGNED_BYTE, b.blitIdxBuf)

    # End the mini-frame, flushing all GPU commands, then free the temporary RT.
    # c3dFrameEnd must precede c3dRenderTargetDelete so the GPU drains before the
    # RT's metadata is freed.
    c3dFrameEnd(0)
    c3dRenderTargetDelete(rt)

  # ---------------------------------------------------------------------------
  # Quad batch pipeline — initQuadBufs, addQuad, flush
  # ---------------------------------------------------------------------------

  proc initQuadBufs(b: Citro3dBackend) =
    ## Allocate and initialise the quad vertex + index buffers.
    ## Called once on the first addQuad invocation.
    let vtxBytes = csize_t(quadLimit * 4 * sizeof(RenderVtx))
    let idxBytes = csize_t(quadLimit * 6 * 2)  # 6 uint16 indices per quad

    b.quadVtxBuf = linearAlloc(vtxBytes)
    if b.quadVtxBuf == nil:
      raise newException(BackendError,
        "initQuadBufs: linearAlloc failed for vertex buffer")
    b.quadIdxBuf = linearAlloc(idxBytes)
    if b.quadIdxBuf == nil:
      linearFree(b.quadVtxBuf); b.quadVtxBuf = nil
      raise newException(BackendError,
        "initQuadBufs: linearAlloc failed for index buffer")

    # Pre-build static index buffer. Same winding pattern as the GL path
    # (boxy.nim:310-316): per quad i, indices [i*4+3, i*4+0, i*4+1, i*4+2, i*4+3, i*4+1].
    # Vertex order in addQuad: 0=BL, 1=BR, 2=TR, 3=TL. Two CCW triangles:
    #   (TL,BL,BR) and (TR,TL,BR). Both front-face under PICA200 default CCW winding.
    let idx = cast[ptr UncheckedArray[uint16]](b.quadIdxBuf)
    for i in 0 ..< quadLimit:
      let base = i * 4
      idx[i * 6 + 0] = uint16(base + 3)
      idx[i * 6 + 1] = uint16(base + 0)
      idx[i * 6 + 2] = uint16(base + 1)
      idx[i * 6 + 3] = uint16(base + 2)
      idx[i * 6 + 4] = uint16(base + 3)
      idx[i * 6 + 5] = uint16(base + 1)
    discard gspgpuFlushDataCache(b.quadIdxBuf, idxBytes)

    # Pre-configure AttrInfo: same register layout as render2d.v.pica.
    attrInfoInit(addr b.quadAttrInfo)
    discard attrInfoAddLoader(addr b.quadAttrInfo, 0, GPU_FLOAT_FORMAT, 2)
    discard attrInfoAddLoader(addr b.quadAttrInfo, 1, GPU_FLOAT_FORMAT, 2)
    discard attrInfoAddLoader(addr b.quadAttrInfo, 2, GPU_UNSIGNED_BYTE, 4)

    # Pre-configure BufInfo: single interleaved buffer, stride = 20 bytes.
    bufInfoInit(addr b.quadBufInfo)
    discard bufInfoAdd(addr b.quadBufInfo, b.quadVtxBuf,
                       sizeof(RenderVtx), 3, 0x210'u64)

    b.quadBufsReady = true

  proc addQuad*(b: Citro3dBackend,
      posQuad: array[4, Vec2],
      uvQuad:  array[4, Vec2],
      tints:   array[4, Color]) =
    ## Accumulate one quad into the vertex buffer.
    ##
    ## Vertex order (matching boxy.nim's drawQuad):
    ##   index 0 = bottom-left, 1 = bottom-right, 2 = top-right, 3 = top-left.
    ##
    ## PRECONDITION: the caller must have an open C3D frame (see flush()).
    ##
    ## SINGLE-BATCH-PER-FRAME CONSTRAINT: the vertex buffer is a single
    ## linearAlloc region. C3D_DrawElements in flush() only queues; the GPU
    ## reads the buffer at FrameEnd. Resetting quadCount to 0 and refilling from
    ## the start would overwrite the first batch's data before the GPU consumes it.
    ## Therefore flush() MUST NOT be called more than once per frame with this
    ## backend. Calling addQuad beyond quadLimit raises BackendError (does NOT
    ## silently flush). A ring-buffer scheme is needed to lift this restriction.
    if not b.quadBufsReady:
      b.initQuadBufs()
    if b.quadCount >= quadLimit:
      raise newException(BackendError,
        "addQuad: vertex buffer full (quadLimit=" & $quadLimit &
        "); flush() before adding more quads, but note single-flush-per-frame constraint")
    let vtx = cast[ptr UncheckedArray[RenderVtx]](b.quadVtxBuf)
    let base = b.quadCount * 4
    for i in 0 ..< 4:
      let c = tints[i].asRgbx()
      vtx[base + i] = RenderVtx(
        x: posQuad[i].x, y: posQuad[i].y,
        u: uvQuad[i].x,  v: uvQuad[i].y,
        r: c.r, g: c.g, b: c.b, a: c.a)
    inc b.quadCount

  method flush*(b: Citro3dBackend) =
    ## Submit the current quad batch to the GPU via C3D_DrawElements.
    ##
    ## PRECONDITION: must be called inside an open C3D frame owned by the caller
    ## (between C3D_FrameBegin and C3D_FrameEnd). This is the opposite of
    ## blitAtlasToNewAtlas which opens its own self-contained mini-frame;
    ## batch draws are mid-frame operations — the caller drives the frame.
    ##
    ## SINGLE-FLUSH-PER-FRAME: the vertex buffer is a single linearAlloc region.
    ## C3D_DrawElements only queues into the PICA command FIFO; the GPU reads the
    ## linearAlloc buffer when FrameEnd flushes the FIFO. Calling flush() twice in
    ## one frame would queue two draw commands both pointing to the same buffer, but
    ## the second call resets quadCount=0 and overwrites the buffer — corrupting the
    ## first draw. Flush exactly once per frame, after all addQuad calls are done.
    ##
    ## Caller is responsible for: binding the shader, uploading the projection
    ## uniform, configuring TEV, binding the atlas texture, and setting blend state.
    ## Color values are premultiplied-alpha (from asRgbx); the caller's blend func
    ## should use GPU_ONE / GPU_ONE_MINUS_SRC_ALPHA to match.
    if b.quadCount == 0:
      return
    let vtxBytes = csize_t(b.quadCount * 4 * sizeof(RenderVtx))
    discard gspgpuFlushDataCache(b.quadVtxBuf, vtxBytes)
    c3dSetAttrInfo(addr b.quadAttrInfo)
    c3dSetBufInfo(addr b.quadBufInfo)
    c3dDrawElements(GPU_TRIANGLES, int32(b.quadCount * 6),
                    C3D_UNSIGNED_SHORT, b.quadIdxBuf)
    b.quadCount = 0

  # ---------------------------------------------------------------------------
  # Stubs for follow-on tasks
  # ---------------------------------------------------------------------------

  method createLayerTarget*(b: Citro3dBackend,
      width, height: int32): tuple[tex: TextureHandle, rt: RenderTargetHandle] =
    raise newException(BackendError, "createLayerTarget: not yet implemented (boxy-q2a)")

  method bindTarget*(b: Citro3dBackend, dst: RenderTargetHandle) =
    raise newException(BackendError, "bindTarget: not yet implemented (boxy-q2a)")

  method beginAtlasTarget*(b: Citro3dBackend, atlas: TextureHandle) =
    raise newException(BackendError, "beginAtlasTarget: not yet implemented (boxy-q2a)")

  method endAtlasTarget*(b: Citro3dBackend, atlas: TextureHandle) =
    raise newException(BackendError, "endAtlasTarget: not yet implemented (boxy-q2a)")

  method compositeLayer*(b: Citro3dBackend,
      src: TextureHandle,
      dst: RenderTargetHandle,
      dstTexture: TextureHandle,
      blendMode: BlendMode, tint: Color,
      frameSize: IVec2, atlasSize: int) =
    raise newException(BackendError, "compositeLayer: not yet implemented (boxy-z5d)")

  method restoreState*(b: Citro3dBackend, s: BackendStateSnapshot) =
    raise newException(BackendError, "restoreState: not yet implemented (boxy-z5d)")
