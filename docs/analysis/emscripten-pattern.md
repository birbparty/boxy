# Emscripten Conditional Compilation Pattern in Boxy

Analysis of `when defined(emscripten):` guards and their implications for 3DS backend design.

## Executive Summary

The Emscripten pattern is **shallow and shader-specific**. It does not guard `import opengl`, does not restructure the `Boxy` type, and does not abstract the rendering pipeline. It only changes GLSL version strings in shader compilation. This is insufficient for 3DS support.

## Complete Inventory of Emscripten Guards

| File | Lines | Type | What it does |
|---|---|---|---|
| `boxy.nim` | 202–260 | `when defined(emscripten)` | Shader compilation: GLSL version + precision header |
| `boxy.nim` | 393–394 | `when not defined(emscripten)` | Debug atlas dump to file (skipped on Emscripten) |
| `shaders.nim` | 33–44 | `when defined(emscripten)` | Shader error log formatting (cosmetic only) |
| `textures.nim` | 187–196 | `when defined(emscripten)` | `readImage()` raises exception (browser security) |

Total: **4 guards**. None affect type structure or core rendering logic.

## Block 1: Shader Compilation (boxy.nim:202–260)

```nim
when defined(emscripten):
  result.atlasShader = newShader(
    ("atlasVert", toGLSL(atlasVert, "300 es", "precision highp float;\n")),
    ("atlasMain", toGLSL(atlasMain, "300 es", "precision highp float;\n"))
  )
  # ... 6 more shaders with "300 es" + precision header
else:
  result.atlasShader = newShader(
    ("atlasVert", toGLSL(atlasVert, "410", "")),
    ("atlasMain", toGLSL(atlasMain, "410", ""))
  )
  # ... 6 more shaders with "410" + no precision header
```

Only two parameters differ: GLSL version string and precision header prefix.

## Block 2: Error Log Format (shaders.nim:33–44)

Emscripten returns raw log; desktop reformats to clickable IDE format. Cosmetic only.

## Block 3: Texture Readback (textures.nim:187–196)

```nim
when defined(emscripten):
  raise newException(Exception, "readImage is not supported on emscripten...")
else:
  glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, ...)
```

Disables one API on Emscripten. All other APIs remain unchanged.

## Block 4: Debug File Dump (boxy.nim:393–394)

One-line skip of `atlasTexture.writeFile()` on Emscripten. No semantic impact.

## What Is NOT Guarded

**`import opengl` (boxy.nim:3):** Unconditional. No `when defined(emscripten)` around it.

**The Boxy type (boxy.nim:31–62):** All fields (`GLuint`, `Texture`, `Buffer`, shader handles) are always present. No platform variants.

**`enterRawOpenGLMode`/`exitRawOpenGLMode` (boxy.nim:338–358):** Raw GL calls (`glBindVertexArray`, `glBindBuffer`, `glBindFramebuffer`, `glBlendFunc`). Not guarded. Work on Emscripten only because WebGL accepts the same API surface.

## Why Emscripten Works But 3DS Cannot Follow the Same Pattern

Emscripten provides WebGL ES 3.0 — an API-compatible superset of the calls Boxy makes. Only GLSL version strings differ. The Emscripten port is a **configuration change**, not a **structural change**.

3DS uses citro3d/citro2d — a completely different API:
- No `glBindTexture`, `glDrawElements`, `glUseProgram`, etc.
- Shader format is PICA200 (custom Nintendo architecture), not GLSL
- Framebuffer management differs fundamentally
- No equivalent to `glGetTexImage` for GPU→CPU readback

## Structural Changes Required for 3DS

A proper 3DS port needs:

1. **Guard `import opengl`** — replace with `import citro3d` when `defined(ds3)`
2. **Abstract the Boxy type** — `GLuint` fields become citro3d handles or a union type
3. **Pluggable shader compilation** — `toGLSL` → PICA200 equivalent
4. **Render command abstraction** — replace all inline `glXxx()` calls with backend dispatch
5. **Abstract `Texture` and `Buffer` types** — current types directly embed GL enums

## Implication for backend_interface.nim

The Emscripten pattern cannot scale to a third backend by adding more `when` blocks. The necessary design is a renderer interface that abstracts over:
- OpenGL (desktop)
- WebGL / Emscripten (GLSL 300 es)
- citro3d (3DS)

See `docs/analysis/boxy-gl-backend-extraction.md` for the full backend interface specification.
