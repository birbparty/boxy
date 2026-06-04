## citro3d backend for boxy — PICA200 Nintendo 3DS rendering backend.
##
## Provides:
##   - swizzleTileIntoAtlas: Morton/Z-order tile writer for GPU_RGBA8 uploads
##   - mortonIdx, pixieRgbaToGpuAbgr: exported helpers (unit-testable on host)
##   - Pica200BlendCategory, blendCategory: blend mode classification (host-testable)
##   - topScreenOrthoProj: OrthoTilt projection matrix (host-testable)
##   - Citro3dBackend: Backend subtype implementing atlas texture management
##
## The swizzle, projection, and blend-category utilities have no citro3d
## dependency and compile on any platform (host-testable), but they do require
## `pixie` to be installed since `BlendMode` is a pixie type.
## Citro3dBackend requires --define:ds3.
##
## Morton convention (verified against devkitPro/tex3ds source/swizzle.cpp):
##   x bits occupy even positions, y bits odd positions.
##   Morton(x, y) = mortonTable[x & 7] | (mortonTable[y & 7] << 1)
##
## Byte-order convention (verified against devkitPro/tex3ds source/encode.cpp):
##   GPU_RGBA8 stores bytes as A, B, G, R (ABGR) at increasing addresses.
##   Pixie's ColorRGBX stores R, G, B, A. Conversion = bswap32.

import pixie   # BlendMode enum (used by host-testable blendCategory / Pica200BlendCategory)
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
# topScreenOrthoProj — OrthoTilt projection for the PICA200 top screen
#
# The 3DS top screen is physically 240×400 (rotated); raw citro3d renders
# into a 240-wide × 400-tall GPU framebuffer and the display hardware
# applies the 90° rotation to the LCD. To render Y-down logical coordinates
# (0,0)→(logicalW×logicalH) without appearing sideways, the projection must
# swap the x and y axis roles — equivalent to a 90° CCW rotation composed
# with the standard orthographic projection.
#
# Derivation: compose ortho(0,W,H,0,-1000,1000) with a 90° CCW rotation:
#   clip_x = -(2/H) · y + 1    (logical Y drives GPU horizontal)
#   clip_y = -(2/W) · x + 1    (logical X drives GPU vertical)
#   clip_z = -z / 1000
#
# PICA200 C3D_Mtx memory layout: each row stores components {w, z, y, x}
# (FVec4_New(x,y,z,w) → {w,z,y,x} in memory). Row i computes clip[i] as
# the dot product of the row with the vertex (vx, vy, vz, vw=1).
#
# This function has no citro3d dependency and compiles on any platform,
# enabling host-side unit testing (see tests/test_citro3d_swizzle.nim).
# ---------------------------------------------------------------------------

type
  Pica200BlendCategory* = enum
    ## How a `BlendMode` maps to PICA200 fixed-function TEV + alpha-blend hardware.
    ##
    ## Use `blendCategory()` to map a `BlendMode`. The citro3d backend uses this to
    ## configure `C3D_AlphaBlend` without the caller knowing about GPU constants.
    ##
    ## Defined outside `when defined(ds3)` so it can be unit-tested on the host.
    bcNormal     ## Standard premultiplied-alpha over: GPU_ONE / GPU_ONE_MINUS_SRC_ALPHA
    bcMultiply   ## Approximated multiply via GPU_DST_COLOR src factor (degraded; see compositeLayer)
    bcScreen     ## Screen: GPU_ONE / GPU_ONE_MINUS_SRC_COLOR
    bcMask       ## Mask: GPU_ZERO / GPU_SRC_COLOR (maskShader lost; degraded on PICA200)
    bcOverwrite  ## Exact overwrite: GPU_ONE / GPU_ZERO (copies src, ignores dst)
    bcUnsupported ## No fixed-function equivalent; falls back to bcNormal with a one-time warning

func blendCategory*(m: BlendMode): Pica200BlendCategory =
  ## Maps a pixie `BlendMode` to its PICA200 fixed-function approximation category.
  ##
  ## NormalBlend and ScreenBlend map exactly. OverwriteBlend maps exactly via
  ## GPU_ONE/GPU_ZERO. MultiplyBlend and MaskBlend are degraded approximations
  ## (no programmable fragment shader on PICA200). All other modes return
  ## bcUnsupported and the caller should warn once and fall back to NormalBlend.
  case m
  of NormalBlend: bcNormal
  of MultiplyBlend: bcMultiply
  of ScreenBlend: bcScreen
  of MaskBlend: bcMask
  of OverwriteBlend: bcOverwrite
  else: bcUnsupported

func topScreenOrthoProj*(logicalW, logicalH: float32): array[16, float32] =
  ## Returns the OrthoTilt projection for the PICA200 top screen as a flat
  ## C3D_Mtx array in {w,z,y,x} row-major order, suitable for passing to
  ## `c3dFVUnifMtx4x4` via `cast[ptr C3D_Mtx](addr result[0])`.
  ##
  ## Maps Y-down logical coordinates (0,0)→(logicalW×logicalH) correctly
  ## onto the 3DS top screen (physically 240×400, rotated):
  ##   clip_x = -(2/logicalH) · y + 1
  ##   clip_y = -(2/logicalW) · x + 1
  ##   clip_z = -z / 1000   (boxy near/far convention: near=-1000, far=1000)
  ##
  ## Depth row convention: row 2 uses clip_z = -z/1000 (zero bias), matching
  ## the compositing matrix in compositeLayer. This is valid for z=0 geometry
  ## and depth-test-disabled rendering (the current 2D use). If depth testing
  ## is enabled or nonzero-z is used, a caller must supply a biased depth row
  ## matching the PICA200 NDC range [0, -1] (near→0, far→-1).
  ##
  ## For the standard 400×240 top screen: `topScreenOrthoProj(400f, 240f)`.
  ## Sanity check: logical centre (W/2, H/2) maps to clip (0, 0).
  assert logicalW > 0f and logicalH > 0f,
    "topScreenOrthoProj: logicalW and logicalH must be positive"
  let scaleY = 2f / logicalH  # coefficient on y → clip_x
  let scaleX = 2f / logicalW  # coefficient on x → clip_y
  # Rows in {w, z, y, x} order:
  result = [
    1f,          0f,       -scaleY,  0f,       # clip_x = -y*(2/H) + 1
    1f,          0f,        0f,      -scaleX,  # clip_y = -x*(2/W) + 1
    0f, -1f/1000f,          0f,       0f,      # clip_z = -z/1000
    1f,          0f,        0f,       0f,      # clip_w = 1
  ]

# ---------------------------------------------------------------------------
# Citro3dBackend — Backend implementation for Nintendo 3DS
#
# Only compiled when --define:ds3 is active.
# Atlas texture management, render targets, quad batching, TEV, and RTT layer
# compositing are all implemented here.
# ---------------------------------------------------------------------------

when defined(ds3):
  import vmath                    # IVec2, Vec2 (pixie imported at top-level for BlendMode/Color)
  import ../bindings/citro3d
  import ../bindings/libctru_gfx
  export citro3d

  # Shader binary loaded at compile time; copied into b.shbinData at first
  # initBlitShader call so DVLB_s can hold a stable heap pointer into it.
  const shbinDataConst = staticRead("../../../build/render2d.shbin")

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
  const maxRtSlots  = 4
    ## Maximum simultaneous render-target slots (layer count cap).
    ## At 512×256×4 = 512 KB per slot, 4 slots = 2 MB for layers.
    ## Combined with the max 1024² atlas (4 MB), total stays within 6 MB VRAM.
    ## (8 slots × 512 KB = 4 MB + 4 MB atlas = 8 MB, which would exceed the 6 MB ceiling.)

  const vramBudgetBytes = 6 * 1024 * 1024
    ## Hard VRAM ceiling (bytes). Atlas + layers must fit within this.

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
      mirror: pointer   ## linearAlloc buffer; nil for VRAM-only RTT layer textures
      sideLen: int
      used: bool
      linkedRt: int     ## rtSlots index for layer textures; -1 if not a layer RT

    RtSlot = object
      rt: ptr C3D_RenderTarget
      bytes: int    ## actual VRAM bytes of backing texture (for accurate budget sums)
      used: bool
      cleared: bool ## false until first bindTarget call clears uninitialized VRAM

    Citro3dBackend* = ref object of Backend
      ## Nintendo 3DS citro3d rendering backend.
      ## Atlas management, GPU atlas blit, quad batch, and layer RTT implemented.
      ##
      ## ARC safety: this ref object holds NO back-reference to the Boxy object.
      ## All state Boxy owns (handles, blend mode, tint, frame size) is passed as
      ## explicit parameters. No reference cycles → ARC (--gc:arc, required for
      ## devkitARM) can collect the Nim ref object without a cycle collector.
      ## Note: ARC frees only the ARC-managed fields (strings, seqs) — the raw C
      ## pointer fields (dvlb, blitVtxBuf, blitIdxBuf, quadVtxBuf, quadIdxBuf,
      ## shaderProg, slot textures/RTs) require a deterministic teardown hook.
      ## See freeShaderState and the follow-up bead for the backend destructor.
      ## Do NOT add a Boxy field here.
      ##
      ## Handle lifetime: handles are not validated against slot reuse. Never retain
      ## a TextureHandle or RenderTargetHandle past the matching delete call — a
      ## freed-then-reallocated slot will have the same id (ABA hazard).
      texSlots: array[maxTexSlots, TexSlot]
      rtSlots: array[maxRtSlots, RtSlot]
      atlasSideLen: int  ## current atlas texture side length; 0 = no atlas yet
      ## Atlas blit / compositing shader state (lazy-initialised on first use).
      shbinData: string      ## shader binary; must outlive dvlb (DVLB_s references it)
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
      ## Per-mode unsupported-blend warning state: a bit is set on first warn so
      ## the warning fires once per session rather than every compositeLayer call.
      warnedBlendModes: set[BlendMode]
      ## Screen render target set by the app before using pushLayer/popLayer.
      ## nil until setScreenTarget is called. compositeLayer raises if this is
      ## nil when compositing to the screen (final popLayer).
      screenRt: ptr C3D_RenderTarget

  proc newCitro3dBackend*(): Citro3dBackend =
    result = Citro3dBackend()
    for i in 0 ..< maxTexSlots:
      result.texSlots[i].linkedRt = -1
    # RtSlot zero-init: used=false, cleared=false, rt=nil, bytes=0 is correct.
    # No explicit rtSlots loop needed — Nim ref object fields default to zero.

  proc setScreenTarget*(b: Citro3dBackend, rt: ptr C3D_RenderTarget) =
    ## Register the physical screen render target so compositeLayer can composite
    ## the final layer onto the screen (final popLayer with layerNum → -1).
    ## Must be called before any pushLayer/popLayer that composites to screen.
    ## Call this once after c3dRenderTargetCreate and before bx.beginFrame.
    b.screenRt = rt

  proc allocTexSlot(b: Citro3dBackend): int =
    for i in 0 ..< maxTexSlots:
      if not b.texSlots[i].used:
        return i
    raise newException(BackendError,
      "no free texture slots (maxTexSlots=" & $maxTexSlots & ")")

  proc allocRtSlot(b: Citro3dBackend): int =
    for i in 0 ..< maxRtSlots:
      if not b.rtSlots[i].used:
        return i
    raise newException(BackendError,
      "no free render-target slots (maxRtSlots=" & $maxRtSlots & ")")

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
    ## a sample source and a render target for blitAtlasToNewAtlas.
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
    b.texSlots[i].sideLen  = size
    b.texSlots[i].used     = true
    b.texSlots[i].linkedRt = -1
    b.atlasSideLen = size
    TextureHandle(id: i + 1, width: int32(size), height: int32(size))

  # ---------------------------------------------------------------------------
  # deleteTexture
  # ---------------------------------------------------------------------------

  method deleteTexture*(b: Citro3dBackend, handle: TextureHandle) =
    let i = b.slotIndex(handle)
    if i < 0: return
    # Free the linked render target before deleting the backing texture.
    # The render target must be freed while the texture is still alive.
    let ri = b.texSlots[i].linkedRt
    if ri >= 0 and b.rtSlots[ri].used:
      c3dRenderTargetDelete(b.rtSlots[ri].rt)
      b.rtSlots[ri].rt      = nil
      b.rtSlots[ri].bytes   = 0
      b.rtSlots[ri].used    = false
      b.rtSlots[ri].cleared = false
    c3dTexDelete(addr b.texSlots[i].tex)
    if b.texSlots[i].mirror != nil:
      linearFree(b.texSlots[i].mirror)
    b.texSlots[i].mirror   = nil
    b.texSlots[i].sideLen  = 0
    b.texSlots[i].linkedRt = -1
    b.texSlots[i].used     = false

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
    ## ARC lifetime audit: `image` (a pixie Image ref) is ARC-managed, but its
    ## `data` seq is only accessed during the synchronous CPU copy in
    ## swizzleTileIntoAtlas. The DMA (`c3dTexUpload`) reads from the linearAlloc
    ## mirror, NOT from `image.data` — so ARC can collect `image` after this
    ## method returns without affecting the DMA source. Safe by two-stage design:
    ##   1. CPU copy: image.data → linearAlloc mirror (synchronous, no GPU)
    ##   2. Upload: linearAlloc mirror → VRAM via c3dTexUpload, which calls
    ##      C3D_TexLoadImage synchronously — the transfer completes before returning
    ## No ARC hazard exists: upload source is linearAlloc (backend-owned, not collected).
    ##
    ## GSPGPU_FlushDataCache is called before the upload to flush the ARM11
    ## write-back cache; without this the transfer reads stale physical RAM.
    ##
    ## Whole-mirror DMA on every call: blitAtlasToNewAtlas keeps the new atlas
    ## CPU mirror in sync via block-copy, so this DMA includes old content plus
    ## the newly added tile.
    if level != 0: return
    if image.width == 0 or image.height == 0: return
    let i = b.slotIndex(handle)
    if i < 0:
      raise newException(BackendError, "uploadTile: invalid or freed handle")
    let side = b.texSlots[i].sideLen
    # Stage 1: synchronous CPU copy of image pixels into the linearAlloc mirror.
    # `image.data[0]` is only dereferenced here; the caller's live binding keeps
    # `image` alive for the entire synchronous call — ARC borrows the parameter
    # (no incref). The guard above (width/height == 0 → return) also ensures
    # image.data is non-empty before this addr is taken.
    swizzleTileIntoAtlas(
      cast[ptr uint8](unsafeAddr image.data[0]),
      image.width, image.height,
      cast[ptr uint8](b.texSlots[i].mirror),
      side, side div 8, x, y)
    # Stage 2: flush and DMA from linearAlloc mirror to VRAM (synchronous).
    discard gspgpuFlushDataCache(b.texSlots[i].mirror, csize_t(side * side * 4))
    c3dTexUpload(addr b.texSlots[i].tex, b.texSlots[i].mirror)
    # Flush the DESTINATION texture cache so the GPU samples the freshly-written
    # texels instead of stale/zero memory (without this, textured draws sample
    # black). Required for the memcpy path; harmless on the DMA path.
    c3dTexFlush(addr b.texSlots[i].tex)

  # ---------------------------------------------------------------------------
  # ---------------------------------------------------------------------------
  # freeShaderState — release blit shader resources (nil-guarded, idempotent)
  # ---------------------------------------------------------------------------

  proc freeShaderState(b: Citro3dBackend) =
    ## Free all resources allocated at or after shaderProgramSetVsh in initBlitShader.
    ## Nil-guarded: safe to call from any error path where dvlbParseFile succeeded,
    ## and from the backend destructor (once added).
    ##
    ## libctru teardown order: linearFree → shaderProgramFree → dvlbFree.
    ##   (The shader program holds DVLE pointers inside the DVLB; freeing
    ##    the DVLB first would leave shaderProgramFree touching freed memory.)
    ##
    ## Note: NOT used for the shaderProgramInit-fail path because shaderProgramInit
    ## failed before allocating any program state — that path only frees the DVLB.
    ## Gating shaderProgramFree on `dvlb != nil` preserves this distinction when
    ## calling from the destructor.
    if b.blitIdxBuf != nil: linearFree(b.blitIdxBuf); b.blitIdxBuf = nil
    if b.blitVtxBuf != nil: linearFree(b.blitVtxBuf); b.blitVtxBuf = nil
    if b.dvlb != nil:
      discard shaderProgramFree(addr b.shaderProg)
      dvlbFree(b.dvlb); b.dvlb = nil
    b.projReg = -1      # no field should outlive the resources it describes
    b.shaderReady = false  # guard: blitAtlasToNewAtlas checks this before re-using freed bufs

  # ---------------------------------------------------------------------------
  # initBlitShader — lazy one-time setup for blitAtlasToNewAtlas
  # ---------------------------------------------------------------------------

  proc initBlitShader(b: Citro3dBackend) =
    ## Load render2d.shbin at compile time, parse it, initialise the shader
    ## program, and allocate the blit quad vertex/index buffers in linearAlloc.
    ## Called once on the first blitAtlasToNewAtlas invocation.
    # Copy the module-level const so DVLB_s has a stable heap pointer.
    # INVARIANT: b.shbinData must not be mutated or resized after dvlbParseFile —
    # the returned DVLB_s holds an internal pointer into b.shbinData's buffer.
    # ARC note: b.shbinData (string, ARC-managed) outlives b.dvlb (ptr DVLB_s, raw C
    # pointer) only as long as the backend ref is alive. ARC frees the string buffer;
    # the DVLB_s is a raw pointer NOT freed by ARC — it requires an explicit dvlbFree
    # via freeShaderState (called from error paths and the future backend destructor).
    b.shbinData = shbinDataConst
    b.dvlb = dvlbParseFile(
      cast[ptr uint32](unsafeAddr b.shbinData[0]),
      uint32(b.shbinData.len))
    if b.dvlb == nil:
      raise newException(BackendError,
        "initBlitShader: DVLB_ParseFile failed — is render2d.shbin valid?")
    # From here: any raise must free b.dvlb first (b.shaderReady is still false,
    # so a retry would dvlbParseFile again, orphaning the current allocation).
    if shaderProgramInit(addr b.shaderProg) != 0:
      # shaderProgramInit failed before allocating program state: only free the DVLB.
      # (shaderProgramFree must NOT be called here — there is nothing to free.)
      dvlbFree(b.dvlb); b.dvlb = nil
      raise newException(BackendError, "initBlitShader: shaderProgramInit failed")
    # From here: shaderProgramSetVsh may have linked program state into the DVLB.
    # All subsequent error paths use freeShaderState (shaderProgramFree → dvlbFree).
    if shaderProgramSetVsh(addr b.shaderProg, b.dvlb.DVLE) != 0:
      b.freeShaderState()
      raise newException(BackendError, "initBlitShader: shaderProgramSetVsh failed")
    b.projReg = dvleGetUniformRegister(b.dvlb.DVLE, "projection")
    if b.projReg < 0:
      b.freeShaderState()
      raise newException(BackendError,
        "initBlitShader: 'projection' uniform not found in render2d.shbin")

    # Blit quad vertex buffer: 4 vertices in clip space, full-UV coverage.
    b.blitVtxBuf = linearAlloc(csize_t(4 * sizeof(BlitVtx)))
    if b.blitVtxBuf == nil:
      b.freeShaderState()
      raise newException(BackendError,
        "initBlitShader: linearAlloc failed for blit vertex buffer")
    b.blitIdxBuf = linearAlloc(csize_t(6))
    if b.blitIdxBuf == nil:
      b.freeShaderState()
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

    c3dDepthTest(false, 0, GPU_WRITE_ALL)

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
    # PICA200 LAYOUT: C3D_FVec stores {w,z,y,x} in memory, so each flat row is
    # [w,z,y,x]. Identity rows (x,y,z,w)=(1,0,0,0),(0,1,0,0)... → anti-diagonal.
    c3dBindProgram(addr b.shaderProg)
    var identMat = [
      0f, 0f, 0f, 1f,
      0f, 0f, 1f, 0f,
      0f, 1f, 0f, 0f,
      1f, 0f, 0f, 0f]
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

  proc prepareAtlasDraw*(b: Citro3dBackend, atlasHandle: TextureHandle,
                         frameSize: IVec2, forScreen: bool = true) =
    ## Set up PICA200 GPU state for the atlas draw path (drawImage / drawRect).
    ##
    ## PRECONDITIONS:
    ##   1. quadCount > 0 — call only when there are quads to draw (boxy.nim flush
    ##      enforces this; direct callers must check before invoking).
    ##   2. Must be called inside an open C3D frame (after c3dFrameBegin and
    ##      c3dFrameDrawOn) and before flush().
    ##   3. When forScreen=true, the RT must be the physical 3DS top screen.
    ##      When forScreen=false (RTT layer target), a non-tilted ortho is used.
    ##
    ## `forScreen`:
    ##   true  (default) — physical top screen target: uses topScreenOrthoProj
    ##   false — RTT layer target (pushed via pushLayer): uses a non-tilted ortho
    ##           matching compositeLayer's projection so quads render upright in
    ##           the layer texture without the 90° screen tilt applied.
    ##
    ## Pipeline state set:
    ##   - shader:     render2d.shbin (lazy-initialised on first call)
    ##   - projection: topScreenOrthoProj(frameSize) when forScreen=true;
    ##                 non-tilted ortho(0,W,H,0) when forScreen=false
    ##   - depth:      off (2D rendering only)
    ##   - blend:      premultiplied-alpha NormalBlend
    ##   - TEV:        MODULATE = texture0 × primary_color (for per-vertex tinting)
    ##                 Single stage; compositeLayer uses the same config for its
    ##                 NormalBlend arm.
    ##   - cull:       GPU_CULL_NONE — both projections flip triangle winding
    ##                 (negative determinant); disabling cull is correct for 2D.
    ##   - atlas tex:  atlasHandle bound to unit 0
    ##
    ## Single-flush-per-frame coupling: this proc is invoked once per frame,
    ## immediately before the single draw submit, because the backend forbids
    ## more than one flush() per frame (linearAlloc vertex buffer, queuable
    ## C3D_DrawElements). If a ring-buffer change ever lifts that constraint, the
    ## per-flush state-setup story must be revisited.
    ##
    ## Caller pattern (in boxy.nim ds3 flush):
    ##   b.prepareAtlasDraw(boxy.atlasHandle, boxy.frameSize, forScreen)
    ##   b.flush()
    if not b.shaderReady:
      b.initBlitShader()

    # Bind render2d shader (same binary used by blitAtlasToNewAtlas).
    c3dBindProgram(addr b.shaderProg)

    # Upload projection: tilted (top-screen) or non-tilted (RTT layer).
    # topScreenOrthoProj composes ortho(0,W,H,0) with a 90° CCW rotation so
    # the logical frame (0,0)→(W,H) maps to the rotated physical display.
    # The RTT path uses a standard non-tilted ortho (same as compositeLayer)
    # because RTT textures are not rotated by the display hardware.
    let W = frameSize.x.float32
    let H = frameSize.y.float32
    if forScreen:
      var proj = topScreenOrthoProj(W, H)
      c3dFVUnifMtx4x4(GPU_VERTEX_SHADER_TYPE, b.projReg.int32,
                       cast[ptr C3D_Mtx](addr proj[0]))
    else:
      var proj = [
        -1f,        0f,     0f, 2f/W,
         1f,        0f, -2f/H,   0f,
         0f, -1f/1000f,    0f,   0f,
         1f,        0f,    0f,   0f]
      c3dFVUnifMtx4x4(GPU_VERTEX_SHADER_TYPE, b.projReg.int32,
                       cast[ptr C3D_Mtx](addr proj[0]))

    # Depth test off — boxy's draw path is purely 2D.
    c3dDepthTest(false, 0, GPU_WRITE_ALL)

    # Cull off. Both topScreenOrthoProj (axis-swap) and the non-tilted ortho
    # (Y-flip) have negative determinants, flipping triangle winding so that
    # quads become CW in clip space. GPU_CULL_BACK_CCW would cull them all.
    # Disabling cull is correct for 2D and removes the winding dependency.
    c3dCullFace(GPU_CULL_NONE)

    # Premultiplied-alpha NormalBlend (GPU_ONE × src + GPU_ONE_MINUS_SRC_ALPHA × dst).
    c3dAlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD,
                  GPU_ONE, GPU_ONE_MINUS_SRC_ALPHA,
                  GPU_ONE, GPU_ONE_MINUS_SRC_ALPHA)

    # TEV stage 0: MODULATE = texture0 × primary_color (vertex tint).
    # Matches compositeLayer's TEV for the NormalBlend path.
    let env = c3dGetTexEnv(0)
    c3dTexEnvInit(env)
    c3dTexEnvSrc(env, C3D_BOTH_MODE, GPU_TEXTURE0, GPU_PRIMARY_COLOR, GPU_TEXTURE0)
    c3dTexEnvFunc(env, C3D_BOTH_MODE, GPU_MODULATE)
    c3dDirtyTexEnv(env)

    # Bind the atlas texture to unit 0.
    let si = b.slotIndex(atlasHandle)
    if si >= 0:
      c3dTexBind(0, addr b.texSlots[si].tex)
    else:
      raise newException(BackendError,
        "prepareAtlasDraw: invalid atlasHandle (id=" & $atlasHandle.id &
        ") — handle not allocated or already freed; check that newBoxy succeeded " &
        "and destroy() has not been called")

  # ---------------------------------------------------------------------------
  # nextPOT — smallest power-of-two ≥ n
  # ---------------------------------------------------------------------------

  func nextPOT(n: int): int {.inline.} =
    result = 1
    while result < n: result = result shl 1

  # ---------------------------------------------------------------------------
  # createLayerTarget — allocate a VRAM RTT texture + render target for a layer
  # ---------------------------------------------------------------------------

  method createLayerTarget*(b: Citro3dBackend,
      width, height: int32): tuple[tex: TextureHandle, rt: RenderTargetHandle] =
    ## Allocate a GPU_RGBA8 VRAM texture + render target for a pushLayer/popLayer pair.
    ##
    ## Input dimensions (width, height) are the *logical* frame size (e.g. 400×240).
    ## Citro3d requires POT textures; dimensions are padded to the next power-of-two
    ## (512×256 for a 400×240 top-screen frame).
    ##
    ## VRAM budget: atlas + all layers must fit within vramBudgetBytes (≈6 MB).
    ## Each layer costs texW × texH × 4 bytes. Raises BackendError if exceeded.
    ##
    ## Returned TextureHandle carries the padded (POT) dimensions in width/height.
    ## compositeLayer reads these to compute UV bounds for the visible sub-region.
    if width <= 0 or height <= 0:
      raise newException(BackendError, "createLayerTarget: non-positive dimensions")
    let texW = max(8, nextPOT(width.int))   # PICA200 minimum texture dim is 8
    let texH = max(8, nextPOT(height.int))
    let layerBytes = texW * texH * 4

    # VRAM budget check: sum actual bytes of existing slots (not all at new layer size).
    # Budget is color-only (depthFmt=-1 means no depth allocation). Does not account
    # for VRAM allocator alignment overhead; treat as a conservative lower bound.
    let atlasBytes = if b.atlasSideLen > 0: b.atlasSideLen * b.atlasSideLen * 4 else: 0
    var usedRtBytes = 0
    for i in 0 ..< maxRtSlots:
      if b.rtSlots[i].used:
        usedRtBytes += b.rtSlots[i].bytes
    if atlasBytes + usedRtBytes + layerBytes > vramBudgetBytes:
      raise newException(BackendError,
        "createLayerTarget: VRAM budget exceeded — atlas (" & $atlasBytes &
        " B) + existing layers (" & $usedRtBytes &
        " B) + new layer (" & $layerBytes & " B) > " & $vramBudgetBytes & " B")

    # Allocate both slots before touching the GPU so neither can leak if the other fails.
    # allocTexSlot / allocRtSlot are side-effect-free scans; they hold no GPU resources.
    let ti = b.allocTexSlot()
    let ri = b.allocRtSlot()

    if not c3dTexInitVram(addr b.texSlots[ti].tex,
                          uint16(texW), uint16(texH), GPU_RGBA8):
      raise newException(BackendError,
        "createLayerTarget: C3D_TexInitVRAM failed for " & $texW & "×" & $texH)

    let rt = c3dRenderTargetCreateFromTex(
      addr b.texSlots[ti].tex, GPU_TEXFACE_2D, 0, -1)
    if rt == nil:
      c3dTexDelete(addr b.texSlots[ti].tex)
      raise newException(BackendError,
        "createLayerTarget: C3D_RenderTargetCreateFromTex failed")

    # sideLen stores texW (the width) for bookkeeping; layer textures are rectangular
    # (e.g. 512×256), not square like atlas textures. uploadTile / blitAtlasToNewAtlas
    # must never be called on a layer slot (they use sideLen as a square side).
    b.texSlots[ti].mirror   = nil
    b.texSlots[ti].sideLen  = texW
    b.texSlots[ti].used     = true
    b.texSlots[ti].linkedRt = ri
    b.rtSlots[ri].rt      = rt
    b.rtSlots[ri].bytes   = layerBytes
    b.rtSlots[ri].used    = true
    b.rtSlots[ri].cleared = false  # uninitialized VRAM; cleared on first bindTarget call

    let tex = TextureHandle(id: ti + 1,
                            width:  int32(texW),
                            height: int32(texH),
                            hasMipmap: false,
                            magFilter: filterLinear,
                            minFilter: filterLinear)
    let rtHandle = RenderTargetHandle(id: ri + 1)
    result = (tex, rtHandle)

  # ---------------------------------------------------------------------------
  # bindTarget — switch the current render target
  # ---------------------------------------------------------------------------

  method bindTarget*(b: Citro3dBackend, dst: RenderTargetHandle) =
    ## Switch the active render target to `dst` and clear it to transparent black.
    ## Must be called inside an open C3D frame (between C3D_FrameBegin and C3D_FrameEnd).
    ## Raises for the screen (id == 0) — the screen is an app-owned RT registered via
    ## setScreenTarget; compositeLayer switches to it, not bindTarget.
    ##
    ## Per-frame clear: c3dRenderTargetClear is called unconditionally on every bindTarget
    ## call, matching GL pushLayer's unconditional clearColor() on every push. This ensures
    ## reused layer RTTs (boxy reuses the layerRTs seq across frames) start fully transparent
    ## each frame, preventing stale previous-frame content from ghosting through transparent
    ## regions. c3dRenderTargetClear is a GPU clear command, not a quad-batch flush — it
    ## does not conflict with the single-flush-per-frame constraint.
    if dst.isScreen():
      raise newException(BackendError,
        "bindTarget: screen is app-owned — use setScreenTarget + compositeLayer, not bindTarget")
    let ri = dst.id - 1
    if ri < 0 or ri >= maxRtSlots or not b.rtSlots[ri].used:
      raise newException(BackendError,
        "bindTarget: invalid or freed RenderTargetHandle (id=" & $dst.id & ")")
    if not c3dFrameDrawOn(b.rtSlots[ri].rt):
      raise newException(BackendError,
        "bindTarget: C3D_FrameDrawOn failed — is a frame open?")
    c3dRenderTargetClear(b.rtSlots[ri].rt, 1, 0x00000000'u32, 0)
    b.rtSlots[ri].cleared = true

  # ---------------------------------------------------------------------------
  # beginAtlasTarget / endAtlasTarget — atlas-as-RTT sync points
  # ---------------------------------------------------------------------------

  method beginAtlasTarget*(b: Citro3dBackend, atlas: TextureHandle) =
    ## Prepare to use `atlas` as a render target (called by boxy's grow() before
    ## blitAtlasToNewAtlas). No-op on citro3d: blitAtlasToNewAtlas opens its own
    ## C3D_FRAME_SYNCDRAW mini-frame and manages the full GPU lifecycle itself.
    ## See blitAtlasToNewAtlas for the flush/sync that makes this safe.
    discard

  method endAtlasTarget*(b: Citro3dBackend, atlas: TextureHandle) =
    ## End rendering into `atlas` as a render target (called after blitAtlasToNewAtlas).
    ## No-op on citro3d: blitAtlasToNewAtlas already called c3dFrameEnd before returning,
    ## so the GPU has drained and VRAM is coherent before this is called.
    discard

  # ---------------------------------------------------------------------------
  # compositeLayer — composite a layer texture onto the next layer or screen
  # ---------------------------------------------------------------------------

  method compositeLayer*(b: Citro3dBackend,
      src: TextureHandle,
      dst: RenderTargetHandle,
      dstTexture: TextureHandle,
      blendMode: BlendMode, tint: Color,
      frameSize: IVec2, atlasSize: int) =
    ## Composite `src` (a popped layer texture) onto `dst` (next layer or screen).
    ## Must be called inside an open C3D frame.
    ##
    ## `src` dimensions are POT-padded (e.g. 512×256 for a 400×240 frame).
    ## UV bounds are computed from frameSize / src.width × src.height so only
    ## the visible sub-region of the layer texture is sampled.
    ##
    ## Blend mode handling uses `blendCategory()`:
    ##   NormalBlend  → GPU_ONE / GPU_ONE_MINUS_SRC_ALPHA (premultiplied-alpha over)
    ##   MultiplyBlend → GPU_DST_COLOR / GPU_ONE_MINUS_SRC_ALPHA (degraded: no dst readback)
    ##   ScreenBlend  → GPU_ONE / GPU_ONE_MINUS_SRC_COLOR
    ##   MaskBlend    → GPU_ZERO / GPU_SRC_COLOR (degraded: maskShader lost on PICA200)
    ##   All others   → warn once to stderr, fall back to NormalBlend
    ##
    ## MultiplyBlend and MaskBlend are hardware approximations that differ from the
    ## desktop GL backend for non-trivial content. See `blendCategory()` for details.
    ##
    ## Screen target (dst.isScreen()): supported when setScreenTarget has been called.
    ## Compositing to screen uses topScreenOrthoProj (tilted) so the final layer
    ## appears correctly on the rotated physical top-screen LCD.
    ## RTT target: uses a non-tilted ortho (standard Y-down → clip).
    let isScreen = dst.isScreen()
    if isScreen and b.screenRt == nil:
      raise newException(BackendError,
        "compositeLayer: screen render target not set — call setScreenTarget before pushLayer/popLayer")

    if frameSize.x <= 0 or frameSize.y <= 0:
      raise newException(BackendError, "compositeLayer: non-positive frameSize")

    let si = b.slotIndex(src)
    if si < 0:
      raise newException(BackendError, "compositeLayer: invalid src TextureHandle")
    if src.width <= 0 or src.height <= 0:
      raise newException(BackendError, "compositeLayer: src has non-positive dimensions")

    if not isScreen:
      let ri = dst.id - 1
      if ri < 0 or ri >= maxRtSlots or not b.rtSlots[ri].used:
        raise newException(BackendError,
          "compositeLayer: invalid dst RenderTargetHandle (id=" & $dst.id & ")")

    # Reject src aliasing dst (read-after-write hazard on PICA200).
    # backend_interface.nim:181 documents dstTexture as the hook for this check.
    if dstTexture.id != 0 and dstTexture.id == src.id:
      raise newException(BackendError,
        "compositeLayer: src and dst alias the same surface (read-after-write hazard)")

    # Warn once per session for blend modes with no fixed-function equivalent.
    # Placed after all validation so the warning is only emitted when a draw
    # will actually happen (not on calls that are about to raise on bad inputs).
    # Note: on retail 3DS without consoleInit/3dslink, stderr may not be visible;
    # the authoritative record of degraded-mode semantics is the docstring above.
    let bcat = blendCategory(blendMode)
    if bcat == bcUnsupported and blendMode notin b.warnedBlendModes:
      b.warnedBlendModes.incl(blendMode)
      stderr.writeLine(
        "citro3d compositeLayer: blend mode " & $blendMode &
        " has no PICA200 fixed-function equivalent — falling back to NormalBlend")

    if not b.shaderReady:
      b.initBlitShader()

    # Switch render target to dst.
    # Screen: use the app-registered screenRt (topScreenOrthoProj, tilted).
    # RTT:    use the slot render target (non-tilted ortho).
    if isScreen:
      if not c3dFrameDrawOn(b.screenRt):
        raise newException(BackendError,
          "compositeLayer: C3D_FrameDrawOn failed for screen target — is a frame open?")
    else:
      let ri = dst.id - 1
      if not c3dFrameDrawOn(b.rtSlots[ri].rt):
        raise newException(BackendError,
          "compositeLayer: C3D_FrameDrawOn failed — is a frame open?")

    # Ortho projection for the compositing quad.
    # Screen target: topScreenOrthoProj (90° CCW tilt for physical top-screen LCD).
    # RTT target: non-tilted ortho — maps (0,0)→(W,H) to clip (-1,-1)→(+1,+1).
    # Layout: C3D_FVec rows store {w, z, y, x}. Each row maps one clip component:
    #   Row 0 (clip_x): {tx=-1, 0, 0, sx=2/W}
    #   Row 1 (clip_y): {ty=1, 0, sy=-2/H, 0}   (Y flipped: boxy Y=0 → clip +1)
    #   Row 2 (clip_z): {0, sz=-0.001, 0, 0}
    #   Row 3 (clip_w): {1, 0, 0, 0}
    let W = frameSize.x.float32
    let H = frameSize.y.float32
    if isScreen:
      var projMat = topScreenOrthoProj(W, H)
      c3dFVUnifMtx4x4(GPU_VERTEX_SHADER_TYPE, b.projReg.int32,
                       cast[ptr C3D_Mtx](addr projMat[0]))
    else:
      var projMat = [
        -1f,        0f,     0f, 2f/W,
         1f,        0f, -2f/H,   0f,
         0f, -1f/1000f,    0f,   0f,
         1f,        0f,    0f,   0f]
      c3dFVUnifMtx4x4(GPU_VERTEX_SHADER_TYPE, b.projReg.int32,
                       cast[ptr C3D_Mtx](addr projMat[0]))

    c3dDepthTest(false, 0, GPU_WRITE_ALL)

    # Cull off. topScreenOrthoProj (screen) has negative determinant (axis-swap);
    # the RTT ortho (non-tilted) has negative determinant (Y-flip). Both flip
    # winding so quads become CW in clip space. GPU_CULL_BACK_CCW would cull them.
    c3dCullFace(GPU_CULL_NONE)

    # Alpha blend by mode. All paths use premultiplied-alpha colors (from asRgbx).
    case bcat
    of bcMask:
      # DEGRADED APPROXIMATION: the GL path also binds maskShader (a fragment shader
      # that broadcasts source alpha across RGB for luminance masking). PICA200 has no
      # programmable shaders so maskShader is unavailable. The blend factors below
      # (GPU_ZERO × src + GPU_SRC_COLOR × dst) replicate the blend equation but not
      # the per-pixel RGB rebroadcast, so colored mask content will differ from desktop.
      {.warning: "MaskBlend on PICA200 is a degraded approximation (maskShader unavailable); colored masks will differ from the desktop GL backend".}
      c3dAlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD,
                    GPU_ZERO, GPU_SRC_COLOR, GPU_ZERO, GPU_SRC_COLOR)
    of bcScreen:
      c3dAlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD,
                    GPU_ONE, GPU_ONE_MINUS_SRC_COLOR,
                    GPU_ONE, GPU_ONE_MINUS_SRC_COLOR)
    of bcMultiply:
      # DEGRADED APPROXIMATION: true per-pixel multiply would need dst available in the
      # TEV/fragment stage, which PICA200 fixed-function lacks. We instead exploit the
      # blend unit's dst access: GPU_DST_COLOR as the src factor yields src·dst at the
      # blend stage. For opaque premultiplied src (src_a=1) this is exact: out=src·dst.
      # For translucent or colored-tint content the blend unit only sees post-TEV src
      # (already modulated by vertex-color tint), so output diverges from the desktop GL
      # blendShader path; the result is src·dst + dst·(1−src_a) rather than a true per-
      # pixel multiply.
      c3dAlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD,
                    GPU_DST_COLOR, GPU_ONE_MINUS_SRC_ALPHA,
                    GPU_ONE, GPU_ONE_MINUS_SRC_ALPHA)
    of bcOverwrite:
      # Exact: copies source pixels, discarding destination entirely.
      # GPU_ONE × src + GPU_ZERO × dst = src. Matches OverwriteBlend semantics perfectly.
      c3dAlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD,
                    GPU_ONE, GPU_ZERO,
                    GPU_ONE, GPU_ZERO)
    else: # bcNormal or bcUnsupported (bcUnsupported warned above; both arms provably exhausted)
          # Enum arms above: bcMask, bcScreen, bcMultiply, bcOverwrite — leaving only
          # bcNormal and bcUnsupported, both of which use the premultiplied-alpha Normal path.
      c3dAlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD,
                    GPU_ONE, GPU_ONE_MINUS_SRC_ALPHA,
                    GPU_ONE, GPU_ONE_MINUS_SRC_ALPHA)

    # TEV stage 0: MODULATE (texture × vertex_color) for both RGB and alpha.
    # vertex_color carries the tint; the shader does NOT normalise GPU_UNSIGNED_BYTE,
    # so the 1/255 factor is applied by the shader (same as the quad batch path).
    # Tint accuracy: asRgbx() premultiplies both the layer texture and the tint color.
    # MODULATE then computes (premul_tex × premul_tint). For opaque white tint this is
    # correct. For translucent or colored tints, verify against the GL backend on device
    # before relying on this path — premul×premul may not match the GL fragment path.
    let env = c3dGetTexEnv(0)
    c3dTexEnvInit(env)
    c3dTexEnvSrc(env, C3D_BOTH_MODE, GPU_TEXTURE0, GPU_PRIMARY_COLOR, GPU_TEXTURE0)
    c3dTexEnvFunc(env, C3D_BOTH_MODE, GPU_MODULATE)
    c3dDirtyTexEnv(env)

    # Bind the source layer texture to unit 0.
    # Texture cache coherency: the src layer was rendered to in an earlier bindTarget call
    # within the same C3D frame. C3D_FrameDrawOn (called above to switch to dst) may flush
    # the prior render target's color buffer; if src was the immediately prior target, the
    # frame switch provides the required write-back. If not, verify on hardware that a
    # frame split or explicit sync is not needed before sampling. blitAtlasToNewAtlas
    # sidesteps this by running in its own SYNCDRAW mini-frame; compositeLayer relies on
    # the caller's frame boundary or the FrameDrawOn flush semantics.
    c3dTexBind(0, addr b.texSlots[si].tex)

    # Bind the compositing shader (already loaded by initBlitShader).
    c3dBindProgram(addr b.shaderProg)

    # Compute UV bounds: src is POT-padded; only frameSize pixels are valid.
    # UV(0,0) = clip bottom-left; UV(uMax,vMax) = top-right of visible area.
    let uMax = W / src.width.float32
    let vMax = H / src.height.float32

    # Tint color via asRgbx() for premultiplied-alpha consistency.
    let tc = tint.asRgbx()

    # Compositing quad — vertex order: v0=BL(0,H), v1=BR(W,H), v2=TL(0,0), v3=TR(W,0)
    #
    # V-axis: V=0 at y=H (logical bottom), V=vMax at y=0 (logical top). The PICA200
    # RTT framebuffer stores clip_y=+1 (logical top) at the highest V value, matching
    # this mapping. Verified 2026-06-04 on Azahar.
    #
    # Triangle diagonal: blitIdxBuf is [0,1,2, 1,3,2] = triangles (BL,BR,TL) and (BR,TR,TL).
    # The shared BR→TL edge tiles the full quad — no uncovered region regardless of image
    # position. In clip space with topScreenOrthoProj the shared edge runs from BR(-1,-1)
    # to TL(+1,+1), i.e. the line clip_y=clip_x.
    #
    # IMPORTANT: v2=TL, v3=TR here (NOT v2=TR, v3=TL as in the original design-doc
    # sketch). The index buffer [0,1,2, 1,3,2] shares the edge between vertices 1 and 2,
    # so the tiling diagonal always runs from v1(BR). With v2=TL the diagonal is BR→TL
    # (clip_y=clip_x) and the two triangles tile the full quad. Swapping to v2=TR,v3=TL
    # instead shares the BR–TR (right) edge: the triangles then OVERLAP on the right and
    # leave an uncovered triangular GAP on the left (gap boundary = the BL→TR line,
    # clip_y=-clip_x). The image gets clipped to that gap — the triangular-image artifact
    # confirmed on Azahar.
    let vtx = cast[ptr UncheckedArray[RenderVtx]](b.blitVtxBuf)
    vtx[0] = RenderVtx(x: 0f, y: H,    u: 0f,   v: 0f,    r: tc.r, g: tc.g, b: tc.b, a: tc.a)  # BL
    vtx[1] = RenderVtx(x: W,  y: H,    u: uMax, v: 0f,    r: tc.r, g: tc.g, b: tc.b, a: tc.a)  # BR
    vtx[2] = RenderVtx(x: 0f, y: 0f,   u: 0f,   v: vMax,  r: tc.r, g: tc.g, b: tc.b, a: tc.a)  # TL
    vtx[3] = RenderVtx(x: W,  y: 0f,   u: uMax, v: vMax,  r: tc.r, g: tc.g, b: tc.b, a: tc.a)  # TR
    discard gspgpuFlushDataCache(b.blitVtxBuf, csize_t(4 * sizeof(RenderVtx)))

    # Attribute layout — same as blit/quad: v0=pos(float×2), v1=uv(float×2), v2=color(u8×4).
    var attrInfo: C3D_AttrInfo
    attrInfoInit(addr attrInfo)
    discard attrInfoAddLoader(addr attrInfo, 0, GPU_FLOAT_FORMAT, 2)
    discard attrInfoAddLoader(addr attrInfo, 1, GPU_FLOAT_FORMAT, 2)
    discard attrInfoAddLoader(addr attrInfo, 2, GPU_UNSIGNED_BYTE, 4)
    c3dSetAttrInfo(addr attrInfo)

    var bufInfo: C3D_BufInfo
    bufInfoInit(addr bufInfo)
    # Permutation 0x210: buffer slot i → AttrInfo loader i (sequential), same as
    # the blit and quad-batch paths. See blitAtlasToNewAtlas line ~502 for the reference.
    discard bufInfoAdd(addr bufInfo, b.blitVtxBuf, sizeof(RenderVtx), 3, 0x210'u64)
    c3dSetBufInfo(addr bufInfo)

    # Re-use blitIdxBuf (actual pattern: [0,1,2, 1,3,2] from initBlitShader).
    # Vertex order matches blit path: v0=BL, v1=BR, v2=TL, v3=TR. The [0,1,2, 1,3,2]
    # index buffer produces a BR→TL diagonal (clip_y=clip_x), verified on Azahar 2026-06-04.
    # See the IMPORTANT vertex-order note above for why v2=TL,v3=TR is required.
    c3dDrawElements(GPU_TRIANGLES, 6, C3D_UNSIGNED_BYTE, b.blitIdxBuf)

    # Restore pipeline state for subsequent draws. The flush() contract says the caller
    # re-establishes its own shader/TEV/blend; we restore TEV to REPLACE (simpler
    # pass-through) and the blend to the normal premultiplied-alpha convention, so the
    # next draw lands in a predictable state regardless of which blend mode was used here.
    # Depth test: left disabled — 2D boxy draws do not use depth testing.
    let envPost = c3dGetTexEnv(0)
    c3dTexEnvInit(envPost)
    c3dTexEnvSrc(envPost, C3D_BOTH_MODE, GPU_TEXTURE0, GPU_TEXTURE0, GPU_TEXTURE0)
    c3dTexEnvFunc(envPost, C3D_BOTH_MODE, GPU_REPLACE)
    c3dDirtyTexEnv(envPost)
    c3dAlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD,
                  GPU_ONE, GPU_ONE_MINUS_SRC_ALPHA,
                  GPU_ONE, GPU_ONE_MINUS_SRC_ALPHA)

  # ---------------------------------------------------------------------------
  # restoreState — re-bind VAO/IBO/FBO after exitRawOpenGLMode
  # ---------------------------------------------------------------------------

  method restoreState*(b: Citro3dBackend, s: BackendStateSnapshot) =
    ## Re-bind shader, attribute/buffer info, and render target from `s`.
    ## On citro3d: VAO and IBO snapshot fields are unused (citro3d has no VAO).
    ## Not yet wired: no-op until the boxy.nim 3DS port wires enterRawOpenGLMode.
    ## NOTE: compositeLayer partially restores pipeline state (TEV, blend) after each
    ## call; restoreState is NOT the mechanism for that — see compositeLayer for details.
    discard

  # ---------------------------------------------------------------------------
  # destroy — deterministic teardown of all GPU/C/linearAlloc resources
  # ---------------------------------------------------------------------------

  method destroy*(b: Citro3dBackend) =
    ## Release all raw resources owned by this backend, in the correct order.
    ## Safe to call on a partially-initialised backend or after individual
    ## deleteTexture/createLayerTarget calls — every step is nil-guarded.
    ##
    ## Order matters: free GPU objects before their backing buffers.
    ##   1. freeShaderState: blit prog+dvlb, blitVtxBuf, blitIdxBuf
    ##   2. quad buffers: quadVtxBuf, quadIdxBuf
    ##   3. slot teardown: texSlots (VRAM tex + mirror) and rtSlots (RT)
    ##
    ## Calling any other backend method after destroy is undefined behavior.
    ## freeShaderState resets shaderReady=false so blitAtlasToNewAtlas cannot
    ## re-enter freed buffers, but this is a safety net, not a license to reuse.
    ##
    ## Call site: boxy.nim:destroy (Boxy.backend.destroy()). Call before c3dFini.
    ## atlas_compile_3ds.nim exercises this teardown path on Azahar.

    # 1. Blit-shader resources (freeShaderState handles nil guards internally).
    b.freeShaderState()

    # 2. Quad batch buffers.
    if b.quadIdxBuf != nil:
      linearFree(b.quadIdxBuf)
      b.quadIdxBuf = nil
    if b.quadVtxBuf != nil:
      linearFree(b.quadVtxBuf)
      b.quadVtxBuf = nil
    b.quadBufsReady = false
    b.quadCount = 0

    # 3a. RT slots: free render targets before their backing textures.
    for i in 0 ..< maxRtSlots:
      if b.rtSlots[i].used:
        c3dRenderTargetDelete(b.rtSlots[i].rt)
        b.rtSlots[i].rt      = nil
        b.rtSlots[i].bytes   = 0
        b.rtSlots[i].used    = false
        b.rtSlots[i].cleared = false

    # 3b. Texture slots: free VRAM texture and linearAlloc mirror.
    # Skip linkedRt cleanup — already done above via the RT loop.
    for i in 0 ..< maxTexSlots:
      if b.texSlots[i].used:
        c3dTexDelete(addr b.texSlots[i].tex)
        if b.texSlots[i].mirror != nil:
          linearFree(b.texSlots[i].mirror)
          b.texSlots[i].mirror  = nil
        b.texSlots[i].sideLen  = 0
        b.texSlots[i].linkedRt = -1
        b.texSlots[i].used     = false
    b.atlasSideLen = 0
