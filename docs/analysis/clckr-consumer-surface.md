# clckr consumer surface — boxy citro3d (ds3) backend contract

**Audience:** clckr's Nintendo 3DS port (`~/git/birbparty/clckr`).
**Request:** `~/.agents/projects/boxy/requests/2026-06-06-clckr-consumes-citro3d-3ds-branch.md`
**Branch:** `matt.spurlin/3ds-support` (consumed by clckr via git pin).
**Verified:** 2026-06-06 against the live code at the pin, with a committed render
gate (`examples/clckr_surface_3ds.nim`) that cross-compiles to a `.3dsx`.

This doc is the **contract** for consuming boxy's ds3 backend. It answers the four
asks, lists the supported API surface, and pins the hard constraints clckr must
respect. Everything here is confirmed by the live code and the keystone example —
not assumed.

---

## TL;DR

- **All four asks pass.** The pin builds, the bindings are importable, windy is
  not pulled in, and pixie font rasterization (`readFont`/`typeset`/`fillText` →
  `addImage`) **compiles and links cleanly on ds3**.
- The full clckr surface (drawRect ×2, a camera-transformed sprite, a pixie-text
  `addImage`, both `drawImage` overloads) is exercised in one layer-free frame by
  `examples/clckr_surface_3ds.nim`, which builds to `build/clckr_surface_3ds.3dsx`
  with exit 0 via `scripts/build_3ds.sh`.
- Re-pin to the new tip only if you want the example + this doc; the **API is
  unchanged from `3a05542`**.

---

## 1. Pin & build (ask #1, ask #4)

### Pin
clckr pins boxy at SHA `3a05542c936850c3da0178f919aa6831804837c4` on
`matt.spurlin/3ds-support`. The example + docs added by this effort are **new
commits on top** and **do not change the consumed API**, so `3a05542` stays a
valid pin. A newer tip SHA is handed off at the end of this doc; re-pinning is
optional (only a *fix* would force it — none was needed).

### nimble self-consistency (ask #1)
- `boxy.nimble` `requires` are unchanged at the pin: `nim >= 1.2.2`,
  `shady >= 0.1.4`, `bitty >= 0.1.4`, `windy >= 0.4.4`.
- `srcDir = "src"` with **no** `installDirs`/`installExt`/exclude → a git-pin
  install ships the whole tree, including `src/boxy/bindings/` and
  `src/boxy/backends/`. The bindings clckr imports are guaranteed present.

### Building for ds3 (ask #4 — windy avoidance)
ds3 builds **bypass nimble entirely**, so windy (which does not cross-compile for
ARMv6K) is never resolved. Mirror `scripts/build_3ds.sh`:

1. Compile PICA200 shader if present: `picasso shaders/render2d.v.pica -o build/render2d.shbin`.
2. Copy `nim_3ds.cfg` → `nim.cfg` (Nim auto-discovers `nim.cfg`; there is no
   `--config` flag). This sets the devkitARM toolchain, `--os:linux --cpu:arm`,
   `-march=armv6k -mtune=mpcore -mfloat-abi=hard`, the libctru/citro3d include +
   lib paths, and `-specs=3dsx.specs`.
3. Create empty `libdl.a` / `librt.a` stubs with **`arm-none-eabi-ar`** (GNU ar;
   BSD ar rejects zero-member archives). Nim injects `-ldl` for `--os:linux` and
   pixie's `times.nim` triggers `-lrt`; both are empty stubs — do **not** call
   `clock_gettime`/`dlopen` on ds3 (links, crashes at runtime).
4. `nim compile --define:ds3 -o:build/<name>.elf <target.nim>`.
5. SMDH via `smdhtool --create <title> <desc> <author> <icon48.png> out.smdh <icon24.png>`.
   **An SMDH is required by `3dsxtool` whenever `--romfs` is passed** (otherwise
   it fails with the misleading `Cannot open SMDH file!`). This repo ships
   `assets/icon48.png` + `assets/icon24.png` so `build_3ds.sh` generates one
   automatically; clckr must provide its own icons (or reuse these).
6. `3dsxtool build/<name>.elf build/<name>.3dsx --smdh=… --romfs=romfs`.

**Evidence windy is not pulled in:** `examples/clckr_surface_3ds.nim` builds to a
`.3dsx` with exit 0 through this path (which never invokes nimble). `boxy.nim`
guards every windy/opengl/shady import behind `when not defined(ds3)`; `grep`
finds no unconditional `import windy` in `src/`. shady is desktop-only.

---

## 2. Consuming the bindings (ask #2)

**Recommendation: `import boxy/bindings/...` directly. Do not vendor your own.**

```nim
import boxy/bindings/libctru_gfx   # gfxInitDefault, KEY_*, hidScanInput, …
import boxy/bindings/libctru_hid
import boxy/bindings/citro3d       # c3dInit, c3dRenderTargetCreate, c3dFrameBegin, …
```

No duplicate-FFI-symbol risk: these modules are thin `{.importc.}` declarations
that emit **no** C definition — they reference external symbols defined once by
`libctru` / `libcitro3d` (the `.a`). Two Nim declarations of the same importc
symbol both resolve to that single definition; `const KEY_A* = …` emits no symbol
at all. `examples/basic_3ds.nim` and `examples/clckr_surface_3ds.nim` both import
all three this way — that is the precedent proving the path works.

> **Caveat for the inputty side (separate request):** an *input* library importing
> a *render* library is a dependency inversion. inputty should define its own thin
> HID bindings rather than `import boxy/bindings/libctru_hid`. The only hazard
> there is **value drift** — keep `KEY_*` constant values byte-identical. boxy's
> `libctru_hid.nim` is a good reference for the correct values, not an import
> target for inputty. (clckr importing boxy's bindings for *rendering* is fine.)

`Citro3dBackend(bx.backend)` and `setScreenTarget` live in
`boxy/backends/citro3d_backend` and are only needed for **layers**. clckr does
not use layers, so it can skip that import entirely.

---

## 3. Supported API surface on ds3

Every row below is exercised by `examples/clckr_surface_3ds.nim` (the "surface
proof").

| Call | ds3 status | Notes |
|---|---|---|
| `newBoxy()` | ✅ | Must follow `c3dInit`. Inserts the white tile at index 0 (`src/boxy.nim:418`) — so `drawRect` is safe from init. |
| `addImage(key, image: pixie.Image)` | ✅ | For pixie **text** images and PNG sprites. **Must be called outside any `beginFrame`/`endFrame` pair** (see constraints). |
| `drawImage(key, pos: Vec2)` | ✅ | Used by clckr's text/widgets. |
| `drawImage(key, rect: Rect)` | ✅ | Used by clckr's coin sprite (`rect=` overload). |
| `drawRect(rect, color)` | ✅ | Flows through white-tile + `drawUvRect` — a different path than `drawImage`; exercised ×2 (background + button). |
| `saveTransform` / `applyTransform(m: Mat3)` / `restoreTransform` | ✅ | Camera transform is applied **CPU-side per-vertex** (`boxy.mat * vec2(...)` in `drawUvRect`). `applyTransform` does `boxy.mat = boxy.mat * m`. Independent of the ds3 projection. |
| `beginFrame(ivec2(w,h))` / `endFrame()` | ✅ | One pair per C3D frame. |

**Projection note:** on ds3 the `proj` argument to `beginFrame` is **ignored** —
`prepareAtlasDraw` recomputes `topScreenOrthoProj` from `frameSize` each frame
(`src/boxy.nim:1110-1112`). Likewise `clearFrame` is **not honored**: the app
owns the frame lifecycle and clears the render target itself. Use the world
camera via `saveTransform`/`applyTransform` (CPU vertex transform), **not** a
custom `proj` matrix.

---

## 4. Hard constraints clckr must respect

1. **`addImage` outside frames.** On ds3, `addImage` raises if called inside a
   `beginFrame`/`endFrame` pair (`src/boxy.nim:610-614`) — atlas grow triggers
   `c3dFrameBegin`, which cannot nest. **Build all text/sprite atlas entries
   before the render loop's frame.** (clckr already does this.)

2. **Single-flush-per-frame.** A flush happens at `endFrame` (and inside
   `popLayer`). A *second* non-empty flush in one C3D frame raises
   (`src/boxy.nim:201-206`). A flat, **layer-free** frame accumulates all draws
   into one batch flushed once at `endFrame` — the supported pattern, and exactly
   what clckr does. Do **not** arrange a `drawImage` before the first `pushLayer`
   (that is the failure the guard catches). clckr uses no layers → nothing to
   worry about.

3. **Quad limit = `10_921`** per frame (`citro3d_backend.nim:233`). There is **no
   mid-frame flush** on ds3 — `addQuad` beyond the limit raises `BackendError`.
   clckr's frame is ~5-10 quads, far under. Keep `newBoxy(quadsPerBatch=…)`
   `<= 10_921` (default 1024 is fine).

4. **App owns the frame lifecycle.** clckr calls `c3dFrameBegin` /
   `c3dFrameDrawOn` / `c3dRenderTargetClear` / `c3dFrameEnd` around the
   `beginFrame`/`endFrame` pair. **No `gfxSwapBuffers` after `c3dFrameEnd`** —
   `c3dFrameEnd` performs the display transfer; swapping would blank the screen.

---

## 5. No-op / unsupported surfaces (do not rely on these)

- **Layers / blur / spread:** clckr does not use these. Plain RTT layers render on
  ds3 (milestone 6), but the **blur/spread/MaskBlend-readback** effect paths and
  **`getImage()` / texture readback** are **unsupported on ds3**. Do not depend on
  reading pixels back from the GPU.
- **`enterRawOpenGLMode` / `exitRawOpenGLMode`:** no-op on ds3
  (`src/boxy.nim:421-429`) — there is no OpenGL context.

---

## 6. pixie status on ds3 (ask #3)

This is the **live** status from the code + the keystone build — it **supersedes**
the "guard out `import pixie` / add `pixie_stub.nim`" recommendation in
`docs/analysis/pixie-armv6k-compat.md`, which was **not taken**. pixie is compiled
into ds3 builds and works.

| pixie capability | ds3 status |
|---|---|
| CPU pixel ops (`newImage`, `fill`, `fillPath`, `draw`) | ✅ working |
| PNG decode from `romfs:/` (`readImage`) | ✅ working (basic_3ds + keystone) |
| **Font rasterization** (`readTypeface`/`newFont`/`typeset`/`fillText`) | ✅ **compiles + links cleanly** — see below |
| GPU readback (`getImage` / read-from-texture) | ❌ unsupported on ds3 |

### Ask #3 — font path, confirmed at build/link
`examples/clckr_surface_3ds.nim` reads `romfs:/font.ttf`, `typeset`s a string,
`fillText`s into an `Image`, and `addImage`s it — mirroring clckr's `widgets.nim`
`fillText → Image → addImage`. The build compiles pixie's full font stack
(`pixie/fontformats/opentype.nim`, `svgfont.nim`, `pixie/fonts.nim`) and **links
with no unresolved symbol** under devkitARM + newlib + `--gc:arc`, producing
`clckr_surface_3ds.3dsx` (exit 0).

**This gate proves compile + link only, not runtime render.** No separate
escalation request was filed, because the one item that could not be answered from
existing examples — does pixie's OpenType parse + glyph rasterization survive the
devkitARM/newlib/`--gc:arc` toolchain — now compiles and links with no unresolved
symbol. Reading a `.ttf` from `romfs:/` is a plain `readFile` (TTF is not
zippy-compressed), and PNG-decode-from-romfs was already proven.

Note the link is genuinely weaker than runtime here: `build_3ds.sh` provides
**empty `libdl.a` / `librt.a` stubs**, so code referencing those symbols links and
then crashes at runtime. The pixie font path is therefore **"compiles and links
cleanly; runtime render unverified pending the Azahar step"** — clckr can proceed
on it, but the visual confirmation below is what upgrades it to fully proven. As of
2026-06-06 nothing suggests a runtime problem; if the Azahar text render ever
fails while rects+sprite render, escalate that as a runtime-only font issue (the
rest of the surface is independent of the font path).

### Remaining manual confirmation (not a blocker)
Build/link is proven in CI; the **visual** render is a documented hands-on step
(Azahar GUI runs are not reliably scriptable). See below. If, on hardware/Azahar,
text were ever garbled while rects+sprite render correctly, that would be a
runtime-only font issue to escalate separately — the rest of the surface is
independent of the font path. As of 2026-06-06 the build gate is green and no such
failure is known.

---

## Azahar manual confirmation step

Build and load the gate, then confirm visually:

```bash
scripts/build_3ds.sh examples/clckr_surface_3ds.nim clckr_surface_3ds
open -a Azahar build/clckr_surface_3ds.3dsx     # or load via Azahar UI
```

Confirm on the top screen, then record the result here:
- full-screen background rect + the blue button rect render with correct colors;
- the sprite renders **scaled ×2 and translated** by the camera transform (not at
  the origin) — proves `saveTransform`/`applyTransform`;
- the **"clckr 3DS" text** renders legibly near the bottom-left — the ask-#3
  visual proof.

Exit via **START**.

> **Manual result (2026-06-06):** _pending hands-on Azahar run._ The automated
> gate (cross-compile + link → `.3dsx`, exit 0) is green; this visual step is a
> documented confirmation, not a CI gate. Update this line after running.

---

## SHA handoff

After this example + doc land on `matt.spurlin/3ds-support` and the build gate is
green, the new tip SHA is handed to clckr with: **"API unchanged from `3a05542`;
re-pin only if you want `clckr_surface_3ds.nim` + `clckr-consumer-surface.md`.
windy still not required; build via `nim compile --define:ds3`."**

The concrete hand-off (with the exact new tip SHA) is delivered to clckr at
`~/.agents/projects/boxy/responses/2026-06-06-clckr-consumes-citro3d-3ds-branch.md`
— that is the canonical answer to the request; this doc is the technical contract
it references.
