import shady, vmath

var
  srcTexture: Uniform[Sampler2d]
  blurRadius: Uniform[float32]
  pixelScale: Uniform[float32]

proc blurXMain*(
  pos: Vec2,
  uv: Vec2,
  color: Vec4,
  fragColor: var Vec4
) =
  fragColor = vec4(0, 0, 0, 0)
  # gaussian blur
  var accumulation = 0f
  let r = max(round(blurRadius), 1)
  for x in floor(-r).int .. ceil(r).int:
    let a = exp(-(x*x).float32/(r * r)*2)
    fragColor += texture(srcTexture, uv + vec2(x.float32 * pixelScale, 0)) * a
    accumulation += a
  fragColor = fragColor / accumulation

proc blurYMain*(
  pos: Vec2,
  uv: Vec2,
  color: Vec4,
  fragColor: var Vec4
) =
  fragColor = vec4(0, 0, 0, 0)
  # gaussian blur
  var accumulation = 0f
  let r = max(round(blurRadius), 1)
  for y in floor(-r).int .. ceil(r).int:
    let a = exp(-(y*y).float32/(r * r)*2)
    fragColor += texture(srcTexture, uv + vec2(0, y.float32 * pixelScale)) * a
    accumulation += a
  fragColor = fragColor / accumulation
  fragColor *= color

# GLSL ES 1.00 (glslES1 / Vita) variants. GLSL ES 1.00 requires *constant* loop
# bounds, so the uniform-bounded loops above are illegal there (shady fail-errors).
# These use a constant MaxBlurRadius bound with an early `break` at the runtime radius
# (and round()->floor(x+0.5), since round is ES 3.00+). They sample x=0 once and ±x
# symmetrically, which is identical taps/weights to the [-r, r] loop above. Selected
# only under -d:vita in newBoxy; desktop/web keep blurXMain/blurYMain unchanged.
const MaxBlurRadius* = 64

proc blurXMainEs1*(
  pos: Vec2,
  uv: Vec2,
  color: Vec4,
  fragColor: var Vec4
) =
  fragColor = vec4(0, 0, 0, 0)
  var accumulation = 0f
  let r = max(floor(blurRadius + 0.5), 1)
  for x in 0 .. MaxBlurRadius:
    if x.float32 > r:
      break
    let a = exp(-(x*x).float32/(r * r)*2)
    if x == 0:
      fragColor += texture(srcTexture, uv) * a
      accumulation += a
    else:
      fragColor += texture(srcTexture, uv + vec2(x.float32 * pixelScale, 0)) * a
      fragColor += texture(srcTexture, uv - vec2(x.float32 * pixelScale, 0)) * a
      accumulation += a * 2
  fragColor = fragColor / accumulation

proc blurYMainEs1*(
  pos: Vec2,
  uv: Vec2,
  color: Vec4,
  fragColor: var Vec4
) =
  fragColor = vec4(0, 0, 0, 0)
  var accumulation = 0f
  let r = max(floor(blurRadius + 0.5), 1)
  for y in 0 .. MaxBlurRadius:
    if y.float32 > r:
      break
    let a = exp(-(y*y).float32/(r * r)*2)
    if y == 0:
      fragColor += texture(srcTexture, uv) * a
      accumulation += a
    else:
      fragColor += texture(srcTexture, uv + vec2(0, y.float32 * pixelScale)) * a
      fragColor += texture(srcTexture, uv - vec2(0, y.float32 * pixelScale)) * a
      accumulation += a * 2
  fragColor = fragColor / accumulation
  fragColor *= color
