## citro3d backend for boxy — PICA200 Nintendo 3DS rendering backend.
##
## Provides:
##   - swizzleTileIntoAtlas: Morton/Z-order tile writer for GPU_RGBA8 uploads
##   - mortonIdx, pixieRgbaToGpuAbgr: exported helpers (unit-testable on host)
##   - Citro3dBackend: stub Backend subtype (ds3-only, further impl in boxy-avl)
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

const mortonTable* = [0, 1, 4, 5, 16, 17, 20, 21]
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
  ## uint32 (bytes A,B,G,R). Both representations are 4×uint8 packed little-
  ## endian; the conversion is a 32-bit byte reversal (bswap32).
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
  ## src       : source pixel data (Pixie ColorRGBX, R at byte 0)
  ## srcW/srcH : source dimensions in pixels
  ## dstAtlas  : destination atlas buffer in PICA200 GPU_RGBA8 Morton layout
  ## atlasW    : atlas width in pixels (power of 2, multiple of 8, ≤ 1024)
  ## atlasStride: block columns per row = atlasW / 8 (NOT atlasW; caller computes)
  ## dstX/dstY : destination top-left in atlas pixel coordinates (need not be
  ##             multiples of 8; block and within-block indices computed per pixel)
  ##
  ## Each pixel is Morton-placed and byte-swapped (Pixie RGBA → PICA200 ABGR).
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
# Citro3dBackend — stub Backend implementation for Nintendo 3DS
#
# Only compiled when --define:ds3 is active. See boxy-avl and follow-on
# tasks for atlas texture management, quad batching, and TEV configuration.
# ---------------------------------------------------------------------------

when defined(ds3):
  import ../bindings/citro3d
  export citro3d

  type
    Citro3dBackend* = ref object of Backend
      ## Nintendo 3DS citro3d rendering backend.
      ## Atlas texture management: boxy-avl.
      ## Quad batching + TEV: follow-on tasks.

  proc newCitro3dBackend*(): Citro3dBackend =
    result = Citro3dBackend()

  method createAtlasTexture*(backend: Citro3dBackend, size: int): TextureHandle =
    raise newException(BackendError, "createAtlasTexture: not yet implemented (boxy-avl)")

  method deleteTexture*(backend: Citro3dBackend, handle: TextureHandle) =
    raise newException(BackendError, "deleteTexture: not yet implemented (boxy-avl)")

  method createLayerTarget*(backend: Citro3dBackend,
      width, height: int32): tuple[tex: TextureHandle, rt: RenderTargetHandle] =
    raise newException(BackendError, "createLayerTarget: not yet implemented (boxy-avl)")

  method bindTarget*(backend: Citro3dBackend, dst: RenderTargetHandle) =
    raise newException(BackendError, "bindTarget: not yet implemented (boxy-avl)")

  method uploadTile*(backend: Citro3dBackend, handle: TextureHandle,
      x, y: int, image: Image, level: int) =
    raise newException(BackendError, "uploadTile: not yet implemented (boxy-avl)")

  method flush*(backend: Citro3dBackend) =
    raise newException(BackendError, "flush: not yet implemented (boxy-avl)")

  method beginAtlasTarget*(backend: Citro3dBackend, atlas: TextureHandle) =
    raise newException(BackendError, "beginAtlasTarget: not yet implemented (boxy-avl)")

  method endAtlasTarget*(backend: Citro3dBackend, atlas: TextureHandle) =
    raise newException(BackendError, "endAtlasTarget: not yet implemented (boxy-avl)")

  method blitAtlasToNewAtlas*(backend: Citro3dBackend,
      old, `new`: TextureHandle) =
    raise newException(BackendError, "blitAtlasToNewAtlas: not yet implemented (boxy-avl)")

  method compositeLayer*(backend: Citro3dBackend,
      src: TextureHandle,
      dst: RenderTargetHandle,
      dstTexture: TextureHandle,
      blendMode: BlendMode, tint: Color,
      frameSize: IVec2, atlasSize: int) =
    raise newException(BackendError, "compositeLayer: not yet implemented (boxy-avl)")

  method restoreState*(backend: Citro3dBackend, s: BackendStateSnapshot) =
    raise newException(BackendError, "restoreState: not yet implemented (boxy-avl)")
