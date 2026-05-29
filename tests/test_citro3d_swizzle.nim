## Tests for the Morton/Z-order swizzle utility in citro3d_backend.nim.
##
## Runs on host (no --define:ds3 required). Tests mortonIdx and
## swizzleTileIntoAtlas for correct spatial placement and byte-order
## conversion.
##
## Expected Morton indices are anchored to the devkitPro/tex3ds
## source/swizzle.cpp cycle table, NOT re-derived from this impl.
## That ensures the test catches a wrong convention, not just internal
## self-consistency.
##
## Usage:
##   nim c -r tests/test_citro3d_swizzle.nim

import boxy/backends/citro3d_backend

proc assertMsg(cond: bool, msg: string) =
  if not cond:
    echo "FAIL: ", msg
    quit(1)
  echo "PASS: ", msg

# ---------------------------------------------------------------------------
# Part 1: mortonIdx — anchored against tex3ds source/swizzle.cpp
#
# The swizzle.cpp file applies in-place 4-cycles and 2-swaps to an 8×8
# pixel block stored in linear row-major order (index = y*8 + x).
# Reading the cycles backwards gives: pixel originally at linear position i
# moves to Morton index mortonIdx(i%8, i/8).
#
# Cycle (2, 8, 16, 4) in swizzle.cpp (forward: v@entry[1]→entry[0]):
#   linear 2 → Morton 4  (x=2, y=0)
#   linear 8 → Morton 2  (x=0, y=1)
#   linear 16 → Morton 8  (x=0, y=2)
#   linear 4 → Morton 16 (x=4, y=0)
#
# Cycle (38, 42, 56, 52) in swizzle.cpp:
#   linear 38 → Morton 52 (x=6, y=4)
#   linear 42 → Morton 38 (x=2, y=5)
#   linear 52 → Morton 56 (x=4, y=6)
#   linear 56 → Morton 42 (x=0, y=7)
#
# Swap (12, 18) in swizzle.cpp:
#   linear 12 → Morton 18 (x=4, y=1)
#   linear 18 → Morton 12 (x=2, y=2)
# ---------------------------------------------------------------------------

# From cycle (2, 8, 16, 4) — authoritative tex3ds reference
assertMsg(mortonIdx(2, 0) == 4,  "mortonIdx(2,0): tex3ds cycle (2,8,16,4)")
assertMsg(mortonIdx(0, 1) == 2,  "mortonIdx(0,1): tex3ds cycle (2,8,16,4)")
assertMsg(mortonIdx(0, 2) == 8,  "mortonIdx(0,2): tex3ds cycle (2,8,16,4)")
assertMsg(mortonIdx(4, 0) == 16, "mortonIdx(4,0): tex3ds cycle (2,8,16,4)")

# From cycle (38, 42, 56, 52)
assertMsg(mortonIdx(6, 4) == 52, "mortonIdx(6,4): tex3ds cycle (38,42,56,52)")
assertMsg(mortonIdx(2, 5) == 38, "mortonIdx(2,5): tex3ds cycle (38,42,56,52)")
assertMsg(mortonIdx(4, 6) == 56, "mortonIdx(4,6): tex3ds cycle (38,42,56,52)")
assertMsg(mortonIdx(0, 7) == 42, "mortonIdx(0,7): tex3ds cycle (38,42,56,52)")

# From swap (12, 18)
assertMsg(mortonIdx(4, 1) == 18, "mortonIdx(4,1): tex3ds swap(12,18)")
assertMsg(mortonIdx(2, 2) == 12, "mortonIdx(2,2): tex3ds swap(12,18)")

# Corner/edge cases
assertMsg(mortonIdx(0, 0) == 0,  "mortonIdx(0,0): origin")
assertMsg(mortonIdx(7, 7) == 63, "mortonIdx(7,7): max corner")
assertMsg(mortonIdx(1, 0) == 1,  "mortonIdx(1,0): x=1,y=0")
assertMsg(mortonIdx(0, 1) == 2,  "mortonIdx(0,1): x=0,y=1")

# ---------------------------------------------------------------------------
# Part 2: pixieRgbaToGpuAbgr — byte-order conversion
#
# Pixie ColorRGBX bytes: R(0), G(1), B(2), A(3) → uint32 = R | G<<8 | B<<16 | A<<24
# PICA200 GPU_RGBA8 bytes: A(0), B(1), G(2), R(3) → uint32 = A | B<<8 | G<<16 | R<<24
# Reference: tex3ds source/encode.cpp rgba8888() outputs Alpha at byte 0.
#
# Test with R=0x11 G=0x22 B=0x33 A=0x44:
#   input  = 0x44332211 (Pixie: bytes [11, 22, 33, 44])
#   output = 0x11223344 (PICA:  bytes [44, 33, 22, 11] = [A, B, G, R])
# ---------------------------------------------------------------------------

let pixiePixel: uint32 = 0x44332211'u32  # R=0x11,G=0x22,B=0x33,A=0x44
let gpuPixel = pixieRgbaToGpuAbgr(pixiePixel)

assertMsg(
  (gpuPixel and 0xFF) == 0x44,            # byte 0 = A
  "ABGR byte 0 = A (tex3ds rgba8888 output[0]=alpha)")
assertMsg(
  ((gpuPixel shr 8) and 0xFF) == 0x33,    # byte 1 = B
  "ABGR byte 1 = B (tex3ds rgba8888 output[1]=blue)")
assertMsg(
  ((gpuPixel shr 16) and 0xFF) == 0x22,   # byte 2 = G
  "ABGR byte 2 = G (tex3ds rgba8888 output[2]=green)")
assertMsg(
  ((gpuPixel shr 24) and 0xFF) == 0x11,   # byte 3 = R
  "ABGR byte 3 = R (tex3ds rgba8888 output[3]=red)")

# Identity: bswap32(bswap32(x)) == x
assertMsg(pixieRgbaToGpuAbgr(pixieRgbaToGpuAbgr(pixiePixel)) == pixiePixel,
  "pixieRgbaToGpuAbgr is its own inverse (bswap32 involution)")

# ---------------------------------------------------------------------------
# Part 3: swizzleTileIntoAtlas — spatial placement and byte order
#
# 16×16 atlas (atlasW=16, atlasStride=2). Each cell is 4 bytes (RGBA8).
# Buffer is 16×16×4 = 1024 bytes.
# ---------------------------------------------------------------------------

const
  ATLAS_W = 16
  ATLAS_STRIDE = ATLAS_W div 8   # = 2 (block columns per row)
  ATLAS_BYTES = ATLAS_W * ATLAS_W * 4

# --- test 3a: single pixel at atlas origin (0, 0) ---
block:
  var src: array[4, uint8] = [0xAA'u8, 0xBB, 0xCC, 0xDD]  # R, G, B, A
  var dst: array[ATLAS_BYTES, uint8]

  swizzleTileIntoAtlas(src[0].addr, 1, 1, dst[0].addr, ATLAS_W, ATLAS_STRIDE, 0, 0)

  # dstX=0,dstY=0 → block(0,0), within(0,0), mortonIdx=0 → dstIdx=0
  let byteOffset = 0 * 4  # dstIdx * 4 bytes per pixel

  # Expected GPU_RGBA8: A,B,G,R = DD,CC,BB,AA
  assertMsg(dst[byteOffset + 0] == 0xDD, "origin pixel: byte0=A")
  assertMsg(dst[byteOffset + 1] == 0xCC, "origin pixel: byte1=B")
  assertMsg(dst[byteOffset + 2] == 0xBB, "origin pixel: byte2=G")
  assertMsg(dst[byteOffset + 3] == 0xAA, "origin pixel: byte3=R")

# --- test 3b: pixel at (1, 0) → mortonIdx(1,0)=1 ---
block:
  var src: array[4, uint8] = [0x11'u8, 0x22, 0x33, 0x44]
  var dst: array[ATLAS_BYTES, uint8]

  swizzleTileIntoAtlas(src[0].addr, 1, 1, dst[0].addr, ATLAS_W, ATLAS_STRIDE, 1, 0)

  # block(0,0), within(1,0), mortonIdx(1,0)=1, dstIdx=1
  let off = 1 * 4
  assertMsg(dst[off + 0] == 0x44, "(1,0) byte0=A")
  assertMsg(dst[off + 3] == 0x11, "(1,0) byte3=R")

# --- test 3c: pixel at (0, 1) → mortonIdx(0,1)=2 (NOT at row-stride offset) ---
block:
  var src: array[4, uint8] = [0x55'u8, 0x66, 0x77, 0x88]
  var dst: array[ATLAS_BYTES, uint8]

  swizzleTileIntoAtlas(src[0].addr, 1, 1, dst[0].addr, ATLAS_W, ATLAS_STRIDE, 0, 1)

  # Within the same 8×8 block: mortonIdx(0,1)=2 (from tex3ds cycle (2,8,16,4))
  # dstIdx = 0 * 64 + 2 = 2; NOT at offset atlasW=16 as in linear layout
  let off = 2 * 4
  assertMsg(dst[off + 0] == 0x88, "(0,1) byte0=A: Morton y≠linear stride")
  assertMsg(dst[off + 3] == 0x55, "(0,1) byte3=R: Morton y≠linear stride")
  # Verify it is NOT at the linear row offset (would be index 16 in linear layout)
  let linearOff = 16 * 4
  assertMsg(dst[linearOff + 0] == 0, "(0,1) not at linear row offset 16")

# --- test 3d: pixel at (8, 0) → second block column ---
block:
  var src: array[4, uint8] = [0xAA'u8, 0xBB, 0xCC, 0xDD]
  var dst: array[ATLAS_BYTES, uint8]

  swizzleTileIntoAtlas(src[0].addr, 1, 1, dst[0].addr, ATLAS_W, ATLAS_STRIDE, 8, 0)

  # block(1, 0), within(0, 0), mortonIdx=0
  # dstIdx = (0 * 2 + 1) * 64 + 0 = 64
  let off = 64 * 4
  assertMsg(dst[off + 0] == 0xDD, "(8,0) byte0=A: second block column")
  assertMsg(dst[off + 3] == 0xAA, "(8,0) byte3=R: second block column")

# --- test 3e: pixel at non-aligned position (9, 5) ---
block:
  var src: array[4, uint8] = [0x12'u8, 0x34, 0x56, 0x78]
  var dst: array[ATLAS_BYTES, uint8]

  swizzleTileIntoAtlas(src[0].addr, 1, 1, dst[0].addr, ATLAS_W, ATLAS_STRIDE, 9, 5)

  # px=9, py=5: blockX=1, blockY=0, withinX=1, withinY=5
  # mortonIdx(1,5) = mortonTable[1] | (mortonTable[5] << 1)
  #               = 1 | (17 << 1) = 1 | 34 = 35
  # dstIdx = (0 * 2 + 1) * 64 + 35 = 64 + 35 = 99
  let expectedIdx = 99
  let off = expectedIdx * 4
  assertMsg(dst[off + 0] == 0x78, "(9,5) byte0=A: non-aligned position")
  assertMsg(dst[off + 3] == 0x12, "(9,5) byte3=R: non-aligned position")

# --- test 3f: 2×2 source image at origin, verify all 4 pixels land correctly ---
block:
  # Source (top-left-origin, row-major):
  #   pixel[0,0]=0x01020304 (R=1,G=2,B=3,A=4)
  #   pixel[1,0]=0x05060708
  #   pixel[0,1]=0x090A0B0C
  #   pixel[1,1]=0x0D0E0F10
  var src: array[16, uint8] = [
    0x01'u8, 0x02, 0x03, 0x04,  # (0,0): R,G,B,A
    0x05'u8, 0x06, 0x07, 0x08,  # (1,0)
    0x09'u8, 0x0A, 0x0B, 0x0C,  # (0,1)
    0x0D'u8, 0x0E, 0x0F, 0x10,  # (1,1)
  ]
  var dst: array[ATLAS_BYTES, uint8]

  swizzleTileIntoAtlas(src[0].addr, 2, 2, dst[0].addr, ATLAS_W, ATLAS_STRIDE, 0, 0)

  # (0,0): mortonIdx=0, GPU bytes A=04,B=03,G=02,R=01
  assertMsg(dst[0*4+0] == 0x04 and dst[0*4+3] == 0x01, "2x2 pixel(0,0)")
  # (1,0): mortonIdx=1, GPU bytes A=08,B=07,G=06,R=05
  assertMsg(dst[1*4+0] == 0x08 and dst[1*4+3] == 0x05, "2x2 pixel(1,0)")
  # (0,1): mortonIdx(0,1)=2, GPU bytes A=0C,B=0B,G=0A,R=09
  assertMsg(dst[2*4+0] == 0x0C and dst[2*4+3] == 0x09, "2x2 pixel(0,1)")
  # (1,1): mortonIdx(1,1)=3, GPU bytes A=10,B=0F,G=0E,R=0D
  assertMsg(dst[3*4+0] == 0x10 and dst[3*4+3] == 0x0D, "2x2 pixel(1,1)")

echo "ALL TESTS PASSED"
