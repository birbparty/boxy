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

  type
    TexSlot = object
      tex: C3D_Tex
      mirror: pointer   ## linearAlloc buffer; size = sideLen*sideLen*4 bytes
      sideLen: int
      used: bool

    Citro3dBackend* = ref object of Backend
      ## Nintendo 3DS citro3d rendering backend.
      ## Atlas texture management implemented; quad batching / TEV in follow-on tasks.
      ##
      ## Handle lifetime: handles are not validated against slot reuse. Never retain
      ## a TextureHandle past the matching deleteTexture call — a freed-then-reallocated
      ## slot will have the same id (ABA hazard).
      texSlots: array[maxTexSlots, TexSlot]

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
    ## WARNING (boxy-z5d): this uploads the ENTIRE mirror on every call.
    ## Once blitAtlasToNewAtlas writes the VRAM atlas directly via GPU blit, the
    ## mirror is stale — a subsequent whole-mirror DMA would OVERWRITE the blit
    ## result. boxy-z5d MUST switch to a partial (sub-rect) upload or re-sync
    ## the mirror from VRAM after the blit. This is a correctness requirement,
    ## not an optimisation.
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
  # Stubs for follow-on tasks
  # ---------------------------------------------------------------------------

  method createLayerTarget*(b: Citro3dBackend,
      width, height: int32): tuple[tex: TextureHandle, rt: RenderTargetHandle] =
    raise newException(BackendError, "createLayerTarget: not yet implemented (boxy-z5d)")

  method bindTarget*(b: Citro3dBackend, dst: RenderTargetHandle) =
    raise newException(BackendError, "bindTarget: not yet implemented (boxy-z5d)")

  method flush*(b: Citro3dBackend) =
    raise newException(BackendError, "flush: not yet implemented (boxy-z5d)")

  method beginAtlasTarget*(b: Citro3dBackend, atlas: TextureHandle) =
    raise newException(BackendError, "beginAtlasTarget: not yet implemented (boxy-z5d)")

  method endAtlasTarget*(b: Citro3dBackend, atlas: TextureHandle) =
    raise newException(BackendError, "endAtlasTarget: not yet implemented (boxy-z5d)")

  method blitAtlasToNewAtlas*(b: Citro3dBackend,
      old, `new`: TextureHandle) =
    raise newException(BackendError, "blitAtlasToNewAtlas: not yet implemented (boxy-z5d)")

  method compositeLayer*(b: Citro3dBackend,
      src: TextureHandle,
      dst: RenderTargetHandle,
      dstTexture: TextureHandle,
      blendMode: BlendMode, tint: Color,
      frameSize: IVec2, atlasSize: int) =
    raise newException(BackendError, "compositeLayer: not yet implemented (boxy-z5d)")

  method restoreState*(b: Citro3dBackend, s: BackendStateSnapshot) =
    raise newException(BackendError, "restoreState: not yet implemented (boxy-z5d)")
