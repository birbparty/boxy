# pixie / nimsimd / zippy Cross-Compilation for ARMv6K

Analysis of whether these packages can cross-compile for the Nintendo 3DS (ARMv6K / arm-none-eabi-gcc / --gc:arc).

## Executive Summary

**Compilation: passes cleanly.** All three packages properly gate SIMD intrinsics on `when defined(amd64)` / `when defined(arm64)`. ARMv6K falls through all guards and uses portable C fallbacks.

**Runtime: pixie is broken** because it is imported unconditionally and its high-level image APIs assume OS/libc support that 3DS bare-metal may lack.

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

| Location | Operation | Status on 3DS |
|---|---|---|
| `boxy.nim:539` | `tileImage.isOneColor()` | one-color tile optimization — broken |
| `boxy.nim:540` | `tileImage[0, 0].color` | direct pixel access — broken |
| `boxy.nim:631` | `newImage(w, h)` for whiteTile | CPU image alloc — may fail |
| `boxy.nim:1169` | `texture.readImage()` | GPU→CPU readback — broken |
| `textures.nim:95` | `newTexture*(image: Image)` | core texture upload path — broken |

Disabling pixie removes:
- One-color tile optimisation
- Bordered tile splitting
- CPU mipmap chain generation
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

A minimal `pixie_stub.nim` for 3DS needs:
- `Image` type with `width`, `height`, `data: seq[ColorRGBA]`
- `newImage(w, h: int): Image`
- `isOneColor(img: Image): bool`
- `[]` pixel accessor
- No SIMD, no file I/O

## Verdict

`--gc:arc` is sound. SIMD guards are properly written. The blocker is the unconditional `import pixie` in `boxy.nim` and `textures.nim` — these must be guarded before 3DS compilation can proceed.
