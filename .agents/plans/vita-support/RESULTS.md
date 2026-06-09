# Vita Support — Results

Running log of what has been empirically verified (vs. assumed) during the Vita port.

## 2026-06-07 — Phase 0 kit built; build/link/package pipeline PROVEN

Environment: VitaSDK 15.2.0 (`arm-vita-eabi-gcc`) present locally; Nim 2.2.10.

### ✅ Verified (empirical, on this machine)

- **boxy's GLES shader generation is sound.** A host build (no toolchain) confirmed
  `shady.toGLSL` produces all 8 of boxy's shader sources (atlasVert + atlasMain,
  maskMain, blendingMain, blurX/Y, spreadX/Y) at `"300 es"`, header `#version 300 es`
  + `precision highp float;`.
- **shady literal gotcha** (caught + fixed during authoring): the version/precision
  args to `toGLSL` MUST be inline string literals. A `const ES = "300 es"` silently
  emits `#version ES` and selects the *desktop* dialect (`"es" in "ES"` is false).
- **The `opengl` fork is REQUIRED and SUFFICIENT** (not just theory). With stock
  `opengl-1.2.9`, `-d:vita` falls into the `dynlib` branch → `dlopen`/`dlsym` drags in
  real `libdl.a` → link fails: `undefined reference to sceSblDmac5HashTransform`
  (exactly the failure configy's cfg comment predicts). With the fork
  (`birbparty/opengl`, vita in the static-link branch) the dynlib path is gone and the
  link succeeds.
- **Fork resolution needs a version bump.** Two `opengl-1.2.9` packages (stock + fork)
  tie and Nim kept picking stock. Bumping the fork to **1.2.10** makes it win
  deterministically. (Upstream PR stays the one-line prelude change; the bump is
  fork-only.)
- **pixie stack cross-compiles** under `arm-vita-eabi` (pixie common/jpeg/png compiled
  and linked) — Phase 2 gate met, not assumed.
- **Link is clean** with `nim_vita.cfg`'s stub set — no unresolved symbols.
- **`vita-elf-create` succeeds** → `-Wl,-q` retained relocations are correct. This is
  the strongest non-hardware signal (same gate configy relies on).
- **`.vpk` packages correctly**: `vita_shader_spike.vpk` (2.8 MB) — `eboot.bin` (8 MB)
  at root, `param.sfo` under `sce_sys/`, valid zip. Toolchain-absent path also exits 0
  (PASS-for-scope).

### ⏳ NOT yet verified (needs Vita3K / real hardware — cannot run headless here)

- **THE Phase 0 question:** does vitaGL accept boxy's `300 es` shaders at runtime?
  The spike compiles/links/packages, but the GLSL is only fed to vitaGL's runtime
  compiler when the `.vpk` actually runs. Run `scripts/run_vita.sh` (Vita3K) and read
  `ux0:data/boxy_vita_shader_spike.txt`:
  - `RESULT: PASS` → **reuse path confirmed** → proceed to Phase 1A (real
    `examples/basic_vita.nim` with `newBoxy`, generalize the emscripten guards to vita).
  - `RESULT: FAIL` → vitaGL needs GLSL ES 1.00 → Phase 1B (file the `shady` request /
    hand-write GLES2 shaders).
- VAO availability at runtime (spike probes `glGenVertexArrays` + `glGetError`).
- Real-hardware run (gold standard; Vita3K hides `-Wl,-q` + `libshacccg.suprx` issues).

## 2026-06-07 — First hardware run: CRASH in vitaGL's GLSL preprocessor

Ran `vita_shader_spike.vpk` on real hardware. It **crashed** (no green/red screen, no
`ux0:data/boxy_vita_shader_spike.txt` written → died before the end-of-main file write).

### Core dump symbolicated (the actual finding)

Dump: `ux0:data/psp2core-…-eboot.bin.psp2dmp` (gzipped ELF32 ARM core). The app loaded
at its **link base** `0x81000000` (no ASLR offset), so core addresses map 1:1 to the
unstripped ELF. Crashing main thread (`BOXY00001`, tid 0x40010003):

- `PC = 0xe009f064` — libc `memcpy`/`malloc` in a system module
- `LR = 0x8103b855` → `addr2line` → **`preprocessor::expand(...)` at
  `/tmp/vitaGL/source/utils/preprocessor/preprocessor.cpp:880`**, inline chain
  `std::string::_M_construct → _S_copy → memcpy` building a `Token`.

**Diagnosis:** the spike reached `glCompileShader` on boxy's FIRST shader (the atlas
vertex shader) — i.e. `vglInit`, the four `glGetString` queries, and the VAO probe all
succeeded. vitaGL's **own C++ GLSL preprocessor** (statically linked from
`libvitaGL.a`, runs *before* the SceShaccCg/vitashark compiler) then faulted with a
bad-length `memcpy` while tokenizing the source. The shader fed is trivial, well-formed
GLES 3.00 (`#version 300 es` / `precision highp float;` / `in`/`out`, no `#define`):

```glsl
#version 300 es
precision highp float;
uniform mat4 proj;
in vec2 vertexPos; in vec2 vertexUv; in vec4 vertexColor;
out vec2 pos; out vec2 uv; out vec4 color;
void main() { pos=vertexPos; uv=vertexUv; color=vertexColor;
  gl_Position = proj * vec4(vertexPos.x, vertexPos.y, 0.0, 1.0); }
```

### Implication

The easy "**reuse the emscripten `300 es` shaders through vitaGL**" path (Phase 1A) is
**NOT viable as-is** with this vitaGL build — vitaGL crashes (rather than cleanly
erroring) on a valid `300 es` shader. Note: this is vitaGL's preprocessor, not the
missing-`libshacccg.suprx` failure mode (that's downstream). Whether GLSL ES **1.00**
fares better is the next question.

### Next experiment (built + on card): `vita_shader_probe.nim`

A breadcrumb probe that rewrites `ux0:data/boxy_vita_probe.txt` BEFORE each
`glCompileShader` (a native memcpy abort is uncatchable, so the file's last line names
the killer). It walks dialects trivial→complex: GLES1 minimal vert/frag, GLES1
attribute/varying, GLES3 minimal vert/frag, then boxy's real atlas vert/frag. Read the
file's stop-point:
- stops at 1–3 → even GLES2/`100` is broken on this vitaGL → precompiled-GXP path.
- stops at 4–5 → `300 es` unsupported; GLES1/`100` is the track (Phase 1B).
- reaches 6–7 → the real boxy shaders (not the dialect) are the trigger.
- all pass → environmental; re-test the spike.

`vita_shader_probe.vpk` is on the card root (sha `e329c03…`).

### Open routes depending on probe result

1. **GLSL ES 1.00 hand-written shaders** (`-d:vita`), if the probe shows `100` compiles.
2. **Precompiled shaders**: GLSL/Cg → `.gxp` offline (vitasdk `psp2cgc`/shacccg),
   loaded via `glShaderBinary`, bypassing vitaGL's runtime preprocessor entirely.
   Most robust; more build machinery; boxy's shaders come from shady so this needs an
   offline emit step.
3. Verify `ur0:data/libshacccg.suprx` is actually deployed (ShaRKF00D installs it) —
   necessary for any runtime GLSL path even if not the cause of *this* crash.

## 2026-06-07 — Probe run #1: `300 es` WORKS; crash is a specific shader, not the dialect

`vita_shader_probe.txt` came back **ALL 7 PASS** — including boxy's real atlasVert (#6)
and atlasMain (#7) at `300 es`. No crash, no new core dump.

**Correction to the earlier diagnosis:** the spike's marker is written only at the *end*
of main, so "crashed on the first shader" was an over-read — the crash could be any
shader in its 7-program compile+link sequence. The probe only exercised boxy's two
**simplest** real shaders (atlas vert/frag) and did **no linking**. It never compiled
the complex ones the spike also builds: `maskMain`, **`blendingMain` (~4.6 KB)**,
`blurX/Y`, `spreadX/Y`. The crash is in one of those, or in `glLinkProgram` — not in
the `300 es` dialect (which is now proven to compile).

### Probe #2 (built, on card — sha 7d1ff9b…)

Comprehensive: compiles the shared `atlasVert` once, then for **every** real boxy
fragment shader (atlas, mask, blend, blurX, blurY, spreadX, spreadY) does compile +
`glLinkProgram`, breadcrumbing before each. The last line in `boxy_vita_probe.txt`
names the exact shader/stage that crashes vitaGL — or `ALL REAL SHADERS PASS` →
reuse path (Phase 1A) is GO.

## 2026-06-07 — Probe run #2: crash is at `glLinkProgram`, not compile

`boxy_vita_probe.txt` last line: `START 1/7 LINK atlas`. Both `atlasVert` and `atlasMain`
**compiled `ok=true`**; the crash is the **first `glLinkProgram`**. New core
(`psp2core-…0b2ee5…`): `PC = r12 = 0xe0094bb4` — an indirect `blx r12` into a system
module that faulted (LR clobbered to a `.LC4`/dtoa constant, so the register frame is
unreliable; the breadcrumb is the source of truth).

**Reframe:** in vitaGL the GLSL→GXM translation (`glLinkProgram → glsl_translate_with_shader_pair
→ preprocessor`) happens at **link time**, not compile time — which is why probe #1
(compile-only) survived and probe #2 (which links) crashed at the first link.

### Environment cross-checked against the raylib hardware journal

`~/git/raylib-nim-multiplatform/.agents/docs/vita-debugging/README.md`:
- This boxy build links the user's **custom `/tmp/vitaGL`** (ELF debug paths prove it),
  which uses full **`shark_init`** (confirmed: `nm libvitaGL.a` → `U shark_init`, not
  `shark_init_simple`). So the `HAVE_VITA3K_SUPPORT` half-init bug (#6) is NOT in play.
- `libshacccg.suprx` on `ux0:data/` is the canonical known-good file (SHA256
  `188adb8c…`, `SCE\0` magic). Journal #5 says it must live at `ur0:data/` +
  `ur0:data/external/`; raylib already got shaders healthy on this device, so `ur0:` is
  presumably already populated.
- **The remaining difference:** raylib feeds vitaGL **GLSL ES 1.00** (`1.00 ES`); boxy
  feeds **`300 es`**. Hypothesis: SceShaccCg's link-time translate crashes on `300 es`
  even though compile returns ok.

### Probe #3 (built, on card — sha 7bae659…): the decisive link discriminator

Links a **minimal `#version 100`** program, then a **minimal `#version 300 es`**
program, then boxy's real shaders — breadcrumbing before each link. Stop point decides
the track:
- crash at **min-100 link** → link-time translate broken for everything → environment
  (libshacccg/`ur0:` placement), not the dialect.
- min-100 ok, crash at **min-300es link** → **`300 es` link unsupported → rewrite boxy
  shaders to GLES2/`100` (Phase 1B)**. shady can't emit `100` (only ES3/desktop), so this
  means the `shady` request and/or hand-written GLES2 sources.
- both minimal ok, crash in **boxy loop** → specific boxy shader content, not the dialect.

## 2026-06-07 — VERDICT: `300 es` link crashes vitaGL; GLSL ES 1.00 is the track (Phase 1B)

Probe #3 breadcrumb (decisive A/B):

```
min-100   link: ok=true          <- GLSL ES 1.00 program compiles AND links
START linkProbe min-300es: LINK  <- CRASHED here (last line)
```

**Definitive:** vitaGL's link-time GLSL→GXM translation (SceShaccCg) **crashes on
`#version 300 es`** but **links `#version 100` cleanly**. This is independent of shader
content (both were minimal). It matches the raylib setup, which runs `1.00 ES`.

→ **boxy must ship GLSL ES 1.00 (GLES2) shaders on Vita.** The "reuse emscripten
`300 es`" path (Phase 1A) is dead on this vitaGL.

### Consequence for shady

`shady.toGLSL` can only emit `glslES3` ("300 es") or `glslDesktop` — **no GLSL ES 1.00**.
So Phase 1B requires either the **`shady` dep request** (add a `glslES1` target) or
**hand-written GLES2 shader strings** for boxy's `-d:vita` path. The hand-written route
is bounded: boxy has a fixed 8-shader set, the conversion rules are mechanical
(`in`→`attribute`/`varying`, `out`→`varying`/`gl_FragColor`, `texture()`→`texture2D()`,
`#version 300 es`→`100`). Caveat: the simple shaders (atlas, mask, blur, spread) convert
trivially; `blendingMain` (~4.6 KB) likely uses GLES3-only constructs (e.g. `switch`,
integer ops) that need real rewriting for GLES2 — but a basic `drawImage` only needs the
atlas shader, so Phase 1B can land incrementally.

### Probe #4 (built, on card — sha a10eab6…): proves the GLES2 path on boxy's real shaders

Links, in order: minimal `100`, **boxy atlasVert+atlasMain hand-converted to `100`**,
**boxy atlasVert+maskMain converted to `100`**, then minimal `300 es` as a negative
control (expected to crash last). If the three `100` link lines are `ok=true`, the
GLES2 track is proven viable for boxy's actual shaders and Phase 1B is GO.

## 2026-06-07 — shady fork integrated (`glslES1` target); probe #5 built

`github.com/birbparty/shady` PR #3 (`2550b934`) landed a `glslES1` target. Verified on
host that `toGLSL(atlasVert/atlasMain/maskMain, glslES1)` produces correct GLSL ES 1.00
(stage-aware `attribute`/`varying`, `gl_FragColor` rewrite, `texture2D`, `#version 100` +
`precision mediump float;`) — equivalent to the hand conversions that already linked on
hardware. Pinned in `boxy.nimble`; stale upstream shady removed from the nimble cache so
the fork wins resolution.

**Probe #5** (`vita_shader_probe.nim`, sha 4fbfbde…): same link harness, but boxy's atlas
+ mask shaders now come from **shady's real `glslES1` output** (not hand-written). Pending
a device run (card was unmounted at build time) to confirm the fork's output links on the
Vita. After that confirms, the next step is the real boxy `-d:vita` integration:
generate the Vita shader set via `glslES1` under a shared guard, then stand up
`examples/basic_vita.nim` with `newBoxy`/`drawImage`.

## 2026-06-07 — Probe #5 PASS: shady `glslES1` confirmed end-to-end on hardware

Breadcrumb: `min-100 link ok` → **`boxy-atlas-shadyES1 link ok`** → **`boxy-mask-shadyES1
link ok`** → then the `min-300es` negative control crashed (the core dump — expected).
So **shady PR #3's `glslES1` output links boxy's real atlas + mask shaders on a physical
Vita.** Probing phase complete.

### boxy shader × glslES1 compatibility matrix (host `toGLSL(x, glslES1)`)

| shader | glslES1 | note |
|--------|---------|------|
| atlasMain   | ✅ | links on hardware (probe #5) |
| maskMain    | ✅ | links on hardware (probe #5) |
| blendingMain| ✅ | compiles (4.6 KB) — no `switch`/int after all |
| spreadXMain | ✅ | compiles |
| spreadYMain | ✅ | compiles |
| **blurXMain** | ❌ | uniform loop bound `for x in floor(-r).int..ceil(r).int` (`r`←`blurRadius`); GLSL ES 1.00 needs **constant** bounds — shady fail-errors (correct) |
| **blurYMain** | ❌ | same uniform-loop issue |

→ Integration: 5/7 shaders go through `glslES1` unchanged. **blur (X/Y) needs an
author-side rewrite** (constant `MAX_RADIUS` loop + runtime `if (i > r) break;`) on the
`-d:vita` path, or be disabled on Vita until reworked. A basic `drawImage` needs only the
atlas shader, so blur can be deferred.

## 2026-06-07 — boxy `-d:vita` integration built (basic_vita.vpk); first render pending

Implemented the real Vita path (decision: full blur parity):
- `src/boxy/blurs.nim`: added `blurXMainEs1`/`blurYMainEs1` — constant `MaxBlurRadius=64`
  loop + early `break` + `floor(x+0.5)` (round is ES3+); symmetric sampling = same taps
  as the uniform-loop originals. Both verified to emit valid GLSL ES 1.00 (shady emits a
  real bounded `for` loop, not an unroll).
- `src/boxy.nim`: added `elif defined(vita):` shader branch building all 7 shaders via
  `toGLSL(x, glslES1)` (atlas/mask/blend/spreadX/Y direct; blurX/Y via the Es1 variants).
- generalized two emscripten-only guards to also cover vita: `readImage`
  (`textures.nim`, no `glGetTexImage` in GLES) and the `tmp/atlas.png` debug dump
  (`boxy.nim`).
- `src/boxy/shaders.nim`: guarded the integer-attribute branch (`glVertexAttribIPointer`,
  GLES3-only) under `-d:vita` — dead code for boxy (all attributes are float/normalized),
  was the only GLES3 symbol the link actually needed.
- `examples/basic_vita.nim`: `vglInit` → `newBoxy` (links all 7 ES1 shaders on device) →
  `addImage` (procedural pixie sprite) → `drawImage` loop; SceCtrl START to exit;
  breadcrumbs to `ux0:data/boxy_vita_basic.txt`.

**Verified (host):** boxy still compiles **without** `-d:vita` (desktop additive-invariant
holds); `basic_vita.vpk` builds clean (sha 028e6cb…) and `vita-elf-create` passes.

**Pending (next hardware run):** install `basic_vita.vpk` (TITLE_ID BOXY00001 — replaces
the probe app) and confirm a sprite renders. `newBoxy` linking all 7 shaders is also the
on-device link test for blend/spread/blur (only atlas+mask were link-verified before).
Read `ux0:data/boxy_vita_basic.txt`: reaching "frame 1 presented OK" = the full
newBoxy→addImage→drawImage→swap pipeline works on real hardware.

## 2026-06-07 — basic_vita crash localized to `spreadX`; fixed (Es1 spread variants)

basic_vita crashed in `newBoxy`. Symbolicated: `std::_Rb_tree_increment` + vitaGL
`custom_shaders.c` → a `glLinkProgram` during shader build. The all-7-link probe (run
#6) breadcrumb pinpointed it: atlas ✓, mask ✓, **blend ✓** (the 4.6 KB one links!),
blurX ✓, blurY ✓ (the Es1 variants link), **spreadX → LINK CRASH**.

**Root cause:** `spreadXMain`/`spreadYMain` loop on a *uniform* radius
(`for x in floor(-r).int..ceil(r).int`, `r = radius`) — same invalid-ES1 uniform loop
bound as blur. But **shady's `glslES1` did NOT reject it** (unlike blur, which it caught
via the `round` error) — it silently emitted a uniform-bounded `for`, and vitaGL's
SceShaccCg crashes linking it. **This is a shady gap** (it should `err()` on non-constant
loop bounds, per the request's fail-loud principle, but misses the spread case).

**Fix:** added `spreadXMainEs1`/`spreadYMainEs1` (`src/boxy/spreads.nim`) — constant
`MaxSpreadRadius=64` loop + `break`, symmetric (0, ±x) max/min, equivalent window. Wired
into `newBoxy`'s `-d:vita` branch. Verified they emit a constant-bound `for` loop. So all
7 boxy shaders now have a link-clean glslES1 path (atlas/mask/blend direct; blur/spread
via Es1 constant-loop variants). Follow-up worth filing on the shady fork: catch
non-constant loop bounds under `glslES1`.

`basic_vita.vpk` rebuilt (sha 7e30824…). Next hardware run should clear `newBoxy` and
render — read `ux0:data/boxy_vita_basic.txt` for "frame 1 presented OK".

## 2026-06-07 — boxy RENDERS CORRECTLY on Vita (readback proof); blank = vitaGL scanout

`basic_vita` with a `glReadPixels` readback, on real hardware:
```
frame 1 readback center(480,272) RGBA=240,220,40,255  corner(5,5)=0,0,0,0  glErr=0
120 frames presented OK (steady state)
START pressed; exiting at frame 306
```
center pixel = the sprite's yellow square (`240,220,40`), corner empty, no GL error.
**boxy's full pipeline renders pixel-correct on the Vita** — the port is functionally
complete (addImage→drawImage→atlas→all 7 glslES1 shaders, clean exit via START).

**The black screen is NOT boxy — it is vitaGL's hardware scanout** (frames render to the
framebuffer correctly but don't reach the panel). This is the exact issue documented in
`~/git/raylib-nim-multiplatform/.agents/docs/vita-debugging/README.md`: on real hardware,
vitaGL's display framebuffers must be **dedicated/base CDRAM memblocks**, not suballocated
inside a larger pool, or `sceDisplaySetFrameBuf` is rejected and the panel stays black
(Vita3K hides this — it "presents loosely"). The sysroot `libvitaGL.a` boxy links is
un-patched for this.

### Fix (vitaGL-level, not boxy)

Build vitaGL with the `gxm.c` `init_display_color_surfaces` dedicated-CDRAM-memblock
patch from the raylib journal, install/link it, and relink boxy. boxy itself needs no
further change — its readback is already correct.

## 2026-06-07 — black-screen candidate fix: proven vitaGL init (reserve CDRAM for display)

Found the likely cause in `~/git/clicky/docs/vitagl/` (hardware-lessons.md): the
sysroot `libvitaGL.a` IS the patched build (has `display_fb` dedicated-CDRAM memblock),
but boxy initialized it with `vglInit(0x800000)` — a **legacy pool that starves the CDRAM
the dedicated display memblocks need**, so display alloc falls back to suballocation and
`sceDisplaySetFrameBuf` rejects it → black, even though rendering is correct (our readback
proved render is correct). The proven-on-hardware init reserves that CDRAM:
```
vglSetSemanticBindingMode(VGL_MODE_POSTPONED)
vglSetDisplayBufferCount(2)
vglInitWithCustomThreshold(0, 960, 544, 8MiB, 8MiB, 0, 26MiB, SCE_GXM_MULTISAMPLE_NONE)
```
`examples/basic_vita.nim` updated to this (it's the caller's job — boxy core unchanged).
basic_vita.vpk sha 38dc0e4…. Pending hardware run: expect the sprite to actually display.

## 2026-06-07 — ISOLATED: the black screen is sysroot vitaGL, NOT boxy

- `display fb: base=0x00000000 w=0 h=0 getRet=0x0` — after 408 swaps, vitaGL never set
  any display framebuffer (not a suballocated-vs-dedicated CDRAM issue; nothing is set).
- `examples/vita_clear.nim` — a **minimal raw-vitaGL** test (no boxy: `vglInit` +
  `glClear(red)` + `vglSwapBuffers`) — is **also black** on hardware.

**Conclusion:** the sysroot `libvitaGL.a` cannot drive the Vita display, independent of
boxy. boxy's Vita port is proven correct (pixel-accurate readback). The remaining blocker
is entirely vitaGL-level — almost certainly a stock `vdpm` vitaGL overwrote the
CDRAM-display-patched build from the clicky/raylib work (per
`~/git/clicky/docs/vitagl/build-chain.md`, which `sudo make install`s a source-patched
vitaGL).

**boxy status: DONE.** No further boxy changes needed for rendering. Remaining work is a
vitaGL rebuild (not a boxy task):
1. Rebuild vitaGL from source with the `gxm.c` dedicated-CDRAM display-memblock patch,
   NO `HAVE_VITA3K_SUPPORT`; `sudo make install` to the sysroot. (Recipe:
   clicky/docs/vitagl/build-chain.md + hardware-lessons.md.)
2. Rebuild + reinstall boxy's `basic_vita.vpk` (links the fixed vitaGL); the existing
   readback + display-probe will then show a real framebuffer base and the sprite.

Note: the physical memory card is reportedly failing — the journal's **FTP hot-swap
workflow** (`scripts/vita_ftp.py` in raylib-nim) pushes `eboot.bin` to the installed app
dir over WiFi and avoids the card entirely; worth switching to.

## 2026-06-07 — patched vitaGL rebuilt + linked into boxy

Rebuilt vitaGL from source (Rinnegatamante/vitaGL @ HEAD) with the dedicated-CDRAM
display-memblock patch in `source/gxm.c` `init_display_color_surfaces` (allocate each
display buffer via `sceKernelAllocMemBlock(SCE_KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW)` +
`sceGxmMapMemory`, pool alloc as fallback). Built `NO_DEBUG=1 NO_SPLASHSCREEN=1`, no
`HAVE_VITA3K_SUPPORT`. Output `/tmp/vitaGL/libvitaGL.a`.

boxy links it via a TEMP `--passL:"-L/tmp/vitaGL"` prepended in `nim_vita.cfg` (before the
sysroot -L) — no sudo, reversible. Verified: `basic_vita` eboot contains
`gxm_color_surface_memblocks` (the patched symbol). `basic_vita.vpk` sha 1761ab0….

Pending hardware run: expect the sprite to display and the `display fb:` probe to report a
real dedicated-CDRAM base (e.g. `0x6x000000`) instead of `base=0`. Once confirmed, fold
the patched vitaGL into the sysroot (`sudo cp` per clicky/docs/vitagl/build-chain.md) and
drop the TEMP -L line.

## Artifacts added

- `nim_vita.cfg`, `examples/vita_shader_spike.nim`, `scripts/build_vita.sh`,
  `scripts/run_vita.sh`, `.gitignore` Vita entries.
- Fork: `birbparty/opengl` @ vita branch, version bumped to 1.2.10 locally
  (commit + push the bump so other clones resolve deterministically).

### How to run the spike

```bash
cd ~/git/opengl && nimble install -y          # fork (1.2.10) wins resolution
cd <boxy>
scripts/build_vita.sh examples/vita_shader_spike.nim
scripts/run_vita.sh   examples/vita_shader_spike.nim   # Vita3K, then real hardware
# read ux0:data/boxy_vita_shader_spike.txt for the verdict
```
