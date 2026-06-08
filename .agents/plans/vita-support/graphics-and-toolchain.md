# Vita Graphics & Toolchain — boxy specifics

This is the boxy-specific companion to `plan.md`. configy's `verification-gate.md`
covers the *file-I/O* console story; boxy is a *renderer*, so the load-bearing parts
here are the **vitaGL graphics stack** and the **GL link chain** that configy never
needed.

---

## The graphics stack (how boxy's GL reaches the screen)

```
boxy (OpenGL 2D atlas renderer, src/boxy.nim + src/boxy/*.nim)
   │  standard gl* calls via the `opengl` Nim module
   ▼
vitaGL            OpenGL ES implementation (the gl* symbols boxy links against)
   ▼
sceGxm            Vita GPU middleware (vitaGL's backend; boxy never touches it)
   ▼
PowerVR SGX543MP4+ (the Vita GPU)
```

Key consequences:

- boxy writes **no GXM code**. It keeps calling `glGenFramebuffers`, `glDrawArrays`,
  etc. vitaGL maps them to sceGxm. This is exactly why Vita is an emscripten-class
  port and not a 3DS-class rewrite.
- vitaGL **statically links** its `gl*` symbols (it's `libvitaGL.a`). So boxy must
  bind GL as direct `importc` externs — *not* via `dlopen`. That is the `opengl`
  module change (see `dependency-requests.md`): Vita must take the same empty-`ogl`
  pragma branch emscripten already takes.
- vitaGL JIT-compiles GLSL at runtime via **`libshacccg.suprx`**. On real hardware
  this file must exist at `ur0:data/libshacccg.suprx` (and/or
  `ur0:data/external/libshacccg.suprx`). Vita3K supplies its own compiler and hides
  this — a hardware-only prerequisite.
- Context creation is `vglInit*()` (or vitaGL via SDL2). The Vita **example** owns
  this; boxy's `src/` does not.

### The GLSL pivot (see plan.md Phase 0)

vitaGL's accepted GLSL dialect decides the port shape. shady can only emit
`glslDesktop` or `glslES3` (`shady.nim:992`). So:

- If vitaGL takes `300 es` (GLES3-style) → reuse boxy's emscripten shader output.
- If vitaGL only takes `100` (GLES2-style) → shady can't help; hand-write GLES2
  shader strings for the `-d:vita` path or extend shady (dep request).

Resolve by spike before writing `nim_vita.cfg`'s final form.

---

## `nim_vita.cfg` (draft — adapt after Phase 0)

Combines configy's Vita toolchain block (cpu/os, `-Wl,-q`, librt stub, console mm
flags) with raylib's vitaGL link chain (the graphics libs configy omitted). Trim the
stub list to what boxy actually pulls (boxy is graphics + libc, not SDL2-audio-net —
some raylib stubs are unnecessary; add-on-unresolved-symbol is the discipline).

```ini
# nim_vita.cfg — Sony PS Vita (VitaSDK + vitaGL). Copied to nim.cfg by
# scripts/build_vita.sh so Nim auto-discovers it. Do NOT edit nim.cfg directly.
#
# boxy reaches the GPU through vitaGL (OpenGL ES over sceGxm). Unlike configy
# (graphics-free), boxy links the vitaGL graphics chain below.

cc = "gcc"
arm.linux.gcc.path      = "/usr/local/vitasdk/bin"
arm.linux.gcc.exe       = "arm-vita-eabi-gcc"
arm.linux.gcc.linkerexe = "arm-vita-eabi-gcc"

--cpu:arm
--os:linux
# arm-vita-eabi-gcc already defaults to armv7-a+neon/hard-float — do NOT add the
# 3DS armv6k/mpcore flags here.

# Console runtime/memory profile (same set configy/raylib use).
--mm:arc
--threads:off
--define:useMalloc
--define:nimAllocPagesViaMalloc
--define:noSignalHandler
--opt:size

# MANDATORY: vita-elf-create consumes these retained relocations to emit SCE
# relocations. Without -Wl,-q the module data-aborts at a non-link load base on
# real hardware (Vita3K loads at the link base and HIDES this).
--passL:"-Wl,-q"

--passC:"-I/usr/local/vitasdk/arm-vita-eabi/include"
--passL:"-L/usr/local/vitasdk/arm-vita-eabi/lib"

# vitaGL graphics chain (installed via `vdpm install vitaGL`).
--passL:"-lvitaGL"
--passL:"-lvitashark"
--passL:"-lSceShaccCgExt"
--passL:"-ltaihen_stub"
--passL:"-lSceShaccCg_stub"
--passL:"-lmathneon"

# Vita system stubs boxy/vitaGL need (start minimal; append on unresolved symbols).
--passL:"-lSceGxm_stub -lSceDisplay_stub -lSceCtrl_stub"
--passL:"-lSceKernelDmacMgr_stub -lSceSysmodule_stub -lSceCommonDialog_stub"
--passL:"-lSceAppMgr_stub -lScePower_stub"

# libc/Sce IO + the C++ runtime vitaGL pulls in.
--passL:"-Wl,--start-group -lc -lm -lstdc++ -lSceLibKernel_stub -lSceIofilemgr_stub -Wl,--end-group"

# Nim injects -lrt for os:linux; Vita has no librt. build_vita.sh creates an empty
# librt.a stub in the build CWD; -L. puts it on the link path. (Vita ships a real
# libdl.a, so no libdl stub is needed — unlike 3DS.)
--passL:"-L."
```

> Notes:
> - **Trim aggressively** then add stubs back as the linker complains. The raylib cfg
>   links SDL2/audio/net/touch/motion stubs boxy does not need.
> - `-lstdc++` is required because vitaGL is C++.
> - If Phase 0 takes the `100` track, no cfg change — the shader *source* changes, not
>   the toolchain.

---

## `scripts/build_vita.sh` (draft pipeline)

Same skeleton as configy/raylib `build_vita.sh`. boxy compiles an **example** (it
needs a `main`/context), and bundles its asset png(s) so the example can `addImage`
from `app0:`.

```bash
#!/usr/bin/env bash
# boxy Vita build: nim -> ELF -> velf -> fself -> sfo -> .vpk
set -euo pipefail
cd "$(dirname "$0")/.."

export VITASDK="${VITASDK:-/usr/local/vitasdk}"
export PATH="$VITASDK/bin:$PATH"
GCC="$VITASDK/bin/arm-vita-eabi-gcc"
AR="$VITASDK/bin/arm-vita-eabi-ar"
SRC="${1:-examples/basic_vita.nim}"
BASE="$(basename "$SRC" .nim)"
TITLE_ID="${2:-BOXY00001}"

# Toolchain-absent ⇒ PASS-for-scope (exit 0), matching configy's gate.
if [[ ! -x "$GCC" ]] || ! command -v vita-elf-create >/dev/null 2>&1 \
   || ! command -v vita-pack-vpk >/dev/null 2>&1; then
  echo "[build_vita] VitaSDK not found — skipping (PASS for scope)."; exit 0
fi

cleanup() { rm -f nim.cfg librt.a "$BASE.velf" eboot.bin param.sfo; }
trap cleanup EXIT

cp nim_vita.cfg nim.cfg
"$AR" rcs librt.a                       # empty librt stub (Nim injects -lrt)

nim c -d:vita -d:release --out:"$BASE" "$SRC"

vita-elf-create "$BASE" "$BASE.velf"    # THE -Wl,-q gate
vita-make-fself "$BASE.velf" eboot.bin
vita-mksfoex -s "TITLE_ID=$TITLE_ID" "boxy $BASE" param.sfo

# Bundle eboot + sfo + assets into the .vpk (assets reachable at app0:)
rm -rf vpk_stage && mkdir -p vpk_stage/sce_sys vpk_stage/data
cp eboot.bin vpk_stage/
cp param.sfo vpk_stage/sce_sys/
[ -d data ] && cp -r data/* vpk_stage/data/ 2>/dev/null || true
( cd vpk_stage && zip -r "../$BASE.vpk" . ) && rm -rf vpk_stage
echo "[build_vita] Done: $BASE.vpk"
```

`scripts/run_vita.sh`: copy raylib's verbatim (Vita3K launch, build-if-missing).

---

## Verification gates (boxy-specific additions over configy)

| Gate | Signal | Where |
|------|--------|-------|
| Nim semantics | `nim check -d:vita examples/basic_vita.nim` clean | host, no toolchain |
| **Shader compile** | boxy's GLSL compiles+links under vitaGL | Phase 0 spike (decisive) |
| pixie stack | pixie/nimsimd/zippy cross-compile + link under arm-vita-eabi | Phase 2 |
| Reloc correctness | `vita-elf-create` succeeds | Phase 2 |
| Render | boxy draws the test image | Vita3K (Phase 3a) |
| **Hardware render** | render + no data-abort, `libshacccg.suprx` present | real Vita (Phase 3b, gold) |

---

## Vita3K-vs-hardware traps (inherited from raylib's debugging notes)

- `-Wl,-q` reloc bug: hidden by Vita3K (link-base load), fatal on hardware.
- `libshacccg.suprx`: needed on hardware, supplied internally by Vita3K.
- Display framebuffers must be dedicated CDRAM memblocks on hardware — vitaGL's
  concern, but if boxy ever does low-level buffer allocation, beware. (boxy does not;
  it stays at the GL API.)
- Always confirm on real hardware before claiming done.
