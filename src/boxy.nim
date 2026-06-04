import
  std/[algorithm, sequtils, sets, strutils, tables],
  bitty, vmath, bumpy, chroma, hashes,
  boxy/backends/backend_interface,
  boxy/[blends, blurs, buffers, shaders, spreads, textures]

when not defined(ds3):
  import shady, opengl, pixie
  import boxy/backends/opengl_backend
  export atlasVert, atlasMain, maskMain
  export pixie
else:
  import pixie
  import boxy/backends/citro3d_backend
  export pixie

const
  QuadLimit = 10_921 # 6 indices per quad, ensure indices stay in uint16 range

type
  BoxyError* = object of ValueError

  TileKind = enum
    tkIndex, tkColor

  TileInfo = object
    case kind: TileKind
    of tkIndex:
      index: int
    of tkColor:
      color: Color

  ImageInfo = ref object
    size: IVec2               ## Size of the image in pixels.
    tiles: seq[seq[TileInfo]] ## The tile info for this image.
    oneColor: Color           ## If tiles = [] then this is the image's color.

  Boxy* = ref object
    when not defined(ds3):
      atlasShader, maskShader, blendShader, activeShader: Shader
      blurXShader, blurYShader: Shader
      spreadXShader, spreadYShader: Shader
      atlasTexture*, tmpTexture: Texture
      tmpFramebuffer: GLuint
    else:
      atlasHandle*: TextureHandle  ## ds3: atlas texture handle (citro3d backend)
    layerNum: int                    ## Index into layer textures for writing.
    when not defined(ds3):
      layerTextures: seq[Texture]      ## Layers array for pushing and popping.
      layerFramebuffers: seq[GLuint]   ## Attachment targets for layer textures.
    else:
      # layerRTs: not yet populated — pushLayer/popLayer on ds3 is unimplemented.
      # Declared as a placeholder; layerNum stays -1 on ds3 so endFrame's
      # `layerNum != -1` guard is always satisfied without touching this seq.
      layerRTs: seq[tuple[tex: TextureHandle, rt: RenderTargetHandle]]
    atlasSize: int                   ## Size x size dimensions of the atlas.
    quadCount: int                   ## Number of quads drawn so far in this batch.
    quadsPerBatch: int               ## Max quads in a batch before issuing an OpenGL call.
    mat: Mat3                        ## The current matrix.
    mats: seq[Mat3]                  ## The matrix stack.
    entries: Table[string, ImageInfo]
    entriesBuffered: HashSet[string] ## Entries used but not flushed yet.
    tileSize: int
    maxTiles: int
    tileRun: int
    tileMargin: int
    takenTiles: BitArray             ## Flag for if the tile is taken or not.
    proj: Mat4
    frameSize: IVec2                 ## Dimensions of the window frame.
    when not defined(ds3):
      vertexArrayId: GLuint
    frameBegun: bool
    when not defined(ds3):
      maxAtlasSize: int
    backend*: Backend                ## Rendering backend (OpenGL or citro3d).
    when not defined(ds3):
      # Buffer data for OpenGL
      positions: tuple[buffer: Buffer, data: seq[float32]]
      colors: tuple[buffer: Buffer, data: seq[uint8]]
      uvs: tuple[buffer: Buffer, data: seq[float32]]
      indices: tuple[buffer: Buffer, data: seq[uint16]]

proc vec2(x, y: SomeNumber): Vec2 {.inline.} =
  ## Integer short cut for creating vectors.
  vec2(x.float32, y.float32)

proc `*`(a, b: Color): Color {.inline.} =
  result.r = a.r * b.r
  result.g = a.g * b.g
  result.b = a.b * b.b
  result.a = a.a * b.a

when not defined(ds3):
  proc readAtlas*(boxy: Boxy): Image =
    ## Read the current atlas content.
    boxy.atlasTexture.readImage()

  proc upload(boxy: Boxy) =
    ## When buffers change, uploads them to GPU.
    boxy.positions.buffer.count = boxy.quadCount * 4
    boxy.colors.buffer.count = boxy.quadCount * 4
    boxy.uvs.buffer.count = boxy.quadCount * 4
    boxy.indices.buffer.count = boxy.quadCount * 6
    bindBufferData(boxy.positions.buffer, boxy.positions.data[0].addr)
    bindBufferData(boxy.colors.buffer, boxy.colors.data[0].addr)
    bindBufferData(boxy.uvs.buffer, boxy.uvs.data[0].addr)

proc contains*(boxy: Boxy, key: string): bool {.inline.} =
  key in boxy.entries

when not defined(ds3):
  proc drawVertexArray(boxy: Boxy) =
    glDrawElements(
      GL_TRIANGLES,
      boxy.indices.buffer.count.GLint,
      boxy.indices.buffer.componentType,
      nil
    )
    boxy.quadCount = 0

  proc flush*(boxy: Boxy, useAtlas: bool = true) =
    ## Flips - draws current buffer and starts a new one.
    if boxy.quadCount == 0:
      return

    boxy.entriesBuffered.clear()
    boxy.upload()

    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, boxy.atlasTexture.textureId)

    glUseProgram(boxy.activeShader.programId)
    boxy.activeShader.setUniform("proj", boxy.proj)
    if useAtlas:
      boxy.activeShader.setUniform("atlasTex", 0)
    boxy.activeShader.bindUniforms()

    boxy.drawVertexArray()

  proc checkFramebuffer() =
    let status = glCheckFramebufferStatus(GL_FRAMEBUFFER)
    if status != GL_FRAMEBUFFER_COMPLETE:
      raise newException(
        BoxyError,
        "Something wrong with layer framebuffer: " & $toHex(status.int32, 4)
      )

  proc drawToTexture(boxy: Boxy, texture: Texture, framebufferId: GLuint) =
    glBindFramebuffer(GL_FRAMEBUFFER, framebufferId)
    glFramebufferTexture2D(
      GL_FRAMEBUFFER,
      GL_COLOR_ATTACHMENT0,
      GL_TEXTURE_2D,
      texture.textureId,
      0
    )

  proc createAtlasTexture(boxy: Boxy, size: int): Texture =
    result = Texture()
    result.width = size.int32
    result.height = size.int32
    result.componentType = GL_UNSIGNED_BYTE
    result.format = GL_RGBA
    result.internalFormat = GL_RGBA8
    result.magFilter = filterLinear
    result.minFilter = filterLinear
    result.useMipmap = false
    bindTextureData(result, nil, false)

  proc addLayerTexture(boxy: Boxy) =
    # Must be >0 for framebuffer creation below
    # Set to real value in beginFrame
    let layerTexture = Texture()
    layerTexture.width = boxy.frameSize.x.int32
    layerTexture.height = boxy.frameSize.y.int32
    layerTexture.componentType = GL_UNSIGNED_BYTE
    layerTexture.format = GL_RGBA
    layerTexture.internalFormat = GL_RGBA8
    layerTexture.magFilter = filterLinear
    layerTexture.minFilter = filterLinear
    bindTextureData(layerTexture, nil)
    boxy.layerTextures.add(layerTexture)

    var layerFramebufferId: GLuint
    glGenFramebuffers(1, layerFramebufferId.addr)
    boxy.drawToTexture(layerTexture, layerFramebufferId)
    boxy.layerFramebuffers.add(layerFramebufferId)

else:
  proc flush(boxy: Boxy) =
    ## Submit current quad batch via the citro3d backend.
    ## Precondition: called inside an open C3D frame (c3dFrameBegin..c3dFrameEnd)
    ## with the render target already bound (c3dFrameDrawOn called by the app).
    boxy.entriesBuffered.clear()
    if boxy.quadCount > 0:
      # Set up PICA200 GPU state before submitting: shader, projection, TEV,
      # atlas bind, blend. Uses downcast — safe: ds3 newBoxy always assigns
      # Citro3dBackend, and prepareAtlasDraw is not in the Backend vtable.
      #
      # PRECONDITION (projection contract): the app MUST have bound the physical
      # top screen via c3dFrameDrawOn before this flush.  prepareAtlasDraw always
      # uploads the 90°-tilted top-screen projection; it produces wrong output for
      # the bottom screen or RTT targets.  See prepareAtlasDraw docstring.
      Citro3dBackend(boxy.backend).prepareAtlasDraw(boxy.atlasHandle, boxy.frameSize)
    boxy.backend.flush()
    boxy.quadCount = 0

proc addWhiteTile(boxy: Boxy)
proc clearAtlas*(boxy: Boxy) =
  boxy.entries.clear()
  boxy.takenTiles.clear()
  boxy.addWhiteTile()

when not defined(ds3):
  proc newBoxy*(
    atlasSize = 512,
    tileSize = 32,
    tileMargin = 2,
    quadsPerBatch = 1024
  ): Boxy =
    ## Creates a new Boxy with a specified atlas size and quads per batch.
    if quadsPerBatch > QuadLimit:
      raise newException(BoxyError, "Quads per batch cannot exceed " & $QuadLimit)

    result = Boxy()
    result.atlasSize = atlasSize
    result.quadsPerBatch = quadsPerBatch
    result.mat = mat3()
    result.mats = newSeq[Mat3]()

    result.atlasTexture = result.createAtlasTexture(atlasSize)
    # Tile system initialization
    result.tileMargin = tileMargin
    result.tileSize = tileSize - result.tileMargin
    if result.atlasSize mod (result.tileSize + result.tileMargin) != 0:
      raise newException(BoxyError, "Atlas size must be a multiple of (tile size + 2)")
    result.tileRun = result.atlasSize div (result.tileSize + result.tileMargin)
    result.maxTiles = result.tileRun * result.tileRun
    result.takenTiles = newBitArray(result.maxTiles)

    result.layerNum = -1

    when defined(emscripten):
      result.atlasShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "300 es", "precision highp float;\n")),
        ("atlasMain", toGLSL(atlasMain, "300 es", "precision highp float;\n"))
      )
      result.maskShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "300 es", "precision highp float;\n")),
        ("maskMain", toGLSL(maskMain, "300 es", "precision highp float;\n"))
      )
      result.blendShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "300 es", "precision highp float;\n")),
        ("blendingMain", toGLSL(blendingMain, "300 es", "precision highp float;\n"))
      )
      result.blurXShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "300 es", "precision highp float;\n")),
        ("blendingMain", toGLSL(blurXMain, "300 es", "precision highp float;\n"))
      )
      result.blurYShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "300 es", "precision highp float;\n")),
        ("blendingMain", toGLSL(blurYMain, "300 es", "precision highp float;\n"))
      )
      result.spreadXShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "300 es", "precision highp float;\n")),
        ("spreadXMain", toGLSL(spreadXMain, "300 es", "precision highp float;\n"))
      )
      result.spreadYShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "300 es", "precision highp float;\n")),
        ("spreadYMain", toGLSL(spreadYMain, "300 es", "precision highp float;\n"))
      )

    else:
      result.atlasShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "410", "")),
        ("atlasMain", toGLSL(atlasMain, "410", ""))
      )
      result.maskShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "410", "")),
        ("maskMain", toGLSL(maskMain, "410", ""))
      )
      result.blendShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "410", "")),
        ("blendingMain", toGLSL(blendingMain, "410", ""))
      )
      result.blurXShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "410", "")),
        ("blendingMain", toGLSL(blurXMain, "410", ""))
      )
      result.blurYShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "410", "")),
        ("blendingMain", toGLSL(blurYMain, "410", ""))
      )
      result.spreadXShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "410", "")),
        ("spreadXMain", toGLSL(spreadXMain, "410", ""))
      )
      result.spreadYShader = newShader(
        ("atlasVert", toGLSL(atlasVert, "410", "")),
        ("spreadYMain", toGLSL(spreadYMain, "410", ""))
      )

    result.positions.buffer = Buffer()
    result.positions.buffer.componentType = cGL_FLOAT
    result.positions.buffer.kind = bkVEC2
    result.positions.buffer.target = GL_ARRAY_BUFFER
    result.positions.data = newSeq[float32](
      result.positions.buffer.kind.componentCount() * quadsPerBatch * 4
    )

    result.colors.buffer = Buffer()
    result.colors.buffer.componentType = GL_UNSIGNED_BYTE
    result.colors.buffer.kind = bkVEC4
    result.colors.buffer.target = GL_ARRAY_BUFFER
    result.colors.buffer.normalized = true
    result.colors.data = newSeq[uint8](
      result.colors.buffer.kind.componentCount() * quadsPerBatch * 4
    )

    result.uvs.buffer = Buffer()
    result.uvs.buffer.componentType = cGL_FLOAT
    result.uvs.buffer.kind = bkVEC2
    result.uvs.buffer.target = GL_ARRAY_BUFFER
    result.uvs.data = newSeq[float32](
      result.uvs.buffer.kind.componentCount() * quadsPerBatch * 4
    )

    result.indices.buffer = Buffer()
    result.indices.buffer.componentType = GL_UNSIGNED_SHORT
    result.indices.buffer.kind = bkSCALAR
    result.indices.buffer.target = GL_ELEMENT_ARRAY_BUFFER
    result.indices.buffer.count = quadsPerBatch * 6

    for i in 0 ..< quadsPerBatch:
      let offset = i * 4
      result.indices.data.add([
        (offset + 3).uint16,
        (offset + 0).uint16,
        (offset + 1).uint16,
        (offset + 2).uint16,
        (offset + 3).uint16,
        (offset + 1).uint16,
      ])

    # Indices are only uploaded once
    bindBufferData(result.indices.buffer, result.indices.data[0].addr)

    result.upload()

    result.activeShader = result.atlasShader

    result.backend = newOpenGLBackend(emscripten = defined(emscripten))

    glGenVertexArrays(1, result.vertexArrayId.addr)
    glBindVertexArray(result.vertexArrayId)
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, result.indices.buffer.bufferId)

    result.activeShader.bindAttrib("vertexPos", result.positions.buffer)
    result.activeShader.bindAttrib("vertexColor", result.colors.buffer)
    result.activeShader.bindAttrib("vertexUv", result.uvs.buffer)

    glBindFramebuffer(GL_FRAMEBUFFER, 0)

    # Enable premultiplied alpha blending
    glEnable(GL_BLEND)
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)

    var maxAtlasSize: int32
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, maxAtlasSize.addr)
    result.maxAtlasSize = maxAtlasSize

    if result.maxAtlasSize < result.atlasSize:
      raise newException(
        BoxyError,
        "Requested atlas texture is larger than max supported size: " &
        $result.maxAtlasSize
      )

    result.addWhiteTile()

else:
  proc newBoxy*(
    atlasSize = 512,
    tileSize = 32,
    tileMargin = 2,
    quadsPerBatch = 1024
  ): Boxy =
    ## Creates a new Boxy for Nintendo 3DS (citro3d backend).
    if quadsPerBatch > QuadLimit:
      raise newException(BoxyError, "Quads per batch cannot exceed " & $QuadLimit)
    result = Boxy()
    result.atlasSize = atlasSize
    result.quadsPerBatch = quadsPerBatch
    result.mat = mat3()
    result.mats = newSeq[Mat3]()
    result.tileMargin = tileMargin
    result.tileSize = tileSize - result.tileMargin
    if result.atlasSize mod (result.tileSize + result.tileMargin) != 0:
      raise newException(BoxyError, "Atlas size must be a multiple of (tile size + 2)")
    result.tileRun = result.atlasSize div (result.tileSize + result.tileMargin)
    result.maxTiles = result.tileRun * result.tileRun
    result.takenTiles = newBitArray(result.maxTiles)
    result.layerNum = -1
    result.backend = newCitro3dBackend()
    result.atlasHandle = result.backend.createAtlasTexture(atlasSize)
    result.addWhiteTile()

when defined(ds3):
  proc enterRawOpenGLMode*(boxy: Boxy) =
    ## Not supported on Nintendo 3DS — use citro3d APIs directly.
    ## Note: stderr may be invisible on retail hardware without consoleInit/3dslink.
    stderr.writeLine("boxy: enterRawOpenGLMode is not supported on Nintendo 3DS")

  proc exitRawOpenGLMode*(boxy: Boxy) =
    ## No-op on Nintendo 3DS — there is no raw-GL mode to exit.
    ## Note: stderr may be invisible on retail hardware without consoleInit/3dslink.
    stderr.writeLine("boxy: exitRawOpenGLMode is a no-op on Nintendo 3DS")
else:
  proc enterRawOpenGLMode*(boxy: Boxy) =
    ## Used to run other OpenGL code while using boxy.
    boxy.flush()

  proc exitRawOpenGLMode*(boxy: Boxy) =
    ## Exits raw OpenGL mode, restoring boxy's GL state via the backend.
    ## The snapshot is derived from live Boxy state at restore time (not
    ## captured at enterRawOpenGLMode) — raw GL code must not mutate layerNum.
    let snap = BackendStateSnapshot(
      vertexArrayId: boxy.vertexArrayId.int,
      indexBufferId: boxy.indices.buffer.bufferId.int,
      framebufferId: if boxy.layerNum >= 0: boxy.layerFramebuffers[boxy.layerNum].int else: 0
    )
    boxy.backend.restoreState(snap)
    boxy.activeShader.bindAttrib("vertexPos", boxy.positions.buffer)
    boxy.activeShader.bindAttrib("vertexColor", boxy.colors.buffer)
    boxy.activeShader.bindAttrib("vertexUv", boxy.uvs.buffer)

# Forward declaration
proc drawUvRect(boxy: Boxy, at, to, uvAt, uvTo: Vec2, tint: Color)
proc saveTransform*(boxy: Boxy)
proc restoreTransform*(boxy: Boxy)

proc removeImage*(boxy: Boxy, key: string) =
  ## Removes an image, does nothing if the image has not been added.
  if key in boxy.entriesBuffered:
    raise newException(
      BoxyError,
      "Attempting to remove an image that is set to be drawn"
    )

  if key in boxy.entries:
    for tileLevel in boxy.entries[key].tiles:
      for tile in tileLevel:
        if tile.kind == tkIndex:
          boxy.takenTiles.unsafeSetFalse(tile.index)
    boxy.entries.del(key)

when not defined(ds3):
  proc clearColor(boxy: Boxy) =
    glClearColor(0, 0, 0, 0)
    glClear(GL_COLOR_BUFFER_BIT)

when not defined(ds3):
  proc grow(boxy: Boxy) =
    ## Grows the atlas size by 2 (growing area by 4) and repositions tiles.
    if boxy.atlasSize == boxy.maxAtlasSize:
      var images = boxy.entries.pairs().toSeq()
      images.sort(proc(a, b: (string, ImageInfo)): int = cmp(-a[1].size.x * a[1].size.y, -b[1].size.x * b[1].size.y))
      var i = 0
      for image in images:
        echo "  Image ", image[0], " size: ", image[1].size.x, "x", image[1].size.y
        inc i
      when not defined(emscripten):
        boxy.atlasTexture.writeFile("tmp/atlas.png")
      raise newException(
        BoxyError,
        "Can't grow boxy atlas texture, max supported size reached: " &
        $boxy.maxAtlasSize
      )

    boxy.flush()

    let
      oldAtlasSize = boxy.atlasSize
      newAtlasSize = oldAtlasSize * 2
      oldTileRun = boxy.tileRun
      newTileRun = newAtlasSize div (boxy.tileSize + boxy.tileMargin)

    let newAtlasTexture = boxy.createAtlasTexture(newAtlasSize)

    var newFramebuffer: GLuint
    glGenFramebuffers(1, newFramebuffer.addr)
    boxy.drawToTexture(newAtlasTexture, newFramebuffer)

    let
      savedFramebuffer = if boxy.layerNum >= 0:
        boxy.layerFramebuffers[boxy.layerNum]
      else:
        0.GLuint
      savedProj = boxy.proj
      savedShader = boxy.activeShader

    glBindFramebuffer(GL_FRAMEBUFFER, newFramebuffer)
    glViewport(0, 0, newAtlasSize.int32, newAtlasSize.int32)
    glClearColor(0, 0, 0, 0)
    glClear(GL_COLOR_BUFFER_BIT)
    boxy.proj = ortho(0.float32, newAtlasSize.float32, newAtlasSize.float32, 0, -1000, 1000)
    boxy.activeShader = boxy.atlasShader
    glDisable(GL_BLEND)

    boxy.saveTransform()
    boxy.mat = mat3()

    boxy.drawUvRect(
      at = vec2(0, newAtlasSize),
      to = vec2(oldAtlasSize, oldAtlasSize),
      uvAt = vec2(0, 0),
      uvTo = vec2(oldAtlasSize, oldAtlasSize),
      tint = color(1, 1, 1, 1)
    )

    boxy.flush()
    boxy.restoreTransform()

    glEnable(GL_BLEND)
    glBindFramebuffer(GL_FRAMEBUFFER, savedFramebuffer)
    glViewport(0, 0, boxy.frameSize.x, boxy.frameSize.y)
    boxy.proj = savedProj
    boxy.activeShader = savedShader

    glDeleteFramebuffers(1, newFramebuffer.addr)
    glDeleteTextures(1, boxy.atlasTexture.textureId.addr)

    boxy.atlasTexture = newAtlasTexture
    boxy.atlasSize = newAtlasSize
    boxy.tileRun = newTileRun
    boxy.maxTiles = newTileRun * newTileRun

    var newTakenTiles = newBitArray(boxy.maxTiles)
    newTakenTiles[0] = true # White tile

    for key, imageInfo in boxy.entries.mpairs:
      for level in 0 ..< imageInfo.tiles.len:
        for i in 0 ..< imageInfo.tiles[level].len:
          if imageInfo.tiles[level][i].kind == tkIndex:
            let
              oldIndex = imageInfo.tiles[level][i].index
              x = oldIndex mod oldTileRun
              y = oldIndex div oldTileRun
              newIndex = x + y * newTileRun

            imageInfo.tiles[level][i].index = newIndex
            newTakenTiles[newIndex] = true

    boxy.takenTiles = newTakenTiles

else:
  proc grow(boxy: Boxy) =
    ## Grows the atlas on ds3 using the citro3d backend blit.
    ## Must be called outside an open C3D frame: blitAtlasToNewAtlas opens its
    ## own C3D_FRAME_SYNCDRAW mini-frame, which fails if a frame is already open.
    ## The flush here ensures any pending quad batch is submitted before the old
    ## atlas handle is invalidated — matching the non-ds3 grow path.
    boxy.flush()
    let oldAtlasSize = boxy.atlasSize
    let newAtlasSize = oldAtlasSize * 2
    let oldTileRun = boxy.tileRun
    let newTileRun = newAtlasSize div (boxy.tileSize + boxy.tileMargin)
    let newAtlasHandle = boxy.backend.createAtlasTexture(newAtlasSize)
    boxy.backend.blitAtlasToNewAtlas(boxy.atlasHandle, newAtlasHandle)
    boxy.backend.deleteTexture(boxy.atlasHandle)
    boxy.atlasHandle = newAtlasHandle
    boxy.atlasSize = newAtlasSize
    boxy.tileRun = newTileRun
    boxy.maxTiles = newTileRun * newTileRun
    var newTakenTiles = newBitArray(boxy.maxTiles)
    newTakenTiles[0] = true # White tile
    for key, imageInfo in boxy.entries.mpairs:
      for level in 0 ..< imageInfo.tiles.len:
        for i in 0 ..< imageInfo.tiles[level].len:
          if imageInfo.tiles[level][i].kind == tkIndex:
            let oldIndex = imageInfo.tiles[level][i].index
            let x = oldIndex mod oldTileRun
            let y = oldIndex div oldTileRun
            let newIndex = x + y * newTileRun
            imageInfo.tiles[level][i].index = newIndex
            newTakenTiles[newIndex] = true
    boxy.takenTiles = newTakenTiles

proc takeFreeTile(boxy: Boxy): int =
  let (found, index) = boxy.takenTiles.firstFalse
  if found:
    boxy.takenTiles.unsafeSetTrue(index)
    return index
  boxy.grow()
  boxy.takeFreeTile()

proc addImage*(boxy: Boxy, key: string, image: Image, mipmaps: bool = true) =
  when defined(ds3):
    if boxy.frameBegun:
      raise newException(BoxyError,
        "addImage must be called outside a beginFrame/endFrame pair on ds3: " &
        "atlas grow triggers c3dFrameBegin which cannot nest inside an open frame")
  if key in boxy.entriesBuffered:
    raise newException(
      BoxyError,
      "Attempting to modify an image that is already set to be drawn " &
      "(try using a unique key?)"
    )

  boxy.removeImage(key)
  boxy.entriesBuffered.incl(key)

  var imageInfo = ImageInfo()
  boxy.entries[key] = imageInfo
  imageInfo.size = ivec2(image.width.int32, image.height.int32)

  if image.isOneColor():
    imageInfo.oneColor = image[0, 0].color
  else:
    var
      img = image
      level = 0
    while true:
      imageInfo.tiles.add(@[])

      # Split the image into tiles.
      for y in 0 ..< (ceil(img.height / boxy.tileSize).int):
        for x in 0 ..< (ceil(img.width / boxy.tileSize).int):
          let tileImage = img.superImage(
            x * boxy.tileSize - boxy.tileMargin div 2,
            y * boxy.tileSize - boxy.tileMargin div 2,
            boxy.tileSize + boxy.tileMargin,
            boxy.tileSize + boxy.tileMargin
          )
          if tileImage.isOneColor():
            let tileColor = tileImage[0, 0].color
            imageInfo.tiles[level].add(
              TileInfo(kind: tkColor, color: tileColor)
            )
          else:
            let index = boxy.takeFreeTile()
            imageInfo.tiles[level].add(TileInfo(kind: tkIndex, index: index))
            when not defined(ds3):
              updateSubImage(
                boxy.atlasTexture,
                (index mod boxy.tileRun) * (boxy.tileSize + boxy.tileMargin),
                (index div boxy.tileRun) * (boxy.tileSize + boxy.tileMargin),
                tileImage
              )
            else:
              boxy.backend.uploadTile(
                boxy.atlasHandle,
                (index mod boxy.tileRun) * (boxy.tileSize + boxy.tileMargin),
                (index div boxy.tileRun) * (boxy.tileSize + boxy.tileMargin),
                tileImage,
                level
              )
      if not mipmaps:
        break

      when not defined(ds3):
        # PICA200 atlas is single-level; uploadTile no-ops for level > 0.
        # On ds3 the while loop exits here — no mip levels are generated.
        if img.width <= 1 or img.height <= 1:
          break

        img = img.minifyBy2()
        inc level
      else:
        break

proc getImageSize*(boxy: Boxy, key: string): IVec2 =
  ## Return the size of an inserted image.
  boxy.entries[key].size

proc checkBatch(boxy: Boxy) {.inline.} =
  when not defined(ds3):
    if boxy.quadCount == boxy.quadsPerBatch:
      boxy.flush()
  # ds3: no mid-frame flush — single-batch-per-frame constraint.
  # addQuad raises BackendError if quadLimit is exceeded; callers must
  # not draw more than quadLimit quads per frame on this backend.

when not defined(ds3):
  proc setVert(buf: var seq[float32], i: int, v: Vec2) =
    buf[i * 2 + 0] = v.x
    buf[i * 2 + 1] = v.y

  proc setVertColor(buf: var seq[uint8], i: int, rgbx: ColorRGBX) =
    buf[i * 4 + 0] = rgbx.r
    buf[i * 4 + 1] = rgbx.g
    buf[i * 4 + 2] = rgbx.b
    buf[i * 4 + 3] = rgbx.a

  proc drawQuad(
    boxy: Boxy,
    verts: array[4, Vec2],
    uvs: array[4, Vec2],
    tints: array[4, Color]
  ) =
    boxy.checkBatch()

    let offset = boxy.quadCount * 4
    boxy.positions.data.setVert(offset + 0, verts[0])
    boxy.positions.data.setVert(offset + 1, verts[1])
    boxy.positions.data.setVert(offset + 2, verts[2])
    boxy.positions.data.setVert(offset + 3, verts[3])

    boxy.uvs.data.setVert(offset + 0, uvs[0])
    boxy.uvs.data.setVert(offset + 1, uvs[1])
    boxy.uvs.data.setVert(offset + 2, uvs[2])
    boxy.uvs.data.setVert(offset + 3, uvs[3])

    boxy.colors.data.setVertColor(offset + 0, tints[0].asRgbx())
    boxy.colors.data.setVertColor(offset + 1, tints[1].asRgbx())
    boxy.colors.data.setVertColor(offset + 2, tints[2].asRgbx())
    boxy.colors.data.setVertColor(offset + 3, tints[3].asRgbx())

    inc boxy.quadCount

  proc drawUvRect(boxy: Boxy, at, to, uvAt, uvTo: Vec2, tint: Color) =
    ## Adds an image rect with a path to a ctx
    ## at, to, uvAt, uvTo are all in pixels
    let
      posQuad = [
        boxy.mat * vec2(at.x, to.y),
        boxy.mat * vec2(to.x, to.y),
        boxy.mat * vec2(to.x, at.y),
        boxy.mat * vec2(at.x, at.y),
      ]
      uvAt = uvAt / boxy.atlasSize.float32
      uvTo = uvTo / boxy.atlasSize.float32
      uvQuad = [
        vec2(uvAt.x, uvTo.y),
        vec2(uvTo.x, uvTo.y),
        vec2(uvTo.x, uvAt.y),
        vec2(uvAt.x, uvAt.y),
      ]
      tints = [tint, tint, tint, tint]

    boxy.drawQuad(posQuad, uvQuad, tints)

  proc addWhiteTile(boxy: Boxy) =
    # Insert a solid white tile used for all one color draws.
    let whiteTile = newImage(boxy.tileSize, boxy.tileSize)
    whiteTile.fill(color(1, 1, 1, 1))
    updateSubImage(boxy.atlasTexture, 0, 0, whiteTile)
    boxy.takenTiles[0] = true

else:
  proc drawUvRect(boxy: Boxy, at, to, uvAt, uvTo: Vec2, tint: Color) =
    ## Submit one textured quad to the citro3d backend.
    ## at/to are screen-space pixel coords; uvAt/uvTo are atlas-space pixels.
    let
      posQuad = [
        boxy.mat * vec2(at.x, to.y),
        boxy.mat * vec2(to.x, to.y),
        boxy.mat * vec2(to.x, at.y),
        boxy.mat * vec2(at.x, at.y),
      ]
      uvAtN = uvAt / boxy.atlasSize.float32
      uvToN = uvTo / boxy.atlasSize.float32
      # PICA200 samples texture V from the bottom edge, opposite the swizzle's
      # py=0 (top) row convention (swizzleTileIntoAtlas writes pixie row 0 at
      # atlas py=0). Flip V (1 - v) so atlas row 0 maps to the top of the quad;
      # without this the atlas samples the wrong rows (verified on Azahar:
      # top-placed tiles read as transparent/black). Verified upright on-device.
      uvQuad = [
        vec2(uvAtN.x, 1f - uvToN.y),
        vec2(uvToN.x, 1f - uvToN.y),
        vec2(uvToN.x, 1f - uvAtN.y),
        vec2(uvAtN.x, 1f - uvAtN.y),
      ]
      tints = [tint, tint, tint, tint]
    # Downcast is safe: on ds3, newBoxy always assigns a Citro3dBackend.
    # addQuad is not in the Backend vtable (PICA200-specific API).
    let c3d = Citro3dBackend(boxy.backend)
    c3d.addQuad(posQuad, uvQuad, tints)
    inc boxy.quadCount

  proc addWhiteTile(boxy: Boxy) =
    # Insert a solid white tile at atlas origin for solid-color draws.
    let whiteTile = newImage(boxy.tileSize, boxy.tileSize)
    whiteTile.fill(color(1, 1, 1, 1))
    boxy.backend.uploadTile(boxy.atlasHandle, 0, 0, whiteTile, 0)
    boxy.takenTiles[0] = true

proc drawRect*(
  boxy: Boxy,
  rect: Rect,
  color: Color
) =
  if color != color(0, 0, 0, 0):
    boxy.drawUvRect(
      rect.xy,
      rect.xy + rect.wh,
      vec2(boxy.tileSize / 2, boxy.tileSize / 2),
      vec2(boxy.tileSize / 2, boxy.tileSize / 2),
      color
    )

when not defined(ds3):
  proc readyTmpTexture(boxy: Boxy) =
    ## Makes sure boxy.tmpTexture is ready to be used.
    if boxy.tmpTexture == nil:
      boxy.tmpTexture = Texture()
      boxy.tmpTexture.width = 1
      boxy.tmpTexture.height = 1
      boxy.tmpTexture.componentType = GL_UNSIGNED_BYTE
      boxy.tmpTexture.format = GL_RGBA
      boxy.tmpTexture.internalFormat = GL_RGBA8
      boxy.tmpTexture.magFilter = filterLinear
      boxy.tmpTexture.minFilter = filterLinear
    if boxy.tmpTexture.width != boxy.frameSize.x.int32 or
      boxy.tmpTexture.height != boxy.frameSize.y.int32:
      boxy.tmpTexture.width = boxy.frameSize.x.int32
      boxy.tmpTexture.height = boxy.frameSize.y.int32
      bindTextureData(boxy.tmpTexture, nil)
    if boxy.tmpFramebuffer == 0:
      glGenFramebuffers(1, boxy.tmpFramebuffer.addr)
      boxy.drawToTexture(boxy.tmpTexture, boxy.tmpFramebuffer)
      checkFramebuffer()
    else:
      glBindFramebuffer(GL_FRAMEBUFFER, boxy.tmpFramebuffer)

  proc pushLayer*(boxy: Boxy) =
    ## Starts drawing into a new layer.
    if not boxy.frameBegun:
      raise newException(BoxyError, "beginFrame has not been called")
    boxy.flush()
    inc boxy.layerNum
    if boxy.layerNum >= boxy.layerTextures.len:
      boxy.addLayerTexture()
    else:
      glBindFramebuffer(GL_FRAMEBUFFER, boxy.layerFramebuffers[boxy.layerNum])
    boxy.clearColor()

  proc popLayer*(
    boxy: Boxy,
    tint = color(1, 1, 1, 1),
    blendMode: BlendMode = NormalBlend
  ) =
    ## Pops the layer and draws with tint and blend.
    if boxy.layerNum == -1:
      raise newException(BoxyError, "popLayer called without pushLayer")
    boxy.flush()
    let layerTexture = boxy.layerTextures[boxy.layerNum]
    let savedAtlasTexture = boxy.atlasTexture
    dec boxy.layerNum
    if blendMode in {NormalBlend, MaskBlend, ScreenBlend}:
      glBindFramebuffer(GL_FRAMEBUFFER, if boxy.layerNum == -1: 0.GLuint else: boxy.layerFramebuffers[boxy.layerNum])
      if blendMode == NormalBlend:
        boxy.atlasTexture = layerTexture
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
        boxy.activeShader = boxy.atlasShader
      elif blendMode == MaskBlend:
        boxy.atlasTexture = layerTexture
        glBlendFunc(GL_ZERO, GL_SRC_COLOR)
        boxy.activeShader = boxy.maskShader
      elif blendMode == ScreenBlend:
        boxy.atlasTexture = layerTexture
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_COLOR)
        boxy.activeShader = boxy.atlasShader
      boxy.drawUvRect(
        at = vec2(0, 0),
        to = boxy.frameSize.vec2,
        uvAt = vec2(0, boxy.atlasSize.float32),
        uvTo = vec2(boxy.atlasSize.float32, 0),
        tint = tint
      )
      boxy.flush(blendMode != MaskBlend)
    else:
      let
        srcTexture = layerTexture
        dstTexture = boxy.layerTextures[boxy.layerNum]
      boxy.readyTmpTexture()
      boxy.clearColor()
      glActiveTexture(GL_TEXTURE0)
      glBindTexture(GL_TEXTURE_2D, srcTexture.textureId)
      glActiveTexture(GL_TEXTURE1)
      glBindTexture(GL_TEXTURE_2D, dstTexture.textureId)
      glUseProgram(boxy.blendShader.programId)
      boxy.blendShader.setUniform("proj", boxy.proj)
      boxy.blendShader.setUniform("srcTexture", 0)
      boxy.blendShader.setUniform("dstTexture", 1)
      boxy.blendShader.setUniform("blendMode", blendMode.ord.int32)
      boxy.blendShader.bindUniforms()
      boxy.drawUvRect(
        at = vec2(0, 0),
        to = boxy.frameSize.vec2,
        uvAt = vec2(0, boxy.atlasSize.float32),
        uvTo = vec2(boxy.atlasSize.float32, 0),
        tint = tint
      )
      boxy.upload()
      boxy.drawVertexArray()
      swap boxy.layerTextures[boxy.layerNum], boxy.tmpTexture
      swap boxy.layerFramebuffers[boxy.layerNum], boxy.tmpFramebuffer
    boxy.atlasTexture = savedAtlasTexture
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
    boxy.activeShader = boxy.atlasShader

  proc copyLowerToCurrent*(boxy: Boxy) =
    ## Copies the immediately lower layer texture into the current layer.
    if boxy.layerNum <= 0:
      raise newException(BoxyError, "copyLowerToCurrent requires an active layer above a lower layer")
    boxy.flush()
    let srcTexture = boxy.layerTextures[boxy.layerNum - 1]
    let savedAtlasTexture = boxy.atlasTexture
    let savedShader = boxy.activeShader
    boxy.atlasTexture = srcTexture
    boxy.activeShader = boxy.atlasShader
    boxy.drawUvRect(
      at = vec2(0, 0),
      to = boxy.frameSize.vec2,
      uvAt = vec2(0, boxy.atlasSize.float32),
      uvTo = vec2(boxy.atlasSize.float32, 0),
      tint = color(1, 1, 1, 1)
    )
    boxy.flush()
    boxy.atlasTexture = savedAtlasTexture
    boxy.activeShader = savedShader

  proc blurEffect(
    boxy: Boxy,
    radius: float32,
    tint: Color,
    offset: Vec2,
    readLayer: int,
    writeLayer: int
  ) =
    ## Blurs the current layer
    if boxy.layerNum == -1:
      raise newException(BoxyError, "blurEffect called without pushLayer")
    boxy.flush()
    boxy.readyTmpTexture()
    boxy.clearColor()
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, boxy.layerTextures[readLayer].textureId)
    glUseProgram(boxy.blurXShader.programId)
    boxy.blurXShader.setUniform("srcTexture", 0)
    boxy.blurXShader.setUniform("proj", boxy.proj)
    boxy.blurXShader.setUniform("pixelScale", 1 / boxy.frameSize.x.float32)
    boxy.blurXShader.setUniform("blurRadius", radius)
    boxy.blurXShader.bindUniforms()
    boxy.drawUvRect(
      at = vec2(0, 0),
      to = boxy.frameSize.vec2,
      uvAt = vec2(0, boxy.atlasSize.float32),
      uvTo = vec2(boxy.atlasSize.float32, 0),
      tint = color(1, 1, 1, 1)
    )
    boxy.upload()
    boxy.drawVertexArray()
    glBindFramebuffer(GL_FRAMEBUFFER, boxy.layerFramebuffers[writeLayer])
    boxy.clearColor()
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, boxy.tmpTexture.textureId)
    glUseProgram(boxy.blurYShader.programId)
    boxy.blurYShader.setUniform("srcTexture", 0)
    boxy.blurYShader.setUniform("proj", boxy.proj)
    boxy.blurYShader.setUniform("pixelScale", 1 / boxy.frameSize.y.float32)
    boxy.blurYShader.setUniform("blurRadius", radius)
    boxy.blurYShader.bindUniforms()
    boxy.drawUvRect(
      at = offset,
      to = offset + boxy.frameSize.vec2,
      uvAt = vec2(0, boxy.atlasSize.float32),
      uvTo = vec2(boxy.atlasSize.float32, 0),
      tint = tint
    )
    boxy.upload()
    boxy.drawVertexArray()

  proc blurEffect*(boxy: Boxy, radius: float32) =
    ## Blurs the current layer
    if boxy.layerNum == -1:
      raise newException(BoxyError, "blurEffect called without pushLayer")
    boxy.blurEffect(radius, color(1, 1, 1, 1), vec2(0, 0), boxy.layerNum, boxy.layerNum)

  proc dropShadowEffect*(boxy: Boxy, tint: Color, offset: Vec2, radius, spread: float32) =
    ## Drop shadows the current layer
    if boxy.layerNum == -1:
      raise newException(BoxyError, "shadowLayer called without pushLayer")
    boxy.pushLayer()
    let
      shadowLayerId = boxy.layerNum
      mainLayerId = boxy.layerNum - 1
      mainLayer = boxy.layerTextures[mainLayerId]
    boxy.readyTmpTexture()
    boxy.clearColor()
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, mainLayer.textureId)
    glUseProgram(boxy.spreadXShader.programId)
    boxy.spreadXShader.setUniform("srcTexture", 0)
    boxy.spreadXShader.setUniform("proj", boxy.proj)
    boxy.spreadXShader.setUniform("pixelScale", 1 / boxy.frameSize.x.float32)
    boxy.spreadXShader.setUniform("radius", spread)
    boxy.spreadXShader.bindUniforms()
    boxy.drawUvRect(
      at = vec2(0, 0),
      to = boxy.frameSize.vec2,
      uvAt = vec2(0, boxy.atlasSize.float32),
      uvTo = vec2(boxy.atlasSize.float32, 0),
      tint = color(1, 1, 1, 1)
    )
    boxy.upload()
    boxy.drawVertexArray()
    glBindFramebuffer(GL_FRAMEBUFFER, boxy.layerFramebuffers[shadowLayerId])
    boxy.clearColor()
    glBindTexture(GL_TEXTURE_2D, boxy.tmpTexture.textureId)
    glUseProgram(boxy.spreadYShader.programId)
    boxy.spreadYShader.setUniform("srcTexture", 0)
    boxy.spreadYShader.setUniform("proj", boxy.proj)
    boxy.spreadYShader.setUniform("pixelScale", 1 / boxy.frameSize.y.float32)
    boxy.spreadYShader.setUniform("radius", spread)
    boxy.spreadYShader.bindUniforms()
    boxy.drawUvRect(
      at = vec2(0, 0) + offset,
      to = boxy.frameSize.vec2 + offset,
      uvAt = vec2(0, boxy.atlasSize.float32),
      uvTo = vec2(boxy.atlasSize.float32, 0),
      tint = color(1, 1, 1, 1)
    )
    boxy.upload()
    boxy.drawVertexArray()
    boxy.blurEffect(radius, tint, offset, shadowLayerId, shadowLayerId)
    swap(boxy.layerTextures[shadowLayerId], boxy.layerTextures[mainLayerId])
    swap(boxy.layerFramebuffers[shadowLayerId], boxy.layerFramebuffers[mainLayerId])
    boxy.popLayer()

proc beginFrame*(boxy: Boxy, frameSize: IVec2, proj: Mat4, clearFrame = true) =
  ## Starts a new frame.
  ## On ds3, `clearFrame` is not honored — the app owns the frame lifecycle
  ## (c3dFrameBegin/c3dFrameEnd) and is responsible for clearing render targets.
  ## On ds3, the `proj` argument is also not honored for atlas draws (drawImage/
  ## drawRect): prepareAtlasDraw recomputes topScreenOrthoProj from frameSize
  ## each frame, ignoring any custom matrix supplied here.
  ## On ds3, addImage must be called before beginFrame (not inside a frame pair).
  if boxy.frameBegun:
    raise newException(BoxyError, "beginFrame has already been called")

  if boxy.frameSize != frameSize:
    boxy.frameSize = frameSize
    when not defined(ds3):
      for texture in boxy.layerTextures:
        texture.width = frameSize.x
        texture.height = frameSize.y
        bindTextureData(texture, nil)

  boxy.frameBegun = true
  boxy.proj = proj

  when not defined(ds3):
    glViewport(0, 0, boxy.frameSize.x, boxy.frameSize.y)
    if clearFrame:
      boxy.clearColor()

proc beginFrame*(boxy: Boxy, frameSize: IVec2, clearFrame = true) {.inline.} =
  beginFrame(
    boxy,
    frameSize,
    ortho(0.float32, frameSize.x.float32, frameSize.y.float32, 0, -1000, 1000),
    clearFrame
  )

proc endFrame*(boxy: Boxy) =
  ## Ends a frame.
  if not boxy.frameBegun:
    raise newException(BoxyError, "beginFrame has not been called")
  if boxy.layerNum != -1:
    raise newException(BoxyError, "Not all layers have been popped")

  boxy.frameBegun = false
  boxy.flush()

proc destroy*(boxy: Boxy) =
  ## Releases backend GPU resources (atlas texture, quad buffers, shaders).
  ## On ds3: call before c3dFini. Idempotent — safe to call multiple times.
  boxy.backend.destroy()

proc applyTransform*(boxy: Boxy, m: Mat3) =
  ## Applies transform to the internal transform.
  boxy.mat = boxy.mat * m

proc setTransform*(boxy: Boxy, m: Mat3) =
  ## Sets the internal transform.
  boxy.mat = m

proc getTransform*(boxy: Boxy): Mat3 =
  ## Gets the internal transform.
  boxy.mat

proc translate*(boxy: Boxy, v: Vec2) =
  ## Translate the internal transform.
  boxy.mat = boxy.mat * translate(v)

proc rotate*(boxy: Boxy, angle: float32) =
  ## Rotates the internal transform.
  boxy.mat = boxy.mat * rotate(angle)

proc scale*(boxy: Boxy, scale: Vec2) =
  ## Scales the internal transform.
  boxy.mat = boxy.mat * scale(scale)

proc scale*(boxy: Boxy, scale: float32) {.inline.} =
  ## Scales the internal transform.
  boxy.scale(vec2(scale))

proc saveTransform*(boxy: Boxy) =
  ## Pushes a transform onto the stack.
  boxy.mats.add boxy.mat

proc restoreTransform*(boxy: Boxy) =
  ## Pops a transform off the stack.
  boxy.mat = boxy.mats.pop()

proc clearTransform*(boxy: Boxy) =
  ## Clears transform and transform stack.
  boxy.mat = mat3()
  boxy.mats.setLen(0)

proc fromScreen*(boxy: Boxy, windowFrame: Vec2, v: Vec2): Vec2 =
  ## Takes a point from screen and translates it to point inside the current transform.
  (boxy.mat.inverse() * vec3(v.x, windowFrame.y - v.y, 0)).xy

proc toScreen*(boxy: Boxy, windowFrame: Vec2, v: Vec2): Vec2 =
  ## Takes a point from current transform and translates it to screen.
  result = (boxy.mat * vec3(v.x, v.y, 1)).xy
  result.y = -result.y + windowFrame.y

proc drawImage*(
  boxy: Boxy,
  key: string,
  pos: Vec2,
  tint = color(1, 1, 1, 1)
) =
  ## Draws image at pos from top-left.
  ## The image should have already been added.
  let imageInfo = boxy.entries[key]
  if imageInfo.tiles.len == 0:
    boxy.drawRect(
      rect(pos, imageInfo.size.vec2),
      imageInfo.oneColor * tint
    )
  else:
    var i = 0
    let
      xVec = vec2(boxy.mat[0, 0], boxy.mat[0, 1])
      yVec = vec2(boxy.mat[0, 1], boxy.mat[1, 1])
      vecMag = max(xVec.length, yVec.length)
      wantLevel = int((-log2(vecMag) + 0.5).floor)
      level = clamp(wantLevel, 0, imageInfo.tiles.len - 1)
      levelPow2 = 2 ^ level
      scale = vec2(levelPow2, levelPow2)
      pos = pos / scale

    boxy.saveTransform()
    boxy.scale(scale)

    var
      width = imageInfo.size.x
      height = imageInfo.size.y
    for _ in 0 ..< level:
      if width mod 2 != 0:
        width = width div 2 + 1
      else:
        width = width div 2
      if height mod 2 != 0:
        height = height div 2 + 1
      else:
        height = height div 2

    for y in 0 ..< (ceil(height / boxy.tileSize).int):
      for x in 0 ..< (ceil(width / boxy.tileSize).int):
        let
          tile = imageInfo.tiles[level][i]
          posAt = pos + vec2(x * boxy.tileSize, y * boxy.tileSize)
        case tile.kind:
        of tkIndex:
          var uvAt = vec2(
            (tile.index mod boxy.tileRun) * (boxy.tileSize + boxy.tileMargin),
            (tile.index div boxy.tileRun) * (boxy.tileSize + boxy.tileMargin)
          )
          uvAt += vec2(boxy.tileMargin div 2, boxy.tileMargin div 2)
          boxy.drawUvRect(
            posAt,
            posAt + vec2(boxy.tileSize, boxy.tileSize),
            uvAt,
            uvAt + vec2(boxy.tileSize, boxy.tileSize),
            tint
          )
        of tkColor:
          if tile.color != color(0, 0, 0, 0):
            let wh = vec2(
              min(boxy.tileSize.float32, imageInfo.size.x.float32),
              min(boxy.tileSize.float32, imageInfo.size.y.float32)
            )
            boxy.drawRect(
              rect(posAt, wh),
              tile.color * tint
            )
        inc i

    boxy.restoreTransform()
    assert i == imageInfo.tiles[level].len

proc drawImage*(
  boxy: Boxy,
  key: string,
  rect: Rect,
  tint = color(1, 1, 1, 1)
) =
  ## Draws image filling the rect.
  ## The image should have already been added.
  let imageInfo = boxy.entries[key]
  boxy.saveTransform()
  let
    scale = rect.wh / imageInfo.size.vec2
    pos = vec2(
      rect.x / scale.x,
      rect.y / scale.y
    )
  boxy.scale(scale)
  boxy.drawImage(key, pos, tint)
  boxy.restoreTransform()

proc drawImage*(
  boxy: Boxy,
  key: string,
  center: Vec2,
  angle: float32,
  tint = color(1, 1, 1, 1),
  scale: float32 = 1
) =
  ## Draws image at center and rotated by angle.
  ## The image should have already been added.
  let imageInfo = boxy.entries[key]
  boxy.saveTransform()
  boxy.translate(center)
  boxy.rotate(angle)
  boxy.scale(vec2(scale, scale))
  boxy.translate(-imageInfo.size.vec2 / 2)
  boxy.drawImage(key, pos = vec2(0, 0), tint)
  boxy.restoreTransform()

when not defined(ds3):
  proc getImage*(boxy: Boxy, bounds: Rect): Image =
    ## Gets an Image rectangle from the current layer.
    ## Note: This is very costly because it transfers GPU data to CPU.
    ## It's not recommended to use this in a game loop.
    if boxy.layerNum == -1:
      raise newException(BoxyError, "getImage called without pushLayer")
    let layerTexture = boxy.layerTextures[boxy.layerNum]
    let fullLayer = layerTexture.readImage()
    fullLayer.flipVertical()
    return fullLayer.subImage(
      bounds.x.int,
      bounds.y.int,
      bounds.w.int,
      bounds.h.int
    )
