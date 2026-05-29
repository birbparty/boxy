# Boxy Type GL Fields and Backend Interface Design

Analysis of `src/boxy.nim` for extracting a platform-agnostic rendering backend.

## GL-Specific Fields in the Boxy Type

All line numbers reference `src/boxy.nim`.

| Field | Type | Line | GPU Concept |
|---|---|---|---|
| `atlasTexture` | `Texture` | 35 | Main texture atlas |
| `tmpTexture` | `Texture` | 35 | Scratch texture for post-processing |
| `tmpFramebuffer` | `GLuint` | 36 | Temporary FBO for blends/blurs |
| `layerFramebuffers` | `seq[GLuint]` | 39 | Per-layer render targets |
| `vertexArrayId` | `GLuint` | 54 | Vertex Array Object |
| `positions.buffer` | `Buffer` | 59 | Vertex position data (VEC2 float32) |
| `colors.buffer` | `Buffer` | 60 | Vertex color data (VEC4 uint8) |
| `uvs.buffer` | `Buffer` | 61 | Texture coordinate data (VEC2 float32) |
| `indices.buffer` | `Buffer` | 62 | Index buffer (SCALAR uint16) |

Shader fields (`atlasShader`, `maskShader`, `blendShader`, etc.) are also platform-specific.

## Import Graph

**Line 3 (unconditional):**
```nim
import ..., opengl, pixie, shady, ...
```

**Line 6 (unconditional export):**
```nim
export atlasVert, atlasMain, maskMain
```

These three exports are defined in `blends.nim` using the shady DSL and must be guarded as a unit — they depend on `opengl` types in their signatures.

**Emscripten-only guard (lines 202–260):** Shader compilation switches GLSL version (`"410"` vs `"300 es"`) and precision header. This is the only conditional in the entire import graph.

## The grow() Procedure: GPU FBO Blit

`grow()` (lines 384–496) doubles the atlas texture size. It is a **pure GPU FBO blit** — no CPU image data is involved. Required steps in order:

1. Flush pending vertex data
2. Create larger atlas texture
3. Create temporary FBO, attach new texture
4. Save current GPU state (framebuffer, viewport, projection, shader)
5. Bind new FBO as render target
6. Set viewport to new dimensions
7. Clear with transparent black
8. Set orthographic projection for new size
9. Bind atlas shader, disable blending
10. Draw old atlas into new atlas (via `glDrawElements`)
11. Flush draw call
12. Restore saved GPU state
13. Delete temporary FBO
14. Delete old texture

This is the most complex backend operation — it requires full FBO support.

## Backend Interface Operations Required

A platform-agnostic backend must expose these abstractions:

### Shaders
- `compileShader(vertSrc, fragSrc) -> ShaderId`
- `useShader(id)` / `deleteShader(id)`
- `setUniform(id, name, value)` — mat4, vec2/3/4, float, int, sampler
- `bindAttrib(id, name, buffer, componentCount, type, normalized)`

### Textures
- `createTexture(w, h, format, internalFormat) -> TextureId`
- `bindTexture(unit, id)` / `deleteTexture(id)`
- `setTextureFilter(id, min, mag, useMipmap)` / `setTextureWrap(id, s, t, r)`
- `uploadTextureData(id, data, format, type, genMipmap)`
- `updateTextureSubregion(id, x, y, w, h, data, format, type, mipmapLevel)`
- `clearTextureSubregion(id, x, y, w, h, level)`
- `downloadTextureData(id) -> ByteArray` (GPU→CPU; disabled on limited platforms)

### Buffers
- `createBuffer(target, componentType, kind) -> BufferId`
- `uploadBufferData(id, data, byteLen)` / `bindBuffer(target, id)` / `deleteBuffer(id)`

### Framebuffers & Rendering
- `createFramebuffer() -> FramebufferId`
- `attachTexture(fbId, attachmentIdx, texId)` / `bindFramebuffer(id)` (0 = screen)
- `checkFramebufferComplete(id) -> bool` / `deleteFramebuffer(id)`
- `setViewport(x, y, w, h)` / `clearColor(r, g, b, a)`
- `setBlendMode(src, dst)` / `enableBlending(bool)`

### Vertex Arrays & Drawing
- `createVertexArray() -> VertexArrayId`
- `bindVertexArray(id)` / `deleteVertexArray(id)`
- `drawElements(primitive, indexCount, indexType, offset)`

## State Invariants

- **Blend mode:** Always `GL_ONE, GL_ONE_MINUS_SRC_ALPHA` (premultiplied alpha)
- **Texture units:** Slot 0 = atlas, Slot 1 = optional blend destination
- **Projection:** Passed to each shader via `setUniform("proj", ...)`
- **Framebuffer:** Screen or one layer texture at a time

## Not Needed in Backend

These are handled by Boxy above the backend level:
- Transform matrix stack (`mats`)
- Quad batching (`quadCount`, `quadsPerBatch`)
- Tile allocation (`takenTiles` BitArray)
- Layer management (`layerNum`, `layerTextures`)
