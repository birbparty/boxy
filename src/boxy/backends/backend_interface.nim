## Platform-agnostic rendering backend interface for boxy.
##
## Defines the GL-free type vocabulary (Filter, Wrap, TextureHandle,
## RenderTargetHandle) and the abstract Backend base type that
## opengl_backend.nim and citro3d_backend.nim implement.
##
## Zero opengl imports — compiles on any platform without GL headers.
##
## Dispatch model: runtime vtable via `ref object of RootObj` methods.
## Platform is selected at compile time (`--define:ds3`) so only one backend
## is ever linked, but runtime dispatch avoids scattering `when defined(ds3)`
## through boxy.nim and keeps the call sites uniform. On 3DS the vtable is a
## single-entry table (one concrete type), so the overhead is one pointer
## dereference — acceptable for a resource-constrained target given the
## reduction in `when` branches across the codebase.

import pixie, vmath

# ---------------------------------------------------------------------------
# Error type
# ---------------------------------------------------------------------------

type
  BackendError* = object of CatchableError
    ## Raised when a Backend method is called on the abstract base or on a
    ## backend that does not support the operation.

# ---------------------------------------------------------------------------
# GL-free replacements for the GL-coupled types in textures.nim
#
# Ordinal values are sequential (no GL constant inlining).
# Each backend maps these to its own platform constants at bind time.
#
# textures.nim imports and re-exports these enums so callers that import
# textures get Filter/Wrap from this module transitively. They are now a
# single shared type — boxy-lct (iteration 6) completed the migration.
# ---------------------------------------------------------------------------

type
  Filter* = enum
    ## Texture filtering mode. Map to platform constants in each backend.
    filterDefault,
    filterNearest,
    filterLinear

  Wrap* = enum
    ## Texture wrap mode. Map to platform constants in each backend.
    wDefault,
    wRepeat,
    wClampToEdge,
    wMirroredRepeat

  ## Opaque handle to a GPU-side texture.
  ## `id == 0` means not yet allocated — use `isAllocated()` to test.
  ## On GL: id is a GLuint cast to int.
  ## On citro3d: id is an index into the backend's C3D_Tex array.
  ## The backend owns the GPU resource lifetime; Boxy holds only this handle.
  TextureHandle* = object
    id*: int          ## Backend-assigned handle; 0 = not yet allocated
    width*, height*: int32
    hasMipmap*: bool
    magFilter*: Filter
    minFilter*: Filter
    mipFilter*: Filter
    wrapS*, wrapT*: Wrap

  ## Opaque framebuffer / render-target handle.
  ## `id == 0` means the default framebuffer (screen).
  ## On GL: id is a GLuint FBO.
  ## On citro3d: id is an index into the backend's C3D_RenderTarget array.
  RenderTargetHandle* = object
    id*: int          ## Backend-assigned handle; 0 = default framebuffer (screen)

  ## Snapshot of the minimal VAO/IBO/framebuffer bindings Boxy saves before
  ## enterRawOpenGLMode and restores via restoreState after exitRawOpenGLMode.
  ##
  ## Vertex attribute binds (posAttrib, colorAttrib, uvAttrib) are NOT in the
  ## snapshot because they are re-established by the backend from its own
  ## owned shader and buffers — Boxy does not hold those references.
  BackendStateSnapshot* = object
    vertexArrayId*: int   ## VAO id (GLuint on GL)
    indexBufferId*: int   ## IBO id (GLuint on GL)
    framebufferId*: int   ## FBO id; 0 = default framebuffer (screen)

  ## Abstract backend. Implement per platform.
  ## ARC safety contract: the backend holds NO reference back to Boxy.
  ## All state Boxy knows (handles, blend mode, tint, frame size) is passed
  ## as parameters on each call. The backend owns GPU resource lifetime.
  Backend* = ref object of RootObj

# ---------------------------------------------------------------------------
# Convenience constructors / predicates
# ---------------------------------------------------------------------------

func noTextureHandle*(): TextureHandle {.inline.} =
  ## Returns the sentinel for "not yet allocated" (id == 0).
  TextureHandle(id: 0)

func defaultRenderTarget*(): RenderTargetHandle {.inline.} =
  ## Returns the sentinel for the default framebuffer / screen (id == 0).
  RenderTargetHandle(id: 0)

func isAllocated*(h: TextureHandle): bool {.inline.} =
  ## True when the handle refers to a live GPU texture.
  h.id != 0

func isScreen*(h: RenderTargetHandle): bool {.inline.} =
  ## True when the handle refers to the default framebuffer (screen).
  h.id == 0

# ---------------------------------------------------------------------------
# Abstract interface — methods dispatch to the concrete GL / citro3d impl
# ---------------------------------------------------------------------------

method createAtlasTexture*(backend: Backend, size: int): TextureHandle {.base.} =
  ## Allocate a square GPU texture of side `size` pixels for the boxy atlas.
  ## The returned handle has `width` and `height` set to `size`.
  raise newException(BackendError, "createAtlasTexture not implemented")

method deleteTexture*(backend: Backend, handle: TextureHandle) {.base.} =
  ## Release the GPU resource associated with `handle`.
  raise newException(BackendError, "deleteTexture not implemented")

method createLayerTarget*(backend: Backend,
    width, height: int32): tuple[tex: TextureHandle, rt: RenderTargetHandle] {.base.} =
  ## Allocate a layer texture + framebuffer pair for pushLayer / popLayer.
  ## On GL: glGenTextures + bindTextureData(nil) + glGenFramebuffers + attach.
  ## On citro3d: C3D_TexInitRenderTarget + C3D_RenderTargetCreate.
  raise newException(BackendError, "createLayerTarget not implemented")

method bindTarget*(backend: Backend, dst: RenderTargetHandle) {.base.} =
  ## Bind `dst` as the active render target.
  ## On GL: glBindFramebuffer(GL_FRAMEBUFFER, dst.id).
  ## On citro3d: C3D_FrameDrawOn(target).
  ## Boxy calls this in pushLayer and at the start of popLayer.
  raise newException(BackendError, "bindTarget not implemented")

method uploadTile*(backend: Backend, handle: TextureHandle,
    x, y: int, image: Image, level: int) {.base.} =
  ## Upload `image` to the sub-region at (x, y) / mip `level` of `handle`.
  ## Single-level upload — replaces textures.updateSubImage(x, y, image, level).
  ## The mip-walking loop (all levels) remains in Boxy.
  raise newException(BackendError, "uploadTile not implemented")

method flush*(backend: Backend) {.base.} =
  ## Submit any buffered draw calls to the GPU.
  ## Called by Boxy before framebuffer switches that require a clean state.
  raise newException(BackendError, "flush not implemented")

method beginAtlasTarget*(backend: Backend, atlas: TextureHandle) {.base.} =
  ## Begin rendering into `atlas` as a GPU render target.
  ## On citro3d: triggers a GPU flush + cache invalidation.
  ## On GL: no-op (FBOs are attached on demand in grow()).
  raise newException(BackendError, "beginAtlasTarget not implemented")

method endAtlasTarget*(backend: Backend, atlas: TextureHandle) {.base.} =
  ## End rendering into `atlas` as a GPU render target.
  ## On citro3d: triggers a GPU flush + cache sync.
  ## On GL: no-op.
  raise newException(BackendError, "endAtlasTarget not implemented")

method blitAtlasToNewAtlas*(backend: Backend,
    old, `new`: TextureHandle) {.base.} =
  ## Copy all content from `old` into `new` (twice the side length).
  ## `new.width` == `new.height` == the new atlas size.
  ## Called by grow(). Boxy saves/restores proj, activeShader, and the
  ## current RenderTargetHandle around this call — the backend is stateless
  ## w.r.t. those fields.
  raise newException(BackendError, "blitAtlasToNewAtlas not implemented")

method compositeLayer*(backend: Backend,
    src: TextureHandle,
    dst: RenderTargetHandle,
    dstTexture: TextureHandle,
    blendMode: BlendMode, tint: Color,
    frameSize: IVec2, atlasSize: int) {.base.} =
  ## Composite `src` (popped layer texture) onto `dst` (next layer or screen).
  ## Called by popLayer(). Boxy passes dst and dstTexture explicitly so the
  ## backend has no layerNum dependency.
  ##
  ## `dstTexture` is the backing texture of `dst`:
  ##   - GL-blend path (NormalBlend/MaskBlend/ScreenBlend): `dstTexture` may
  ##     be a zero handle (`defaultRenderTarget()`); the backend draws into
  ##     `dst` using standard GL blending.
  ##   - Shader-blend path (all other BlendMode values): both `src` and
  ##     `dstTexture` are bound as samplers for `blendShader`. The backend
  ##     owns the temp-texture/swap semantics for this path.
  raise newException(BackendError, "compositeLayer not implemented")

method restoreState*(backend: Backend, s: BackendStateSnapshot) {.base.} =
  ## Re-bind VAO, IBO, and framebuffer from `s`.
  ## Called by exitRawOpenGLMode(). The backend also re-establishes its own
  ## vertex attribute binds (shader + position/color/uv buffers) from its
  ## own owned state — those are not in the snapshot.
  raise newException(BackendError, "restoreState not implemented")
