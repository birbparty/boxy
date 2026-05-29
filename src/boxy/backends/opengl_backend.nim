## OpenGL backend for boxy — implements the Backend interface.
##
## Owns all GL resources for the OpenGL rendering path: texture allocation,
## framebuffer management, layer compositing shaders and VAO.
##
## Handle encoding:
##   TextureHandle.id     == GLuint texture object (cast via int)
##   RenderTargetHandle.id == GLuint FBO object    (0 == default framebuffer)

import opengl, pixie, vmath, chroma, shady
import ../[blends, buffers, shaders]
import backend_interface

export backend_interface

# ---------------------------------------------------------------------------
# OpenGLBackend type
# ---------------------------------------------------------------------------

type
  OpenGLBackend* = ref object of Backend
    ## Shaders used only for layer compositing (not for the main boxy quad batch).
    atlasShader*: Shader
    maskShader*: Shader
    blendShader*: Shader
    ## Compositing VAO — a single quad, positions and colors updated per call.
    vao: GLuint
    posBuffer: Buffer
    posData: seq[float32]      ## 4 × (x, y) — refreshed with frameSize per call
    uvBuffer: Buffer           ## Constant: full-frame Y-flipped UVs
    uvData: seq[float32]
    colorBuffer: Buffer
    colorData: seq[uint8]      ## 4 × (r, g, b, a) — refreshed with tint per call
    indexBuffer: Buffer        ## Constant: 6 indices for two triangles
    ## Temporary texture/FBO owned by the backend for shader-blend compositing.
    tmpGLTex: GLuint
    tmpGLFbo: GLuint
    tmpTexW, tmpTexH: int32

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newOpenGLBackend*(emscripten = false): OpenGLBackend =
  result = OpenGLBackend()

  let version = if emscripten: "300 es" else: "410"
  let prefix  = if emscripten: "precision highp float;\n" else: ""

  result.atlasShader = newShader(
    ("atlasVert",    toGLSL(atlasVert,    version, prefix)),
    ("atlasMain",    toGLSL(atlasMain,    version, prefix))
  )
  result.maskShader = newShader(
    ("atlasVert",    toGLSL(atlasVert,    version, prefix)),
    ("maskMain",     toGLSL(maskMain,     version, prefix))
  )
  result.blendShader = newShader(
    ("atlasVert",    toGLSL(atlasVert,    version, prefix)),
    ("blendingMain", toGLSL(blendingMain, version, prefix))
  )

  # --- compositing VAO ---
  glGenVertexArrays(1, result.vao.addr)
  glBindVertexArray(result.vao)

  # Positions: 4 vertices × 2 floats, filled per compositeLayer call.
  result.posBuffer          = Buffer()
  result.posBuffer.target   = GL_ARRAY_BUFFER
  result.posBuffer.componentType = cGL_FLOAT
  result.posBuffer.kind     = bkVEC2
  result.posBuffer.count    = 4
  result.posData            = newSeq[float32](8)

  # UVs: constant full-frame Y-flipped (GL tex y=0 at bottom).
  # Matches boxy.nim drawUvRect with uvAt=(0,1) uvTo=(1,0):
  #   v0=(0,0), v1=(1,0), v2=(1,1), v3=(0,1)
  result.uvBuffer          = Buffer()
  result.uvBuffer.target   = GL_ARRAY_BUFFER
  result.uvBuffer.componentType = cGL_FLOAT
  result.uvBuffer.kind     = bkVEC2
  result.uvBuffer.count    = 4
  result.uvData = @[0'f32, 0'f32, 1'f32, 0'f32, 1'f32, 1'f32, 0'f32, 1'f32]
  bindBufferData(result.uvBuffer, result.uvData[0].addr)

  # Colors: 4 vertices × 4 bytes (RGBA uint8 normalised), filled per call.
  result.colorBuffer          = Buffer()
  result.colorBuffer.target   = GL_ARRAY_BUFFER
  result.colorBuffer.componentType = GL_UNSIGNED_BYTE
  result.colorBuffer.kind     = bkVEC4
  result.colorBuffer.normalized = true
  result.colorBuffer.count    = 4
  result.colorData            = newSeq[uint8](16)

  # Indices: [3,0,1,2,3,1] — same winding as boxy.nim's quad batch.
  result.indexBuffer          = Buffer()
  result.indexBuffer.target   = GL_ELEMENT_ARRAY_BUFFER
  result.indexBuffer.componentType = GL_UNSIGNED_SHORT
  result.indexBuffer.kind     = bkSCALAR
  result.indexBuffer.count    = 6
  let idxData = [3'u16, 0, 1, 2, 3, 1]
  bindBufferData(result.indexBuffer, idxData[0].addr)

  glBindVertexArray(0)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc toGLuint(id: int): GLuint {.inline.} = id.GLuint

proc drawCompositingQuad(b: OpenGLBackend, shader: Shader) =
  ## Upload per-call vertex data and draw the compositing quad.
  ## `shader` must be the currently active program so attribute locations match.
  bindBufferData(b.posBuffer,   b.posData[0].addr)
  bindBufferData(b.colorBuffer, b.colorData[0].addr)
  glBindVertexArray(b.vao)
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, b.indexBuffer.bufferId)
  shader.bindAttrib("vertexPos",   b.posBuffer)
  shader.bindAttrib("vertexUv",    b.uvBuffer)
  shader.bindAttrib("vertexColor", b.colorBuffer)
  glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, nil)

proc setCompositingPos(b: OpenGLBackend, frameSize: IVec2) =
  ## Fill posData for a full-frame quad (same vertex order as drawUvRect).
  ## v0=(0,H), v1=(W,H), v2=(W,0), v3=(0,0)
  let w = frameSize.x.float32
  let h = frameSize.y.float32
  b.posData[0] = 0; b.posData[1] = h
  b.posData[2] = w; b.posData[3] = h
  b.posData[4] = w; b.posData[5] = 0
  b.posData[6] = 0; b.posData[7] = 0

proc setCompositingColor(b: OpenGLBackend, tint: Color) =
  ## Fill colorData with `tint` using chroma asRgbx() to match the original
  ## drawQuad path — alpha-premultiplied and rounded, not truncated.
  let rgbx = tint.asRgbx()
  for i in 0 ..< 4:
    b.colorData[i*4+0] = rgbx.r
    b.colorData[i*4+1] = rgbx.g
    b.colorData[i*4+2] = rgbx.b
    b.colorData[i*4+3] = rgbx.a

proc ensureTmp(b: OpenGLBackend, w, h: int32) =
  ## Ensure the tmp texture/FBO is present and sized to (w, h).
  if b.tmpGLTex == 0:
    glGenTextures(1, b.tmpGLTex.addr)
  if b.tmpGLFbo == 0:
    glGenFramebuffers(1, b.tmpGLFbo.addr)
  if b.tmpTexW == w and b.tmpTexH == h:
    return
  b.tmpTexW = w; b.tmpTexH = h
  glBindTexture(GL_TEXTURE_2D, b.tmpGLTex)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, w, h, 0,
               GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
  glBindFramebuffer(GL_FRAMEBUFFER, b.tmpGLFbo)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                         GL_TEXTURE_2D, b.tmpGLTex, 0)

# ---------------------------------------------------------------------------
# Backend interface implementation
# ---------------------------------------------------------------------------

method createAtlasTexture*(backend: OpenGLBackend, size: int): TextureHandle =
  var texId: GLuint
  glGenTextures(1, texId.addr)
  glBindTexture(GL_TEXTURE_2D, texId)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
               size.GLint, size.GLint, 0,
               GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
  result = TextureHandle(id: texId.int, width: size.int32, height: size.int32,
                         hasMipmap: false, magFilter: filterLinear,
                         minFilter: filterLinear)

method deleteTexture*(backend: OpenGLBackend, handle: TextureHandle) =
  var id = handle.id.GLuint
  glDeleteTextures(1, id.addr)

method createLayerTarget*(
    backend: OpenGLBackend,
    width, height: int32
): tuple[tex: TextureHandle, rt: RenderTargetHandle] =
  # Texture
  var texId: GLuint
  glGenTextures(1, texId.addr)
  glBindTexture(GL_TEXTURE_2D, texId)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
               width, height, 0,
               GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
  let tex = TextureHandle(id: texId.int, width: width, height: height,
                          hasMipmap: false, magFilter: filterLinear,
                          minFilter: filterLinear)
  # Framebuffer attached to the texture
  var fboId: GLuint
  glGenFramebuffers(1, fboId.addr)
  glBindFramebuffer(GL_FRAMEBUFFER, fboId)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                         GL_TEXTURE_2D, texId, 0)
  result = (tex, RenderTargetHandle(id: fboId.int))

method bindTarget*(backend: OpenGLBackend, dst: RenderTargetHandle) =
  glBindFramebuffer(GL_FRAMEBUFFER, dst.id.toGLuint)

method uploadTile*(backend: OpenGLBackend, handle: TextureHandle,
    x, y: int, image: Image, level: int) =
  glBindTexture(GL_TEXTURE_2D, handle.id.toGLuint)
  glTexSubImage2D(
    GL_TEXTURE_2D, level.GLint,
    x.GLint, y.GLint,
    image.width.GLint, image.height.GLint,
    GL_RGBA, GL_UNSIGNED_BYTE,
    image.data[0].addr
  )

method flush*(backend: OpenGLBackend) =
  ## GL draws synchronously; no explicit flush needed.
  discard

method beginAtlasTarget*(backend: OpenGLBackend, atlas: TextureHandle) =
  ## No-op on OpenGL — FBOs are attached on demand in blitAtlasToNewAtlas/grow.
  discard

method endAtlasTarget*(backend: OpenGLBackend, atlas: TextureHandle) =
  ## No-op on OpenGL.
  discard

method blitAtlasToNewAtlas*(backend: OpenGLBackend,
    old, `new`: TextureHandle) =
  ## Copy `old` into the bottom-left (0,0)-(old.width,old.height) region of
  ## `new` using GL_READ_FRAMEBUFFER → GL_DRAW_FRAMEBUFFER blit.
  ## Tile pixel addresses are identical in old and new; only tileRun changes.
  var readFbo, drawFbo: GLuint
  glGenFramebuffers(1, readFbo.addr)
  glGenFramebuffers(1, drawFbo.addr)

  glBindFramebuffer(GL_READ_FRAMEBUFFER, readFbo)
  glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                         GL_TEXTURE_2D, old.id.toGLuint, 0)

  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, drawFbo)
  glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                         GL_TEXTURE_2D, `new`.id.toGLuint, 0)

  # Clear the full new atlas so the three uncopied quadrants are transparent
  # black, not undefined GPU memory (matches original grow() glClear).
  glClearColor(0, 0, 0, 0)
  glClear(GL_COLOR_BUFFER_BIT)

  let s = old.width.GLint
  glBlitFramebuffer(0, 0, s, s, 0, 0, s, s, GL_COLOR_BUFFER_BIT, GL_NEAREST.GLenum)

  glDeleteFramebuffers(1, readFbo.addr)
  glDeleteFramebuffers(1, drawFbo.addr)

method compositeLayer*(backend: OpenGLBackend,
    src: TextureHandle,
    dst: RenderTargetHandle,
    dstTexture: TextureHandle,
    blendMode: BlendMode, tint: Color,
    frameSize: IVec2, atlasSize: int) =
  ## Composite `src` layer onto `dst` using the appropriate blend mode.
  ##
  ## GL-blend path (Normal/Mask/Screen): bind dst FBO, set blend func, draw.
  ## Shader-blend path: blend src + dstTexture → backend tmp, blit tmp → dst.
  let proj = ortho(0'f32, frameSize.x.float32, frameSize.y.float32, 0, -1000, 1000)
  backend.setCompositingPos(frameSize)
  backend.setCompositingColor(tint)

  if blendMode in {NormalBlend, MaskBlend, ScreenBlend}:
    glBindFramebuffer(GL_FRAMEBUFFER, dst.id.toGLuint)

    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, src.id.toGLuint)
    case blendMode
    of NormalBlend:
      glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
      glUseProgram(backend.atlasShader.programId)
      backend.atlasShader.setUniform("proj", proj)
      backend.atlasShader.setUniform("atlasTex", 0)
      backend.atlasShader.bindUniforms()
      backend.drawCompositingQuad(backend.atlasShader)
    of MaskBlend:
      glBlendFunc(GL_ZERO, GL_SRC_COLOR)
      glUseProgram(backend.maskShader.programId)
      backend.maskShader.setUniform("proj", proj)
      backend.maskShader.setUniform("atlasTex", 0)
      backend.maskShader.bindUniforms()
      backend.drawCompositingQuad(backend.maskShader)
    else: # ScreenBlend
      glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_COLOR)
      glUseProgram(backend.atlasShader.programId)
      backend.atlasShader.setUniform("proj", proj)
      backend.atlasShader.setUniform("atlasTex", 0)
      backend.atlasShader.bindUniforms()
      backend.drawCompositingQuad(backend.atlasShader)
  else:
    # Shader-blend path: blend src + dstTexture → tmp, then blit tmp → dst.
    backend.ensureTmp(frameSize.x, frameSize.y)

    glBindFramebuffer(GL_FRAMEBUFFER, backend.tmpGLFbo)
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA) # explicit — not ambient state
    glClearColor(0, 0, 0, 0)
    glClear(GL_COLOR_BUFFER_BIT)

    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, src.id.toGLuint)
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_2D, dstTexture.id.toGLuint)

    glUseProgram(backend.blendShader.programId)
    backend.blendShader.setUniform("proj", proj)
    backend.blendShader.setUniform("srcTexture", 0)
    backend.blendShader.setUniform("dstTexture", 1)
    backend.blendShader.setUniform("blendMode", blendMode.ord.int32)
    backend.blendShader.bindUniforms()

    backend.drawCompositingQuad(backend.blendShader)

    # Blit result from tmp → dst so dst holds the composited content.
    glBindFramebuffer(GL_READ_FRAMEBUFFER, backend.tmpGLFbo)
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dst.id.toGLuint)
    let w = frameSize.x.GLint
    let h = frameSize.y.GLint
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST.GLenum)

    glActiveTexture(GL_TEXTURE0)

  # Unified post-composite reset — mirrors boxy.nim's popLayer tail.
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)

method restoreState*(backend: OpenGLBackend, s: BackendStateSnapshot) =
  ## Re-bind VAO, IBO, and FBO from `s`.
  ## The caller (boxy) re-establishes its own shader + attribute binds after.
  glBindVertexArray(s.vertexArrayId.toGLuint)
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, s.indexBufferId.toGLuint)
  glBindFramebuffer(GL_FRAMEBUFFER, s.framebufferId.toGLuint)
  glEnable(GL_BLEND)
  glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
