# pixie / nimsimd / zippy Cross-Compilation for ARMv6K

Analysis of whether these packages can cross-compile for the Nintendo 3DS (ARMv6K / arm-none-eabi-gcc / --gc:arc).

> **Verification status:** SIMD guard analysis verified against installed sources (pixie 6.1.0, nimsimd 1.3.2, zippy 0.10.19). Unconditional import locations verified against `src/boxy.nim` and `src/boxy/textures.nim`. All runtime verdicts are **inferred, not executed** — nothing has been run on 3DS hardware or an emulator. The one test that converts hypotheses to facts: cross-compile a trivial Nim program calling `newImage`, `isOneColor`, and `[]` with `-d:ds3` against the devkitARM toolchain and link it.

> **Note:** pixie is a transitive dependency (via windy/shady); `boxy.nimble` does not pin it directly. The analyzed pixie 6.1.0 is whatever was installed. A future `nimble install` could pull a pixie version with a new ARM branch — re-run this analysis if the version changes.

## Executive Summary

**Compilation: passes cleanly.** All three packages properly gate SIMD intrinsics on `when defined(amd64)` / `when defined(arm64)`. ARMv6K falls through all guards and uses portable C fallbacks.

**The real blocker is not runtime failure but the unconditional `import pixie` / `export pixie`** in `boxy.nim` and `textures.nim`. The 3DS toolchain is **newlib-hosted via libctru** (not bare-metal): libctru provides `malloc`/`free`, file I/O via `sdmc:/` and `romfs:/` devoptabs, and the C runtime — which is exactly why `useMalloc` + `nimAllocPagesViaMalloc` work. Pure CPU pixel operations (`isOneColor`, `[]`) are low-risk given that allocator. The genuine high-risk items are file I/O paths (PNG decode via zippy inflate) and GPU readback (`readImage` / `glGetTexImage`, which has no citro3d equivalent).

## SIMD Architecture Guard Analysis

### pixie (6.1.0) — `pixie/simd.nim`
```nim
when allowSimd:
  when defined(amd64):
    import simd/sse2, nimsimd/runtimecheck, simd/avx, simd/avx2
  elif defined(arm64):
    import simd/neon, nimsimd/neon
```
ARMv6K: neither branch taken. Compiles cleanly.

Safety flag: `-d:pixieNoSimd` forces the portable path unconditionally regardless of architecture detection (`pixie/simd.nim:5`: `const allowSimd* = not defined(pixieNoSimd) and not defined(tcc)`). Useful if a future pixie version adds an ARM branch that misfires.

### nimsimd (1.3.2) — `nimsimd/hassimd.nim`
Macro dispatch only handles `amd64` and `arm64`. For ARMv6K the macro emits nothing — non-SIMD path used. Compiles cleanly.

### zippy (0.10.19) — `zippy/adler32.nim`, `zippy/crc32_simd.nim`
```nim
when allowSimd:
  when defined(amd64): ...
  elif defined(arm64): ...
```
No ARMv6K entry. Falls through to portable C. Compiles cleanly.

## Unconditional pixie Import (the real problem)

**`src/boxy.nim` line 3:**
```nim
import ..., opengl, pixie, ...
```

**`src/boxy.nim` line 8:**
```nim
export pixie
```

**`src/boxy/textures.nim` line 1:**
```nim
import buffers, opengl, pixie, vmath
```

Both imports are unconditional. No `when not defined(ds3):` guard exists.

## What pixie Does in Boxy

| Location | Operation | Compiles? | Runtime Concern on 3DS |
|---|---|---|---|
| `boxy.nim:76` | `atlasTexture.readImage()` | Yes | **High** — GPU→CPU via `glGetTexImage`; no citro3d equivalent |
| `boxy.nim:521–522` | `tileImage.isOneColor()` / `image[0,0].color` | Yes | Low — pure CPU `seq` ops; works if `useMalloc` works |
| `boxy.nim:539–540` | `tileImage.isOneColor()` / `image[0,0].color` | Yes | Low — same as above (per-tile path) |
| `boxy.nim:631` | `newImage(w, h)` for whiteTile | Yes | Low — malloc-backed allocation; works with `useMalloc` |
| `boxy.nim:1169` | `texture.readImage()` | Yes | **High** — GPU→CPU readback; no citro3d equivalent |
| `textures.nim:95` | `newTexture*(image: Image)` | Yes | Medium — pixie `Image` type; depends on `superImage`, mipmap chain |
| `textures.nim:200` | `writeFile` / `readImage` | Yes | **High** — file I/O + GPU readback; must be guarded for 3DS |

Disabling pixie removes:
- One-color tile optimisation
- Bordered tile splitting
- CPU mipmap chain generation (pixie `minifyBy2` in `textures.nim:updateSubImage`)
- `drawImage` LOD selection
- Layer readback via `getImage()`

## Recommended Path Forward

**Wrap pixie imports in `when` guards:**

```nim
# src/boxy.nim
when not defined(ds3):
  import pixie
  export pixie

# src/boxy/textures.nim
when not defined(ds3):
  import pixie
  # pixie-dependent procs
else:
  # 3DS-native image stubs
```

A minimal `pixie_stub.nim` for 3DS needs — note pixie stores **premultiplied alpha** (`ColorRGBX`, not `ColorRGBA`):
- `Image` type with `width`, `height`, `data: seq[ColorRGBX]`
- `newImage(w, h: int): Image`
- `isOneColor(img: Image): bool`
- `[]` pixel accessor returning `ColorRGBX` with `.color` conversion to `Color`
- `superImage(img: Image, x, y, w, h: int): Image` — used at `boxy.nim:534`
- `width` / `height` field accessors
- `getFormat` — used at `textures.nim:102`
- `flipVertical` — used at `textures.nim:201`
- No SIMD, no file I/O

The CPU mipmap chain (currently `image.minifyBy2()` loop in `textures.nim:updateSubImage`) must either be replaced with a non-pixie CPU minify or offloaded to GPU mipmap generation (`glGenerateMipmap` / citro3d equivalent).

## Verdict

`--gc:arc` is sound. SIMD guards are properly written. The blockers are:
1. The unconditional `import pixie` / `export pixie` in `boxy.nim` and `textures.nim` — these must be guarded before 3DS compilation can proceed.
2. File I/O paths (pixie `writeFile`/PNG decode) and GPU readback (`readImage` / `glGetTexImage`) — these have no citro3d equivalent and must be removed or replaced.

Pure CPU pixel operations (`isOneColor`, `[]`, `newImage`) are low risk given the newlib-hosted allocator environment.
