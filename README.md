<img src="docs/banner.png">

# Boxy - 2D GPU rendering with a tiling atlas.

`nimble install boxy`

![Github Actions](https://github.com/treeform/boxy/workflows/Github%20Actions/badge.svg)

[API reference](https://treeform.github.io/boxy)

## About

Boxy is an easy to use 2D GPU rendering API built on top of [Pixie](https://github.com/treeform/pixie).

The basic model for using Boxy goes something like this:

* Open a window and prepare an OpenGL context.
* Load image files like .png using Pixie.
* Render any dynamic assets (such as text) into images once using Pixie.
* Add these images to Boxy, where they are put into a tiling atlas texture.
* Draw these images to screen each frame.

## Videos

* [Efficient 2D rendering on GPU](https://www.youtube.com/watch?v=UFbffBIzEDc)
* [GPU Gaussian Blur in Nim using Boxy and Shady](https://youtu.be/oUB0BGsNY5g)

## Basic Example

```nim
import boxy, opengl, windy

let windowSize = ivec2(1280, 800)

let window = newWindow("Windy + Boxy", windowSize)
makeContextCurrent(window)

loadExtensions()

let bxy = newBoxy()

# Load the images.
bxy.addImage("bg", readImage("examples/data/bg.png"))
bxy.addImage("ring1", readImage("examples/data/ring1.png"))
bxy.addImage("ring2", readImage("examples/data/ring2.png"))
bxy.addImage("ring3", readImage("examples/data/ring3.png"))

var frame: int

# Called when it is time to draw a new frame.
proc display() =
  # Clear the screen and begin a new frame.
  bxy.beginFrame(windowSize)

  # Draw the bg.
  bxy.drawImage("bg", rect = rect(vec2(0, 0), windowSize.vec2))

  # Draw the rings.
  let center = windowSize.vec2 / 2
  bxy.drawImage("ring1", center, angle = frame.float / 100)
  bxy.drawImage("ring2", center, angle = -frame.float / 190)
  bxy.drawImage("ring3", center, angle = frame.float / 170)

  # End this frame, flushing the draw commands.
  bxy.endFrame()
  # Swap buffers displaying the new Boxy frame.
  window.swapBuffers()
  inc frame

while not window.closeRequested:
  display()
  pollEvents()
```

## Nintendo 3DS

Boxy can be compiled for the Nintendo 3DS using [devkitPro](https://devkitpro.org/) and the citro3d fixed-function GPU backend.

### Build Prerequisites

Install via `dkp-pacman -S 3ds-dev`:

| Tool | Purpose |
|---|---|
| devkitARM | ARMv6K cross-compiler toolchain (`arm-none-eabi-*`) |
| citro3d | 3DS GPU library (C3D_* API) |
| picasso | PICA200 assembly shader compiler (`.v.pica` → `.shbin`) |
| 3dsxtool | Packages the ELF into a runnable `.3dsx` file |
| Azahar | Nintendo 3DS emulator for local testing |

Other nimble dependencies (`bitty`, `pixie`, `vmath`) must already be installed in the nimble cache (`~/.nimble/pkgs`) before building — the 3DS build script calls `nim compile` directly and skips nimble dependency resolution.

### Build Steps

```sh
chmod +x scripts/build_3ds.sh
scripts/build_3ds.sh examples/basic_3ds.nim basic_3ds
# Output: build/basic_3ds.3dsx
```

Load `build/basic_3ds.3dsx` in Azahar or transfer it to hardware via FBI.

### API Compatibility Table

| Feature | 3DS Status | Notes |
|---|---|---|
| `addImage` | ✓ Works | Must be called **outside** a `beginFrame`/`endFrame` pair; atlas grow triggers an internal C3D frame |
| `drawImage` | ✓ Works | |
| `drawRect` | ✓ Works | |
| `beginFrame` / `endFrame` | ✓ Works | `clearFrame` and `proj` args are ignored on ds3 |
| `pushLayer` / `popLayer` — `NormalBlend` | ✓ Works | Exact premultiplied-alpha over via GPU |
| `pushLayer` / `popLayer` — `ScreenBlend` | ✓ Works | Exact hardware equivalent (`GPU_ONE / GPU_ONE_MINUS_SRC_COLOR`) |
| `pushLayer` / `popLayer` — `OverwriteBlend` | ✓ Works | Exact copy via `GPU_ONE / GPU_ZERO` |
| `pushLayer` / `popLayer` — `MultiplyBlend` | ~ Degraded | Fixed-function approximation; no framebuffer readback on PICA200 — results differ from desktop GL for non-trivial content |
| `pushLayer` / `popLayer` — `MaskBlend` | ~ Degraded | `maskShader` unavailable on PICA200; colored masks differ from desktop GL |
| All other blend modes | ⚠ Fallback | Warns once per mode to stderr, then falls back to `NormalBlend` |
| `blurEffect` | ✗ Compile error | Not defined when `--define:ds3`; guarded by `when not defined(ds3)` |
| `dropShadowEffect` | ✗ Compile error | Not defined when `--define:ds3` |
| `getImage` | ✗ Compile error | Not defined when `--define:ds3` |
| `readAtlas` | ✗ Compile error | Not defined when `--define:ds3` |
| `enterRawOpenGLMode` | ⚠ Runtime warning | Defined on ds3 but writes a warning to stderr and returns immediately |
| `exitRawOpenGLMode` | No-op | Defined on ds3, returns immediately |
| `saveTransform` / `restoreTransform` | ✓ Works | |
| `getImageSize` / `removeImage` / `contains` | ✓ Works | |

### Known Constraints

**Atlas VRAM budget** — The PICA200 GPU has ≈6 MB of VRAM. The atlas is capped at `maxAtlasSize = 1024` (4 MB for a full 1024×1024 texture). Starting size is 512×512 (1 MB); the atlas doubles on demand. A third grow to 2048 would exceed VRAM and is disallowed.

**Layer count cap** — At most 4 simultaneous RTT layer slots (`maxRtSlots = 4`). Each 512×256 RTT layer costs ≈0.5 MB; 4 layers = 2 MB, keeping the atlas + layers total within 6 MB.

**Single-flush-per-frame** — The citro3d quad batch may only be submitted once per C3D frame. Call `pushLayer` **before** any `drawImage` call in a frame. Violating this order raises `BoxyError`.

**pixie cross-compilation** — `pixie` compiles successfully for the 3DS target and is used for image loading (`readImage`). The `windy` windowing library does **not** cross-compile for ARMv6K and is excluded from 3DS builds; use the 3DS-native `libctru`/`citro3d` bindings for window and input management instead. The build script links empty `libdl.a`/`librt.a` stub archives to satisfy Nim's POSIX link flags — any code that actually calls symbols from those libraries will link but crash at runtime.

## Emscripten

Boxy can be compiled to WebAssembly using Emscripten. See the [Emscripten tutorial](https://github.com/treeform/nim_emscripten_tutorial) for more information on how Emscripten works with Nim and things you need to know.

To compile any of the examples:
```sh
nim c -d:emscripten examples/basic_windy.nim
```

This will generate:
* HTML shell: `examples/basic_windy.html`
* Preloaded data: `examples/basic_windy.data`
* JavaScript: `examples/basic_windy.js`
* WebAssembly: `examples/basic_windy.wasm`

Then run the compiled HTML file:
```sh
emrun examples/basic_windy.html
```

## Examples

You can use boxy with industry standard windowing libraries like [GLFW](https://github.com/treeform/boxy/blob/master/examples/basic_glfw.nim) and [SDL2](https://github.com/treeform/boxy/blob/master/examples/basic_sdl2.nim).


<img src="docs/basic_windy.png">

But the preferred way is to use Boxy with my own Nim native windowing library [Windy](https://github.com/treeform/boxy/blob/master/examples/basic_windy.nim).

<img src="docs/hexmap.png">

[Hexmap](https://github.com/treeform/boxy/blob/master/examples/hexmap.nim)


<img src="docs/bigbang.png">

[Bigbang](https://github.com/treeform/boxy/blob/master/examples/bigbang.nim)

<img src="docs/blending.png">

[Blending](https://github.com/treeform/boxy/blob/master/examples/blending.nim)


<img src="docs/blur.png">

[Blur](https://github.com/treeform/boxy/blob/master/examples/blur.nim)

<img src="docs/masking.png">

[Masking](https://github.com/treeform/boxy/blob/master/examples/masking.nim)

<img src="docs/shadow.png">

[Shadow](https://github.com/treeform/boxy/blob/master/examples/shadow.nim)


[Check out more examples here.](https://github.com/treeform/boxy/tree/master/examples)
