## GLSL spread-effect shader procs (spreadXMain, spreadYMain).
## Desktop/OpenGL only — the entire module is guarded under
## when not defined(ds3). Spread effects are not implemented on 3DS — PICA200
## has no programmable fragment stage; this shady-DSL module is not compiled for ds3.

when not defined(ds3):
  import shady, vmath

  var
    srcTexture: Uniform[Sampler2d]
    radius: Uniform[float32]
    pixelScale: Uniform[float32]

  proc spreadXMain*(
    pos: Vec2,
    uv: Vec2,
    color: Vec4,
    fragColor: var Vec4
  ) =
    var alpha: float32
    if radius >= 0:
      let r = radius
      alpha = 0f
      for x in floor(-r).int .. ceil(r).int:
        alpha = max(alpha, texture(
          srcTexture,
          uv + vec2(x.float32 * pixelScale, 0)
        ).a)
    else:
      let r = -radius
      alpha = 1f
      for x in floor(-r).int .. ceil(r).int:
        alpha = min(alpha, texture(
          srcTexture,
          uv + vec2(x.float32 * pixelScale, 0)
        ).a)
    fragColor.rgba = vec4(alpha)

  proc spreadYMain*(
    pos: Vec2,
    uv: Vec2,
    color: Vec4,
    fragColor: var Vec4
  ) =
    var alpha: float32
    if radius >= 0:
      let r = radius
      alpha = 0f
      for y in floor(-r).int .. ceil(r).int:
        alpha = max(alpha, texture(
          srcTexture,
          uv + vec2(0, y.float32 * pixelScale)
        ).a)
    else:
      let r = -radius
      alpha = 1f
      for y in floor(-r).int .. ceil(r).int:
        alpha = min(alpha, texture(
          srcTexture,
          uv + vec2(0, y.float32 * pixelScale)
        ).a)
    fragColor.rgba = vec4(alpha)

  # GLSL ES 1.00 (glslES1 / Vita) variants. Like blur, the uniform-bounded loops above
  # are illegal in GLSL ES 1.00. NOTE: unlike blur, shady's glslES1 does NOT reject these
  # (it silently emits a uniform-bounded `for`, which vitaGL's SceShaccCg then crashes
  # linking — confirmed on hardware), so these constant-bound + `break` variants are
  # mandatory for spread on Vita. Symmetric (0, ±x) = same [-r, r] window.
  const MaxSpreadRadius* = 64

  proc spreadXMainEs1*(
    pos: Vec2,
    uv: Vec2,
    color: Vec4,
    fragColor: var Vec4
  ) =
    var alpha: float32
    if radius >= 0:
      let r = radius
      alpha = 0f
      for x in 0 .. MaxSpreadRadius:
        if x.float32 > r:
          break
        alpha = max(alpha, texture(srcTexture, uv + vec2(x.float32 * pixelScale, 0)).a)
        if x != 0:
          alpha = max(alpha, texture(srcTexture, uv - vec2(x.float32 * pixelScale, 0)).a)
    else:
      let r = -radius
      alpha = 1f
      for x in 0 .. MaxSpreadRadius:
        if x.float32 > r:
          break
        alpha = min(alpha, texture(srcTexture, uv + vec2(x.float32 * pixelScale, 0)).a)
        if x != 0:
          alpha = min(alpha, texture(srcTexture, uv - vec2(x.float32 * pixelScale, 0)).a)
    fragColor.rgba = vec4(alpha)

  proc spreadYMainEs1*(
    pos: Vec2,
    uv: Vec2,
    color: Vec4,
    fragColor: var Vec4
  ) =
    var alpha: float32
    if radius >= 0:
      let r = radius
      alpha = 0f
      for y in 0 .. MaxSpreadRadius:
        if y.float32 > r:
          break
        alpha = max(alpha, texture(srcTexture, uv + vec2(0, y.float32 * pixelScale)).a)
        if y != 0:
          alpha = max(alpha, texture(srcTexture, uv - vec2(0, y.float32 * pixelScale)).a)
    else:
      let r = -radius
      alpha = 1f
      for y in 0 .. MaxSpreadRadius:
        if y.float32 > r:
          break
        alpha = min(alpha, texture(srcTexture, uv + vec2(0, y.float32 * pixelScale)).a)
        if y != 0:
          alpha = min(alpha, texture(srcTexture, uv - vec2(0, y.float32 * pixelScale)).a)
    fragColor.rgba = vec4(alpha)
