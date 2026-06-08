# Sony PS Vita Support Plan (boxy)

## Metadata

- **Target repo:** `boxy` (`github.com/birbparty/boxy`) — 2D GPU rendering with a tiling atlas
- **Define symbol:** `-d:vita` (mirrors `-d:ds3` for 3DS, `-d:emscripten` for web)
- **Author:** planning pass, 2026-06-07
- **Toolchain:** VitaSDK (`arm-vita-eabi-gcc`), graphics via **vitaGL** (OpenGL ES over sceGxm)
- **Status:** PLAN ONLY — nothing implemented yet
- **References studied:**
  - boxy `origin/matt.spurlin/3ds-support` (the citro3d native-backend port)
  - boxy `master` emscripten path (the existing GLES seam — the real template here)
  - `~/git/configy/.agents/plans/vita-support/` (toolchain, `-Wl,-q`, velf→vpk packaging)
  - `~/git/raylib-nim-multiplatform` (`nim_vita.cfg`, `scripts/build_vita.sh`, vitaGL graphics)

---

## Bottom line (read first)

**boxy's Vita port is emscripten-shaped, not 3DS-shaped.**

The 3DS port was a *native rewrite*: PICA200 has no OpenGL, so the branch built an
entire `Citro3dBackend` (citro3d/libctru FFI, a PICA200 vertex shader, Morton
swizzle, fixed-function TEV blending) behind a new `Backend` interface. That was
~40 ralph iterations of work.

Vita does **not** need that. Vita's homebrew graphics standard is **vitaGL** — an
OpenGL ES implementation layered over sceGxm. boxy is already an OpenGL renderer
that **already runs on GLES** (the `when defined(emscripten)` path compiles boxy's
shaders as `"300 es"` and links GL statically). Porting to Vita is therefore the
same *class* of change as the emscripten port:

1. Teach boxy's existing GL path to compile/link against vitaGL under `-d:vita`.
2. Generalize the handful of `when defined(emscripten)` guards to also cover Vita.
3. Add the VitaSDK toolchain config + velf→fself→sfo→vpk packaging (copy from
   configy / raylib — purely mechanical).

We do **not** write a native sceGxm backend. We reuse boxy's OpenGL backend.

### The one real unknown: GLSL version (resolve FIRST, in Phase 0)

boxy emits shaders at three GLSL levels via `shady.toGLSL`:
- desktop: `"410"`
- emscripten: `"300 es"` (GLSL ES 3.00 — `in`/`out`/`texture()`)

The raylib-nim reference reported its vitaGL as `GL_SHADING_LANGUAGE_VERSION = "1.00 ES"`
(GLSL ES 1.00 — `attribute`/`varying`/`gl_FragColor`/`texture2D()`). **GLSL ES 1.00
and 3.00 are not source-compatible.** Which one our vitaGL accepts splits the effort:

- **vitaGL accepts `300 es`** → reuse the emscripten shader path almost verbatim.
  Easy. One dependency request (`opengl`). *(Modern vitaGL builds can run a
  GLES2/3-unified shader path; this is plausible but UNVERIFIED.)*
- **vitaGL only accepts `100`** → boxy needs a GLSL ES 1.00 shader variant, **and
  `shady` cannot currently emit it** (see grounding below) → a **second dependency
  request (`shady`)** plus real shader work, or hand-written `.vert/.frag` strings
  for the Vita path that bypass shady.

**Everything else in this port is mechanical.** The shaders are the only
non-mechanical unknown, so a shader-compilation spike is **Phase 0** and the rest of
the plan branches on its result.

---

## Decisions (locked)

1. **Reuse the OpenGL backend via vitaGL. Do NOT write a native sceGxm backend.**
   This is the entire reason vitaGL exists and the reason Vita is cheaper than 3DS.
2. **Base this work on `master`, not on the `3ds-support` branch.** The 3DS branch's
   `Backend`-interface refactor (backend_interface.nim / opengl_backend.nim /
   citro3d_backend.nim) is for swapping in a *non-GL* backend. Vita stays on the GL
   path, so it needs none of that abstraction. The two efforts are independent and
   coexist cleanly if both land (Vita's GLES guards sit in the same GL code the 3DS
   branch moved into `opengl_backend.nim`).
3. **`-d:vita` is the gate.** Mirror the existing `when defined(emscripten)` idiom.
   Prefer a single internal alias (e.g. a `boxyGles {.booldefine.}` or a
   `when defined(emscripten) or defined(vita)` helper) so the GLES branches are
   shared, not duplicated.
4. **Windowing/GL-context creation is the caller's job** (as it already is). boxy's
   `src/` imports no windowing library (`windy` appears only in `examples/`). The
   Vita example calls `vglInit*()` to create the GL context the way desktop examples
   call windy and the web build uses a canvas. No windowing dependency request.
5. **`--mm:arc` + `-d:useMalloc -d:nimAllocPagesViaMalloc -d:noSignalHandler`** for
   the Vita build (the console memory/runtime profile — same set configy/raylib use).
6. **`-Wl,-q` is mandatory.** vita-elf-create needs retained relocations or the
   module data-aborts at a non-link load base on real hardware (Vita3K hides this).

---

## Current state (verified during planning)

All of the following were confirmed by reading boxy `master` and the dep packages —
not assumed:

- **boxy uses the `opengl` Nim module directly** (`GLuint`, `glGenFramebuffers`,
  `glGenVertexArrays`, `glBindFramebuffer`, …) — `src/boxy.nim`, `src/boxy/shaders.nim`.
- **`windy` is NOT used in `src/`** — only in `examples/`. The library does not
  window. (`grep -rn windy src/` → none.)
- **An emscripten/GLES path already exists** and is the seam we extend:
  - `src/boxy.nim:202` — `when defined(emscripten):` builds all shaders as `"300 es"`
    with `"precision highp float;\n"`, vs `"410"` for desktop.
  - `src/boxy.nim:393` — `when not defined(emscripten):` guards a desktop-only
    `atlasTexture.writeFile("tmp/atlas.png")` debug dump.
  - `src/boxy/textures.nim:187` — `readImage` raises under emscripten (no
    `glGetTexImage` in GLES); the only `glGetTexImage` call in `src/`.
- **The `opengl` module has no Vita branch.** `opengl/private/prelude.nim` makes the
  GL procs *direct static `importc` externs* (empty `ogl` pragma) for
  `android or js or emscripten or wasm`, and uses **`dynlib`/`loadLib` runtime
  loading** for everything else. Vita falls into the `else` (dynlib) branch, which
  cannot work on Vita (no `dlopen` of `libGL`). → **dependency request + interim
  vendored patch** (see `dependency-requests.md`).
- **`loadExtensions()` is examples-only** — never called from `src/`. So the fact
  that the opengl module only defines `loadExtensions` in its dynlib branch does not
  affect the library; Vita examples simply won't call it (exactly like emscripten).
- **`shady` cannot emit GLSL ES 1.00.** `shady.nim:992`:
  `glslTarget = if "es" in version: glslES3 else: glslDesktop`. There are only two
  modes. Passing `"100"` does **not** produce GLSL 1.00 — it contains no `"es"`, so
  shady emits *desktop* syntax (`in`/`out`/`texture()`) under a `#version 100` header,
  which is invalid GLES2. This is the load-bearing fact behind the Phase 0 branch.
- **GL feature usage in `src/`** (audit for GLES compatibility):
  - `glGenFramebuffers` / `glCheckFramebufferStatus` — FBOs; fine on GLES (already
    used on emscripten).
  - `glGenVertexArrays` / `glBindVertexArray` — VAOs; **core GLES2 lacks VAOs**, but
    vitaGL implements them. Already exercised on emscripten ("300 es"). *Verify in
    the spike.*
  - `glGetTexImage` — desktop/GLES-absent; already guarded out under emscripten,
    generalize the guard to Vita.

---

## Architecture: what actually changes in boxy

### Library source (`src/`) — small, additive, mirrors emscripten

| File | Change |
|------|--------|
| `src/boxy.nim` | Share the GLES shader-construction block (`"300 es"`, precision header) between emscripten and Vita — `when defined(emscripten) or defined(vita):` (or a `boxyGles` alias). **Pending Phase 0**, the version string may be `"300 es"` (reuse) or a hand-written `"100"` variant. Generalize the `tmp/atlas.png` debug-dump guard to exclude Vita. |
| `src/boxy/textures.nim` | Generalize the `readImage` `when defined(emscripten)` raise-guard to include Vita (no `glGetTexImage`). |
| `src/boxy/shaders.nim` | No change expected if `300 es` is accepted. If `100` is required, this is where the alternate shader source path is wired. |
| (no new backend file) | Vita reuses the GL code path. No `vita_backend.nim`. |

### Build config — new, copied/adapted (mechanical)

| Artifact | Source to copy from | boxy-specific delta |
|----------|--------------------|----------------------|
| `nim_vita.cfg` | configy `@if vita:` block + raylib `nim_vita.cfg` link chain | boxy needs the **vitaGL graphics link chain** (configy did not — it's graphics-free). See `graphics-and-toolchain.md`. |
| `scripts/build_vita.sh` | configy/raylib `build_vita.sh` | Compile a boxy *example* (not the lib); bundle the romfs/asset png(s) under `app0:`. Toolchain-absent ⇒ exit 0 (PASS-for-scope), per configy. |
| `scripts/run_vita.sh` | raylib `run_vita.sh` | Vita3K launch; build-if-missing. |
| `.gitignore` | both | `nim.cfg` is transient (copied from `nim_vita.cfg`); `*.velf *.vpk eboot.bin param.sfo librt.a libdl.a`. |

### Example — new

- `examples/basic_vita.nim` — the Vita equivalent of `basic_windy.nim` /
  `examples/basic.html`: `vglInit(...)` to create the GLES context, `newBoxy()`,
  `addImage`, a frame loop doing `drawImage`, `SceCtrl` polling for exit, and
  `vglSwapBuffers()`/present. This is also the verification harness (there is no
  meaningful headless render test on-device).

### Docs — new

- This `plan.md`, `graphics-and-toolchain.md`, `dependency-requests.md`, and a
  `RESULTS.md` to be filled after the spike + hardware runs (mirrors configy).

---

## Phased task breakdown

### Phase 0 — Shader/vitaGL spike (BLOCKING; decides the whole shape) ⏳

Goal: answer "does our vitaGL accept boxy's `300 es` shaders?" before committing.

**Harness already written** (host-verified for Nim/shader-gen correctness; needs the
toolchain to actually run): `nim_vita.cfg` + `examples/vita_shader_spike.nim`. The
spike generates boxy's **real** 8 shader sources via `toGLSL(... "300 es" ...)`,
`vglInit`s a context, compiles/links all 7 programs with raw GL, probes VAO support,
logs `GL_VERSION`/`GLSL_VERSION`/`GL_RENDERER`, and writes the verdict to
`ux0:data/boxy_vita_shader_spike.txt`.

> **Gotcha confirmed during authoring:** `shady.toGLSL` reads `version.strVal` off the
> AST node, so the version/precision args MUST be inline string **literals**. Passing a
> `const ES = "300 es"` silently emits `#version ES` *and* picks the desktop dialect
> (`"es" in "ES"` is false). `src/boxy.nim` already uses literals; preserve that when
> adding the `-d:vita` shader guard.

1. Install VitaSDK (`vdpm bootstrap`) + vitaGL (`vdpm install vitaGL`) + Vita3K, and
   resolve the opengl fork (`cd ~/git/opengl && nimble install -y`).
2. `scripts/build_vita.sh examples/vita_shader_spike.nim` → `.vpk`; run on Vita3K
   and ideally real hardware. Read the `ux0:` marker for the verdict.
3. The spike already probes VAO availability and reports GL strings. (FBO
   completeness is exercised later by the real render example.)
4. **Branch the plan:**
   - **Compiles & links as `300 es`** → take the *Reuse* track (Phase 1A). One dep
     request (`opengl`).
   - **Rejected; only `100` works** → take the *Rewrite-shaders* track (Phase 1B).
     File the `shady` request and/or hand-write GLES2 shader strings for the Vita
     path.
   Record the outcome (and the exact GL strings/versions observed) in `RESULTS.md`.

### Phase 1A — Reuse track (if `300 es` works)

1. File the `opengl` dependency request; apply the interim vendored patch so the
   build proceeds now (`dependency-requests.md`).
2. Add `nim_vita.cfg` (toolchain + `-Wl,-q` + vitaGL link chain + console mm flags).
3. Share the emscripten GLES shader block to also fire under `-d:vita`; generalize
   the `readImage` and `tmp/atlas.png` guards.
4. Add `scripts/build_vita.sh`, `scripts/run_vita.sh`, `.gitignore` entries.
5. Write `examples/basic_vita.nim`.

### Phase 1B — Rewrite-shaders track (if only `100` works)

Same as 1A, plus:
- File the `shady` request (add a `glslES1` target) **and** provide an interim:
  hand-write GLSL ES 1.00 vertex/fragment sources for boxy's atlas/mask/blend/blur/
  spread shaders, selected under `-d:vita`. (boxy has a fixed, small shader set, so
  this is bounded but real.)
- Confirm each rewritten shader is functionally equivalent (atlas blit, mask,
  blend modes, blur X/Y, spread X/Y).

### Phase 2 — Build/link/package on real VitaSDK

1. `scripts/build_vita.sh examples/basic_vita.nim` produces a `.vpk`.
2. **Strongest non-hardware signal:** `vita-elf-create` succeeds (proves `-Wl,-q`
   retained relocations) — same gate configy uses.
3. **pixie stack cross-compiles** under `arm-vita-eabi-gcc` — explicit gate, not an
   assumption (the 3DS branch proved pixie/nimsimd/zippy on armv6k; armv7 should be
   fine, but link it cleanly here). pixie's CPU rasterization is what boxy uses to
   build images before upload.

### Phase 3 — Runtime verification

1. **Vita3K**: install `.vpk`, launch, observe boxy drawing the test image. (Weaker:
   Vita3K loads at the link base and hides `-Wl,-q` relocation bugs.)
2. **Real PS Vita hardware** (gold standard, as configy did): install via VitaShell,
   confirm render + no data-abort. Ensure `ur0:data/libshacccg.suprx` is present
   (vitaGL's runtime GLSL→GXM compiler) — a hardware-only prerequisite Vita3K hides.
3. Record all results in `RESULTS.md`.

### Phase 4 — CI / docs (optional hardening, deferred)

- A host-side `nim check -d:vita` smoke (catches Nim-level breakage with no
  toolchain). Full VitaSDK builds in CI are optional/low-priority (configy deferred
  this too).

---

## Out of scope (do NOT do)

- A native sceGxm/GXM backend (the whole point of vitaGL is to avoid this).
- The `Backend`-interface refactor from the 3DS branch (Vita reuses GL; it adds
  nothing here).
- Vita input as a boxy concern — `SceCtrl` polling lives in the example/consumer,
  not in boxy (boxy renders; it does not own input). A consumer needing unified
  input would route it through `inputty` (cf. the 3DS `inputty` request), separately.
- Touch, audio, networking, trophies, LiveArea art beyond a minimal icon.
- Merging Vita into the 3DS branch.

---

## Invariants to preserve (the contract)

- Desktop (`410`) and emscripten (`300 es`) builds are **unchanged** — every Vita
  change is additive behind `-d:vita` (or a shared GLES alias that emscripten
  already satisfies).
- boxy's public API is identical on Vita; only context creation differs (caller).
- `src/` still imports no windowing library.

---

## References

- boxy `master`: `src/boxy.nim` (lines 202, 393), `src/boxy/shaders.nim`,
  `src/boxy/textures.nim:187`.
- boxy `origin/matt.spurlin/3ds-support`: `nim_3ds.cfg`, `scripts/build_3ds.sh`,
  `docs/analysis/*` — the *native* console template (contrast, not copy).
- `opengl-1.2.9`: `opengl/private/prelude.nim` (the `ogl` pragma branch).
- `shady-0.1.5`: `shady.nim:916,969,992` (`toGLSL`, the ES3/desktop-only split).
- configy `~/git/configy/.agents/plans/vita-support/{plan,verification-gate,RESULTS}.md`.
- raylib `~/git/raylib-nim-multiplatform/{nim_vita.cfg,scripts/build_vita.sh,scripts/run_vita.sh}`,
  `.agents/plans/multiplatform/`, `.agents/docs/vita-debugging/`.
- Dependency requests: `dependency-requests.md` (this dir) +
  `~/.agents/projects/opengl/requests/`, `~/.agents/projects/shady/requests/`.
