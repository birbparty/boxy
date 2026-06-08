# Dependency Requests — boxy Vita support

Two of boxy's dependencies do not handle Vita. Following the request pattern in
`~/.agents/projects/<dep>/requests/`, we file upstream asks AND give each an interim
workaround so the port is never blocked waiting on upstream (mirrors the 3DS branch's
windy-bypass precedent).

---

## 1. `opengl` — Vita must link GL statically (REQUIRED regardless of Phase 0)

> **STATUS: FIXED in fork (2026-06-07).** `github.com/birbparty/opengl` @ `43ad61a`
> (branch HEAD `2764b23`) adds `or defined(vita)` to the static-link branch
> (`src/opengl/private/prelude.nim:35`). Local checkout: `~/git/opengl`. The fork is a
> strict superset of upstream `8e2e098` (1-line additive change), so it is safe to use
> for all boxy builds, not just Vita. **Still TODO:** open the PR to `nim-lang/opengl`
> upstream (the ask below) and drop the fork once merged.
>
> **How boxy consumes it (interim):** pin the fork in `boxy.nimble` —
> `requires "https://github.com/birbparty/opengl#43ad61a"` (safe globally since the
> change only adds a `-d:vita` branch). Alternatively, scope it to the Vita build only
> with `--path:"<path>/opengl/src"` in `scripts/build_vita.sh`. Prefer the nimble pin
> for reproducibility; remove it when upstream merges.


**Problem.** `opengl/private/prelude.nim` decides how GL procs are bound:

```nim
elif defined(android) or defined(js) or defined(emscripten) or defined(wasm):
  {.pragma: ogl.}            # empty → direct static importc externs
  {.pragma: oglx.}
else:
  import dynlib              # runtime loadLib(libGL) + glGetProc — desktop only
  ...
```

Vita has no `-d:vita` case, so it falls into the `else` branch and tries to
`loadLib("libGL.so.1")` at startup — which does not exist on Vita. vitaGL provides
the `gl*` symbols **statically**, so Vita needs the *empty `ogl` pragma* branch that
emscripten already uses.

**The ask (one line).** Add `vita` to the static branch:

```nim
elif defined(android) or defined(js) or defined(emscripten) or defined(wasm) or defined(vita):
```

**Interim workaround (so we don't block on upstream).** Vendor a patched copy of
`opengl` and point boxy's Vita build at it via a local nimble path override
(`--path:` to a vendored `opengl/` with the one-line change), exactly the
"bypass the unbuildable dep" move the 3DS branch used for windy. Drop the override
once upstream merges.

**Filed:** `~/.agents/projects/opengl/requests/2026-06-07-vita-static-gl-linking.md`

---

## 2. `shady` — GLSL ES 1.00 output (IMPLEMENTED in fork; pinned)

> **STATUS: IMPLEMENTED (2026-06-07).** The request was acted on:
> `github.com/birbparty/shady` **PR #3** (branch `matt.spurlin/retro-targets`, head
> `2550b934`) adds a **`glslES1`** target (= `glsl1WebGL`) plus the 3DS/PICA200 targets.
> It implements exactly what the reviewed request asked: stage-aware
> `attribute`/`varying`, user frag-output → `gl_FragColor` rewrite, `texture()`→
> `texture2D()`, `#version 100` + mandatory `precision mediump float;`, `"100"`/`"100 es"`
> version-string routing, and **fail-loud `err()`s** on ES1-illegal constructs
> (`switch`/`case`, integer/bitwise ops, shadow/`texelFetch`/`textureGrad` samplers,
> integer & array/struct varyings, `gl_FragData[i]`).
>
> **Verified (host):** `toGLSL(atlasVert/atlasMain/maskMain, glslES1)` emits correct GLSL
> ES 1.00 — byte-equivalent to the hand conversions already proven to link on hardware.
>
> **Pinned:** `boxy.nimble` → `requires "https://github.com/birbparty/shady#2550b934…"`.
> Local resolution made deterministic by removing the stale upstream `shady-0.1.5`
> from the nimble cache (the fork is a superset). Revert to a version range once the PR
> merges and a release is tagged.
>
> Original request (folded-in review findings):
> `~/.agents/projects/shady/requests/2026-06-07-glsl-es-100-target.md`.

**Problem.** `shady.nim:992` chooses the dialect from the version string:

```nim
glslTarget = if "es" in version.strVal: glslES3 else: glslDesktop
```

There are exactly two modes. There is **no GLSL ES 1.00 target**. Passing `"100"`
contains no `"es"`, so shady emits *desktop* syntax (`in`/`out`/`texture()`,
no `precision`) under `#version 100` — invalid GLES2 (which needs
`attribute`/`varying`/`gl_FragColor`/`texture2D()`). So boxy cannot get a valid
GLES2 shader out of shady today.

**The ask.** Add a `glslES1` target to `toGLSL` (emit `attribute`/`varying`/
`gl_FragColor`, rewrite `texture()`→`texture2D()`, default-precision header),
selected when the version is `"100"`/`"100 es"`.

**Interim workaround.** Don't block on shady. boxy's shader set is small and fixed
(atlas, mask, blend, blurX/Y, spreadX/Y). Hand-write GLSL ES 1.00 `.vert/.frag`
strings for the `-d:vita` path and feed them to the existing
`newShader((name, source), …)` overload (boxy already accepts raw GLSL strings — the
emscripten path just happens to get them from `toGLSL`). The Vita shader sources live
beside the shaders module and are selected under `when defined(vita)`.

**Filed (DRAFT — promote after Phase 0 confirms it's needed):**
`~/.agents/projects/shady/requests/2026-06-07-glsl-es-100-target.md`

---

## Not requested

- **`windy`** — boxy `src/` never imports it; the Vita example creates its context
  with `vglInit` directly. No change needed (the `examples/basic_windy.nim` family
  simply isn't built for Vita, same as the 3DS branch).
- **`pixie` / `nimsimd` / `zippy`** — expected to cross-compile under arm-vita-eabi
  (the 3DS branch proved them on armv6k). Treated as a *verification gate*
  (Phase 2), not a code change. File a request only if the link actually fails.
- **Vita input (`SceCtrl`)** — not a boxy concern. A consumer needing unified input
  would request an `inputty` Vita backend, paralleling the existing 3DS `inputty`
  request — out of scope for boxy itself.
