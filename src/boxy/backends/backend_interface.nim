# backend_interface.nim — Platform-agnostic rendering backend design
#
# STATUS: Design stub. No implementation. See boxy-0hw for implementation task.
#
# This file defines the type plan and interface contract for a backend that can
# be implemented by OpenGL (desktop/emscripten), PICA200/citro3d (3DS), or GXM
# (PSP/Vita). All types here must compile without importing opengl.

# ---------------------------------------------------------------------------
# SECTION 1: GL-free type definitions
#
# These replace the GL-coupled enums in src/boxy/textures.nim lines 6–23.
# The original types embed GL constants as ordinal values:
#
#   filterNearest = GL_NEAREST   (9728)
#   filterLinear  = GL_LINEAR    (9729)
#   wRepeat       = GL_REPEAT    (10497)
#
# This makes them unusable without importing opengl. The backend is responsible
# for translating the abstract enum to its platform constant at bind time.
# ---------------------------------------------------------------------------

type
  # Replaces textures.nim Filter (lines 6–9).
  # Ordinal values are sequential; each backend maps these to its own constants.
  BackendFilter* = enum
    bfDefault,
    bfNearest,
    bfLinear

  # Replaces textures.nim Wrap (lines 11–14).
  BackendWrap* = enum
    bwDefault,
    bwRepeat,
    bwClampToEdge,
    bwMirroredRepeat

  # Opaque handle to a GPU-side texture. The backend implementation holds the
  # concrete GL/citro3d resource; Boxy holds only this handle.
  #
  # Using int rather than GLuint so this file compiles without opengl.
  # On GL: id = textureId (GLuint cast to int).
  # On citro3d: id = index into backend's C3D_Tex array (VRAM-allocated).
  TextureHandle* = object
    id*: int                  ## Backend-assigned handle (0 = not yet created)
    width*, height*: int32
    hasMipmap*: bool
    magFilter*: BackendFilter
    minFilter*: BackendFilter
    mipFilter*: BackendFilter
    wrapS*, wrapT*: BackendWrap

  # Opaque framebuffer / render-target handle.
  # On GL: id = GLuint FBO (0 = default framebuffer / screen).
  # On citro3d: id = index into backend's C3D_RenderTarget array.
  RenderTargetHandle* = object
    id*: int

# ---------------------------------------------------------------------------
# SECTION 2: Backend object graph — ARC cycle safety
#
# ARC (--gc:arc, required for 3DS) has NO cycle collector. --gc:orc is
# incompatible with this target. Therefore Boxy and its backend must form a
# DAG, not a cycle.
#
# SAFE layout:
#   Boxy (ref) ──owns──► BackendGL (ref)   [GL implementation]
#   Boxy (ref) ──owns──► BackendC3D (ref)  [citro3d implementation]
#
# UNSAFE layout (DO NOT USE):
#   Boxy (ref) ──► Backend (ref) ──► Boxy (ref)   ← cycle, leaks under ARC
#
# The backend holds NO reference back to Boxy. All state that the backend
# needs is passed in as parameters on each call. Boxy passes handles it
# received from prior backend calls; it never passes `self`.
#
# Layer textures and framebuffers are owned by the backend; Boxy holds only
# RenderTargetHandle values (integers). When Boxy calls beginFrame, the backend
# returns a RenderTargetHandle for the screen. When pushLayer is called, Boxy
# calls backend.allocLayerTarget() and stores the returned handle in
# boxy.layerFramebuffers[boxy.layerNum]. dec/inc layerNum remains in Boxy.
# ---------------------------------------------------------------------------

# (Sketch — not a working type; shows ownership without cycles)
#
# type
#   BackendBase* = ref object of RootObj   ## Implement per platform
#
#   Boxy* = ref object
#     backend: BackendBase                 ## owned, no back-ref
#     atlasTexture: TextureHandle          ## id from backend.createAtlasTexture()
#     layerTargets: seq[RenderTargetHandle]
#     ... (all bookkeeping fields remain here)

# ---------------------------------------------------------------------------
# SECTION 3: Higher-level GPU operations
#
# These are the three compound operations that grow() and popLayer() need
# from the backend. They are expressed as single backend calls so that each
# platform can implement them efficiently (e.g. citro3d's C3D_DrawOn instead
# of GL FBO swap).
# ---------------------------------------------------------------------------

# 3a. blitAtlasToNewAtlas — used by grow() (boxy.nim lines 384–496)
#
# Copies all content from `old` into `new`, which has twice the side length.
# On GL: creates a temporary FBO, attaches `new`, issues a full-screen draw
#   with the atlas shader (blending disabled), then deletes the FBO.
# On citro3d: uses C3D_RenderTargetCreate on the new VRAM texture, calls
#   C3D_DrawOn, and issues a GPU copy blit.
#
# CONTRACT: caller (grow) is responsible for:
#   - flushing pending vertices before calling this
#   - saving proj, activeShader, and the current RenderTargetHandle
#   - restoring them after this returns
#   - updating takenTiles and tile index remapping (CPU-only, stays in grow())
#
# WHY THIS BOUNDARY: grow() mixes state save/restore with tile bookkeeping.
# The state save references boxy.layerNum (to find savedFramebuffer) and
# boxy.proj. Passing the saved state as OUT parameters avoids giving the
# backend a reference to Boxy; the actual restoration is done by Boxy.

# proc blitAtlasToNewAtlas*(backend: BackendBase,
#   old, `new`: TextureHandle,
#   newSize: int32): void

# 3b. compositeLayer — used by popLayer() (boxy.nim lines 710–780)
#
# Composites `src` (a layer texture) onto `dst` (the render target one level
# down, or screen if layerNum will become -1) using blendMode and tint.
#
# On GL: sets glBlendFunc per blendMode, binds the appropriate shader, issues
#   a full-screen draw, restores blend to ONE/ONE_MINUS_SRC_ALPHA.
# For complex blendModes (not NormalBlend/MaskBlend/ScreenBlend): reads
#   current dst into tmpTexture, binds both as TEXTURE0/TEXTURE1, uses
#   blendShader with blendMode uniform.
#
# CONTRACT: caller (popLayer) passes:
#   - src = layerTextures[layerNum] (the texture being popped)
#   - dst = layerFramebuffers[layerNum - 1], or screen if layerNum == 0
#   - blendMode, tint
# Boxy decrements layerNum AFTER this call returns.
#
# WHY THIS BOUNDARY: popLayer interleaves dec(boxy.layerNum) with GL calls.
# The dec determines which dst framebuffer to bind. Passing dst explicitly
# lets the backend be stateless w.r.t. layer count.

# proc compositeLayer*(backend: BackendBase,
#   src: TextureHandle, dst: RenderTargetHandle,
#   blendMode: BlendMode, tint: Color,
#   frameSize: IVec2, atlasSize: int32): void

# 3c. beginAtlasTarget / endAtlasTarget — atlas-as-RTT for PICA200 VRAM
#
# On GL: the atlas texture can be attached to an FBO at will. grow() already
#   does this via glGenFramebuffers + drawToTexture.
# On PICA200 (citro3d): textures and render targets share the same VRAM pool
#   (C3D_BufInfo). A texture must be explicitly created as a render-target
#   texture (C3D_TexInitRenderTarget) before it can be written by the GPU.
#   This is a one-time allocation difference, not a per-frame bind.
#
# These two calls bracket the period where the atlas texture is used as a GPU
# render target (currently only inside grow()). On GL they are no-ops.
# On citro3d, beginAtlasTarget triggers a GPU flush + cache invalidation.

# proc beginAtlasTarget*(backend: BackendBase, atlas: TextureHandle): void
# proc endAtlasTarget*(backend: BackendBase, atlas: TextureHandle): void

# ---------------------------------------------------------------------------
# SECTION 4: GL + bookkeeping interleaving analysis
#
# These are the sites in boxy.nim where GPU calls and Boxy bookkeeping are
# so interleaved that simple field-wrapping (putting GL calls in the backend
# while Boxy fields remain in Boxy) does not cleanly separate them. Each
# entry notes WHY field-wrapping fails and what the chosen boundary is.
# ---------------------------------------------------------------------------

# SITE 1: grow() lines 384–496
#
# Structure:
#   [CPU]  check atlasSize == maxAtlasSize → may writeFile (emscripten-guarded)
#   [GPU]  createAtlasTexture(newAtlasSize)
#   [GPU]  glGenFramebuffers → attach to new texture
#   [CPU]  save: savedFramebuffer = boxy.layerFramebuffers[boxy.layerNum]
#          save: savedProj = boxy.proj
#          save: savedShader = boxy.activeShader
#   [GPU]  glBindFramebuffer, glViewport, glClearColor, glClear
#   [CPU]  boxy.proj = ortho(...)
#   [CPU]  boxy.activeShader = boxy.atlasShader
#   [GPU]  glDisable(GL_BLEND)
#   [GPU]  drawUvRect + flush (multiple GPU calls via flush)
#   [CPU]  restore: boxy.proj, boxy.activeShader, boxy.layerFramebuffers
#   [GPU]  glEnable(GL_BLEND), glBindFramebuffer, glViewport
#   [GPU]  glDeleteFramebuffers, glDeleteTextures
#   [CPU]  update boxy.atlasTexture, atlasSize, tileRun, maxTiles
#   [CPU]  rebuild takenTiles BitArray
#   [CPU]  remap every tile index from oldTileRun to newTileRun
#
# WHY FIELD-WRAPPING FAILS: The save block references boxy.layerNum to choose
#   savedFramebuffer — the backend would need to know layerNum. The proj and
#   shader saves write back to Boxy fields that are also used by flush(), which
#   issues real GPU calls. Pulling the GPU part into blitAtlasToNewAtlas and
#   keeping the save/restore in Boxy is the clean split.
#
# CHOSEN BOUNDARY: blitAtlasToNewAtlas (section 3a). Boxy calls it with the
#   two TextureHandles and receives no output. Boxy performs save/restore
#   around the call using its own fields.
#
# NOTE: The max-size error branch calls atlasTexture.writeFile() which is a
#   pixie+file-I/O path guarded `when not defined(emscripten)` but NOT for ds3.
#   Must add `when not defined(ds3)` guard or remove it entirely for the 3DS
#   build (no filesystem before romfs is mounted).

# SITE 2: popLayer() lines 700–780
#
# Structure:
#   [CPU]  check layerNum >= 0
#   [GPU]  flush()
#   [CPU]  let layerTexture = boxy.layerTextures[boxy.layerNum]
#   [CPU]  let savedAtlasTexture = boxy.atlasTexture
#   [CPU]  dec boxy.layerNum
#   [GPU]  … (varies by blendMode — up to 15 interleaved CPU/GPU lines)
#   [CPU]  boxy.atlasTexture = savedAtlasTexture
#   [GPU]  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
#   [CPU]  boxy.activeShader = boxy.atlasShader
#
# WHY FIELD-WRAPPING FAILS: dec(boxy.layerNum) happens BEFORE the GPU calls
#   that decide which FBO to bind. The destination FBO is
#   `boxy.layerFramebuffers[boxy.layerNum]` AFTER dec. Extracting the GL
#   calls as-is would require the backend to know the post-dec layerNum, which
#   means either passing it explicitly or keeping layerNum in the backend (bad).
#
# CHOSEN BOUNDARY: compositeLayer (section 3b). Boxy computes the destination
#   RenderTargetHandle before calling compositeLayer (post-dec logic stays in
#   Boxy), then passes src and dst explicitly. The backend has no layerNum.

# SITE 3: exitRawOpenGLMode() lines 342–358
#
# Structure (all GL):
#   glBindVertexArray(boxy.vertexArrayId)
#   glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, boxy.indices.buffer.bufferId)
#   boxy.activeShader.bindAttrib("vertexPos",   boxy.positions.buffer)
#   boxy.activeShader.bindAttrib("vertexColor", boxy.colors.buffer)
#   boxy.activeShader.bindAttrib("vertexUv",    boxy.uvs.buffer)
#   glBindFramebuffer(GL_FRAMEBUFFER,
#     if boxy.layerNum >= 0: boxy.layerFramebuffers[boxy.layerNum] else: 0)
#   glEnable(GL_BLEND); glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
#
# WHY FIELD-WRAPPING FAILS: This is the full Boxy GL state contract — every
#   GL handle that Boxy manages is re-bound here. Adding a backend layer means
#   this becomes `backend.restoreState(snapshot)` where snapshot captures all
#   the IDs above. The snapshot must be value-typed (no Boxy reference) to
#   maintain ARC safety.
#
# CHOSEN BOUNDARY: `backend.restoreState(s: BackendStateSnapshot)` where
#   BackendStateSnapshot is a plain object:
#     type BackendStateSnapshot* = object
#       vertexArrayId: int
#       indexBufferId:  int
#       posAttribId:    int
#       colorAttribId:  int
#       uvAttribId:     int
#       framebufferId:  int   ## 0 = screen
#   Boxy populates this before calling enterRawOpenGLMode and passes it to
#   exitRawOpenGLMode → restoreState. The public API shape is unchanged.

# ---------------------------------------------------------------------------
# SECTION 5: Unsupported operations on citro3d (must guard at compile time)
#
# These exist in the current OpenGL backend and must be removed or
# conditionally compiled out for ds3 targets.
# ---------------------------------------------------------------------------

# 5a. downloadTextureData / readImage (textures.nim:185–196, boxy.nim:74–76)
#
# GL: glGetTexImage reads back GPU texture data to CPU.
# citro3d: no equivalent. PICA200 does not expose a texture readback path.
#
# Affected callers:
#   readAtlas()        boxy.nim:74–76    → must `when not defined(ds3): ...`
#   getImage()         boxy.nim:1169     → same guard
#   atlasTexture.writeFile() inside grow()'s max-size error branch
#                      boxy.nim:393–394  → same guard
#
# Implementation note: the emscripten branch already raises an exception
# (textures.nim:187–191). The 3DS branch should do the same OR be removed
# entirely at compile time via a `when defined(ds3)` guard.

# 5b. Texture buffer objects (textures.nim:25–37, bindTextureBufferData)
#
# GL: GL_TEXTURE_BUFFER is an OpenGL 3.1+ extension.
# citro3d: not supported. Boxy does not appear to use texture buffers in the
# current codebase (grep shows bindTextureBufferData is defined but never
# called from boxy.nim). Safe to exclude under `when not defined(ds3)`.

# 5c. glGetIntegerv(GL_MAX_TEXTURE_SIZE, ...) in newBoxy() (boxy.nim:325–327)
#
# citro3d: maximum texture side = 1024 on PICA200. Must hardcode or use
# ctrulib's GX_GetMaxTextureSize equivalent instead of querying GL.
