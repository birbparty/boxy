import buffers, opengl, pixie, vmath
import backends/backend_interface

# Re-export Filter and Wrap so existing callers (boxy.nim) don't need a new import.
export Filter, Wrap

type
  Texture* = ref object
    width*, height*: int32
    componentType*, format*, internalFormat*: GLenum
    magFilter*: Filter
    minFilter*: Filter
    mipFilter*: Filter
    wrapS*, wrapT*, wrapR*: Wrap
    useMipmap*: bool
    textureId*: GLuint

# ---------------------------------------------------------------------------
# Filter / Wrap → GL constant converters
#
# backend_interface uses sequential ordinals (0,1,2) instead of GL constants.
# These converters translate to the correct GLenum for glTexParameteri.
# The filterDefault / wDefault paths are never reached because call sites
# guard with != filterDefault / != wDefault before invoking glTexParameteri.
# ---------------------------------------------------------------------------

func toGLenum*(f: Filter): GLenum {.inline.} =
  ## Map Filter to a GL constant for glTexParameteri.
  ## filterDefault is a sentinel meaning "do not set" — call sites guard
  ## with `!= filterDefault` before calling this. The arm returns GL_NEAREST
  ## as a conservative fallback; it should never be reached.
  case f:
  of filterDefault, filterNearest: GL_NEAREST.GLenum
  of filterLinear:                 GL_LINEAR.GLenum

func toGLenum*(w: Wrap): GLenum {.inline.} =
  ## Map Wrap to a GL constant for glTexParameteri.
  ## wDefault is a sentinel meaning "do not set" — call sites guard
  ## with `!= wDefault` before calling this. GL_REPEAT is the GL default.
  case w:
  of wDefault, wRepeat:   GL_REPEAT.GLenum
  of wClampToEdge:        GL_CLAMP_TO_EDGE.GLenum
  of wMirroredRepeat:     GL_MIRRORED_REPEAT.GLenum

proc bindTextureBufferData*(texture: Texture, buffer: Buffer, data: pointer) =
  ## Binds data to a texture buffer.
  bindBufferData(buffer, data)

  if texture.textureId == 0:
    glGenTextures(1, texture.textureId.addr)

  glBindTexture(GL_TEXTURE_BUFFER, texture.textureId)
  glTexBuffer(
    GL_TEXTURE_BUFFER,
    texture.internalFormat,
    buffer.bufferId
  )

proc bindTextureData*(texture: Texture, data: pointer, useMipmap = texture.useMipmap) =
  ## Binds the data to a texture.
  if texture.textureId == 0:
    glGenTextures(1, texture.textureId.addr)

  glBindTexture(GL_TEXTURE_2D, texture.textureId)
  glTexImage2D(
    target = GL_TEXTURE_2D,
    level = 0,
    internalFormat = texture.internalFormat.GLint,
    width = texture.width,
    height = texture.height,
    border = 0,
    format = texture.format,
    `type` = texture.componentType,
    pixels = data
  )

  if texture.magFilter != filterDefault:
    glTexParameteri( # default is GL_LINEAR
      GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, texture.magFilter.toGLenum.GLint
    )
  if not texture.useMipmap:
    glTexParameteri( # default is GL_NEAREST_MIPMAP_LINEAR, but we don't use mipmaps
      GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
      if texture.minFilter == filterDefault: GL_NEAREST
      else: texture.minFilter.toGLenum.GLint
    )
  elif texture.minFilter != filterDefault or texture.mipFilter != filterDefault:
    glTexParameteri( # default is GL_NEAREST_MIPMAP_LINEAR
      GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
      case texture.minFilter:
      of filterNearest, filterDefault:
        case texture.mipFilter:
        of filterNearest: GL_NEAREST_MIPMAP_NEAREST
        else: GL_NEAREST_MIPMAP_LINEAR
      else:
        case texture.mipFilter:
        of filterNearest: GL_LINEAR_MIPMAP_NEAREST
        else: GL_LINEAR_MIPMAP_LINEAR
    )

  if texture.wrapS != wDefault:
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, texture.wrapS.toGLenum.GLint)
  if texture.wrapT != wDefault:
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, texture.wrapT.toGLenum.GLint)
  if texture.wrapR != wDefault:
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_R, texture.wrapR.toGLenum.GLint)

  if useMipmap:
    glGenerateMipmap(GL_TEXTURE_2D)

func getFormat(image: Image): GLenum =
  ## Gets the format of the image.
  result = GL_RGBA

proc newTexture*(image: Image): Texture =
  ## Creates a new texture.
  result = Texture()
  result.width = image.width.GLint
  result.height = image.height.GLint
  result.componentType = GL_UNSIGNED_BYTE
  result.format = image.getFormat()
  result.internalFormat = GL_RGBA8
  result.useMipmap = true
  result.magFilter = filterLinear
  result.minFilter = filterLinear
  result.mipFilter = filterLinear
  bindTextureData(result, image.data[0].addr)

proc updateSubImage*(texture: Texture, x, y: int, image: Image, level: int) =
  ## Update a small part of a texture image.
  glBindTexture(GL_TEXTURE_2D, texture.textureId)
  glTexSubImage2D(
    GL_TEXTURE_2D,
    level = level.GLint,
    xoffset = x.GLint,
    yoffset = y.GLint,
    width = image.width.GLint,
    height = image.height.GLint,
    format = image.getFormat(),
    `type` = GL_UNSIGNED_BYTE,
    pixels = image.data[0].addr
  )

proc updateSubImage*(texture: Texture, x, y: int, image: Image, mip = texture.useMipmap) =
  ## Update a small part of texture with a new image.
  var
    x = x
    y = y
    image = image
    level = 0
  while true:
    texture.updateSubImage(x, y, image, level)
    if not mip or image.width <= 1 or image.height <= 1:
      break
    image = image.minifyBy2()
    x = x div 2
    y = y div 2
    inc level

proc clearSubImage*(texture: Texture, x, y, width, height: int, level: int = 0) =
  ## Clears a rectangular region of the texture to transparent black.
  ## Uses a more compatible approach that works with older OpenGL versions.
  if width <= 0 or height <= 0:
    return
  let clearImage = newImage(width, height)
  glBindTexture(GL_TEXTURE_2D, texture.textureId)
  glTexSubImage2D(
    GL_TEXTURE_2D,
    level = level.GLint,
    xoffset = x.GLint,
    yoffset = y.GLint,
    width = width.GLint,
    height = height.GLint,
    format = GL_RGBA,
    `type` = GL_UNSIGNED_BYTE,
    pixels = clearImage.data[0].addr
  )

proc clearSubImage*(texture: Texture, x, y: int, size: IVec2) =
  ## Clears a rectangular region across all mipmap levels.
  if size.x <= 0 or size.y <= 0:
    return
  var
    curX = x
    curY = y
    curWidth = size.x
    curHeight = size.y
    level = 0

  while true:
    texture.clearSubImage(curX, curY, curWidth, curHeight, level)

    if curWidth <= 1 or curHeight <= 1:
      break
    if not texture.useMipmap:
      break

    # Scale down for next mipmap level
    curX = curX div 2
    curY = curY div 2
    curWidth = max(1, curWidth div 2)
    curHeight = max(1, curHeight div 2)
    inc level

proc readImage*(texture: Texture): Image =
  ## Reads the data of the texture back.
  when defined(emscripten):
    raise newException(
      Exception,
      "readImage is not supported on emscripten due to security reasons"
    )
  else:
    let image = newImage(texture.width, texture.height)
    glBindTexture(GL_TEXTURE_2D, texture.textureId)
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr)
    return image

proc writeFile*(texture: Texture, path: string) =
  ## Reads the data of the texture and writes it to file.
  let image = texture.readImage()
  image.flipVertical()
  image.writeFile(path)
