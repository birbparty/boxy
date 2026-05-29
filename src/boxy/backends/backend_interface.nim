## Platform-agnostic rendering backend interface for boxy.
##
## Defines the GL-free type vocabulary (Filter, Wrap, TextureHandle,
## RenderTargetHandle) and the abstract Backend base type that
## opengl_backend.nim and citro3d_backend.nim implement.
##
## Zero opengl imports — compiles on any platform without GL headers.

import pixie, vmath

# ---------------------------------------------------------------------------
# GL-free replacements for the GL-coupled types in textures.nim
#
# Ordinal values are sequential (no GL constant inlining).
# Each backend maps these to its own platform constants at bind time.
# ---------------------------------------------------------------------------

type
  Filter* = enum
    filterDefault,
    filterNearest,
    filterLinear

  Wrap* = enum
    wDefault,
    wRepeat,
    wClampToEdge,
    wMirroredRepeat

  ## Opaque handle to a GPU-side texture.
  ## id == 0 means not yet allocated.
  ## On GL: id is a GLuint cast to int.
  ## On citro3d: id is an index into the backend's C3D_Tex array.
  TextureHandle* = object
    id*: int
    width*, height*: int32
    hasMipmap*: bool
    magFilter*: Filter
    minFilter*: Filter
    mipFilter*: Filter
    wrapS*, wrapT*: Wrap

  ## Opaque framebuffer / render-target handle.
  ## id == 0 means the default framebuffer (screen).
  ## On GL: id is a GLuint FBO.
  ## On citro3d: id is an index into the backend's C3D_RenderTarget array.
  RenderTargetHandle* = object
    id*: int

  ## Snapshot of backend state for enterRawOpenGLMode / exitRawOpenGLMode.
  ## Value type — the backend holds no Boxy reference (ARC cycle safety).
  BackendStateSnapshot* = object
    vertexArrayId*: int
    indexBufferId*: int
    posAttribId*: int
    colorAttribId*: int
    uvAttribId*: int
    framebufferId*: int  ## 0 = default framebuffer (screen)

  ## Abstract backend. Implement per platform (ref object of RootObj for
  ## dynamic dispatch). ARC safety contract: the backend holds NO reference
  ## back to Boxy — all state is passed as parameters on each call.
  Backend* = ref object of RootObj

# ---------------------------------------------------------------------------
# Abstract interface — methods dispatch to the concrete GL/citro3d impl
# ---------------------------------------------------------------------------

method createAtlasTexture*(backend: Backend, size: int32): TextureHandle {.base.} =
  ## Allocate a square GPU texture of side `size` pixels for the boxy atlas.
  ## Returns the handle Boxy stores in boxy.atlasTexture.
  raise newException(CatchableError, "createAtlasTexture not implemented")

method deleteTexture*(backend: Backend, handle: TextureHandle) {.base.} =
  ## Release the GPU resource associated with `handle`.
  raise newException(CatchableError, "deleteTexture not implemented")

method uploadTile*(backend: Backend, handle: TextureHandle,
    x, y: int, image: Image, level: int) {.base.} =
  ## Upload `image` to the sub-region at (x, y) / mip `level` of `handle`.
  ## Replaces textures.updateSubImage for the abstract pipeline.
  raise newException(CatchableError, "uploadTile not implemented")

method flush*(backend: Backend) {.base.} =
  ## Submit any buffered draw calls to the GPU.
  ## Called by Boxy before framebuffer switches that require a clean state.
  raise newException(CatchableError, "flush not implemented")

method beginAtlasTarget*(backend: Backend, atlas: TextureHandle) {.base.} =
  ## Begin rendering into `atlas` as a GPU render target.
  ## On citro3d: triggers a GPU flush + cache invalidation.
  ## On GL: no-op (FBOs are attached on demand in grow()).
  raise newException(CatchableError, "beginAtlasTarget not implemented")

method endAtlasTarget*(backend: Backend, atlas: TextureHandle) {.base.} =
  ## End rendering into `atlas` as a GPU render target.
  ## On citro3d: triggers a GPU flush + cache sync.
  ## On GL: no-op.
  raise newException(CatchableError, "endAtlasTarget not implemented")

method blitAtlasToNewAtlas*(backend: Backend,
    old, `new`: TextureHandle, newSize: int32) {.base.} =
  ## Copy all content from `old` into `new` (twice the side length).
  ## Called by grow(). Boxy saves/restores proj, activeShader, and the
  ## current RenderTargetHandle around this call — the backend is stateless
  ## w.r.t. those fields.
  raise newException(CatchableError, "blitAtlasToNewAtlas not implemented")

method compositeLayer*(backend: Backend,
    src: TextureHandle, dst: RenderTargetHandle,
    blendMode: BlendMode, tint: Color,
    frameSize: IVec2, atlasSize: int32) {.base.} =
  ## Composite `src` (layer texture) onto `dst` (next layer down or screen).
  ## Called by popLayer(). Boxy passes dst explicitly after dec(layerNum) so
  ## the backend has no layerNum dependency.
  raise newException(CatchableError, "compositeLayer not implemented")

method restoreState*(backend: Backend, s: BackendStateSnapshot) {.base.} =
  ## Re-bind all backend state captured in `s`.
  ## Called by exitRawOpenGLMode(). Boxy populates the snapshot before
  ## enterRawOpenGLMode and passes it back here.
  raise newException(CatchableError, "restoreState not implemented")
