# Merge plan: 3ds-support → (branch off vita-support), PR vs master

## Goal
New branch `matt.spurlin/console-support` off `origin/matt.spurlin/vita-support`, merge
`origin/matt.spurlin/3ds-support` into it, resolve conflicts so **both `-d:ds3` and
`-d:vita` build** (and desktop/emscripten are unchanged), push, open a draft PR vs
`birbparty/boxy:master`.

## Context (verified)
- Merge base of the two branches = `f064ead` (current master tip). Both branch from master.
- 3ds-support is a large refactor: extracts a backend interface
  (`src/boxy/backends/{backend_interface,opengl_backend,citro3d_backend,render2d_pica}.nim`),
  adds `src/boxy/bindings/*`, `nim_3ds.cfg`, `scripts/build_3ds.sh`, `examples/*_3ds.nim`,
  `romfs/`, `tests/*`, docs — and **wraps the shared GL modules in `when not defined(ds3):`
  and re-indents them** (that's why the conflicts span whole files).
- vita-support is small/additive on top of master's monolithic files.
- devkitARM IS installed (`/opt/devkitpro/devkitARM/bin/arm-none-eabi-gcc`) → `-d:ds3`
  build is verifiable here. VitaSDK installed → `-d:vita` verifiable. Patched vitaGL at
  `~/git/vitaGL` (build_vita.sh injects its `-L`).

## Conflicted files (6) and resolution

Principle: **take the 3DS structure as the base** (it's the bigger refactor) and **re-apply
vita's small, targeted changes inside the `when not defined(ds3):` blocks**. The vita GL
path is a desktop-class GL target, so all vita shader/blur/spread code lives inside
`when not defined(ds3):` (NOT compiled on 3DS, which has its own citro3d backend).

### 1. `.gitignore` — union both
Keep the 3DS additions (`!.ralph`, `build/`, beads/dolt `.dolt/ *.db .beads-credential-key`,
`assets/`) AND the vita artifacts block (`nim.cfg *.vpk *.velf eboot.bin param.sfo librt.a
libdl.a`). Both are additive; just take both sides.

### 2. `src/boxy.nim` — 3DS base + 2 vita edits
The 3DS version keeps the same emscripten/`else` shader-build blocks as master (just
wrapped in `when not defined(ds3): proc newBoxy` and indented +1). Re-apply:
- **(a) vita shader branch:** insert an `elif defined(vita):` block between the
  `when defined(emscripten):` block and the `else:` (desktop `"410"`) block in `newBoxy`,
  emitting all 7 shaders via `toGLSL(x, glslES1)` — atlas/mask/blend/spreadX/spreadY direct,
  blurX/blurY via `blurXMainEs1`/`blurYMainEs1`, spreadX/Y via `spreadXMainEs1`/
  `spreadYMainEs1`. (Identical to the block already on vita-support, indented to match.)
- **(b) atlas-dump guard** (3DS line ~484): `when not defined(emscripten):` →
  `when not (defined(emscripten) or defined(vita)):`.
- Everything else: take 3DS (`theirs`).

### 3. `src/boxy/blurs.nim` — 3DS base + vita Es1 variants
3DS wraps the module in `when not defined(ds3):` (+indent). Add `blurXMainEs1` and
`blurYMainEs1` (constant `MaxBlurRadius=64` loop + early `break` + `floor(x+0.5)`) **inside**
that block, matching its indentation. (These are the GLSL-ES-1.00 variants; uniform-bounded
loops are illegal in ES1.)

### 4. `src/boxy/spreads.nim` — 3DS base + vita Es1 variants
Same: add `spreadXMainEs1`/`spreadYMainEs1` (constant `MaxSpreadRadius=64` + break) inside
the `when not defined(ds3):` block.

### 5. `src/boxy/shaders.nim` — 3DS base + vita integer-attrib guard
3DS wraps the whole module in `when not defined(ds3):`. At the integer-attribute branch
(3DS `bindAttrib`, the `glVertexAttribIPointer` call), wrap it:
`when defined(vita): raise newException(Exception, "integer vertex attributes are not
supported on Vita (GLES2)") else: glVertexAttribIPointer(...)`. (Dead code for boxy — all
attributes are float/normalized — but `glVertexAttribIPointer` is GLES3-only and would be an
unresolved symbol under vitaGL otherwise.)

### 6. `src/boxy/textures.nim` — 3DS base + vita readImage guard
3DS `readImage` uses `when defined(emscripten):`. Change to
`when defined(emscripten) or defined(vita):` and update the message to the GLES-generic one
("readImage is not supported on this GLES target (no glGetTexImage)").

## Non-conflicted, auto-merged (verify, don't hand-edit)
- `boxy.nimble`: must end with EXACTLY ONE shady requirement — the fork pin
  (`https://github.com/birbparty/shady#2550b934…`), plus the 3DS build note. **Verify no
  duplicate `requires "shady …"` line survived** (would break nimble resolution).
- `examples/config.nims`: 3DS edits auto-merge; confirm it still has both desktop and
  ds3/vita handling and compiles.
- All vita-only files (nim_vita.cfg, scripts/build_vita.sh, run_vita.sh, examples/*vita*,
  .agents/plans/*) are already on the branch base; 3DS-only files (backends/, bindings/,
  nim_3ds.cfg, build_3ds.sh, examples/*_3ds*, romfs/, tests/, docs/) come in clean.

## Verification gate (after resolving, before commit)
1. **Desktop:** `nim check --path:src src/boxy.nim` (no defines) → clean.
2. **Vita:** `scripts/build_vita.sh examples/basic_vita.nim` → `.vpk` builds, links patched
   vitaGL (eboot has `gxm_color_surface_memblocks`), `vita-elf-create` passes.
3. **3DS:** `scripts/build_3ds.sh examples/basic_3ds.nim` → `.3dsx` builds (devkitARM).
4. **shady ES1 still resolves:** the `elif defined(vita)` block compiles
   (`toGLSL(blurXMainEs1, glslES1)` etc.).
5. (Manual, deferred to user) re-run `basic_vita.vpk` on hardware as a regression check.

## Commit & PR
- Resolve, `git add` the 6 files, `git commit` (merge commit), push branch.
- Open **draft** PR vs `birbparty/boxy:master` titled for combined 3DS + Vita console
  support; body summarizes both ports + the dependency forks (opengl/shady/vitaGL).
- gh note: use `env -u GITHUB_TOKEN gh ...` (the active fine-grained PAT lacks PR create;
  the keyring `repo`-scoped token works).

## Review reconciliation (2 Opus passes) — applied

- **[HIGH] `tests/test_examples.nim` would break.** It (from 3DS) compiles every
  `examples/*.nim` except `*_3ds.nim` + 3 windowing ones — but NOT `*_vita.nim`/probes.
  `vita_clear.nim` has `{.error: "vita-only".}` without `-d:vita`, so the test aborts.
  **FIX (part of this merge):** extend its exclusion filter to also skip `*_vita.nim` and
  the `vita_shader_*`/`vita_clear` probes.
- **[MED] emscripten unverified** → add `nim check -d:emscripten --path:src examples/basic.nim`
  to the gate. (config.nims emscripten block is unchanged across branches — low risk, but check.)
- **[MED] ds3 gate must be `nim compile` via build_3ds.sh, NOT `nim check`** — `toPicaShbin`
  (`render2d_pica.nim`) uses staticExec+error() and gives false failures under `nim check`.
- **[LOW] consts move inside the guard:** `MaxBlurRadius`/`MaxSpreadRadius` are top-level on
  vita-support; on the merged tree they must move INSIDE `when not defined(ds3):` in
  blurs/spreads (with the Es1 procs).
- **Exact indentation** for the vita `elif` in 3DS boxy.nim: `elif` at 4 spaces, body at 6,
  continuations at 8 (match the emscripten/else siblings at lines ~255/285).
- **.gitignore is a real conflict** (manual union), not auto.
- **Cheap vita-regression check at resolve time:** `git diff origin/matt.spurlin/vita-support
  -- src/boxy/blurs.nim src/boxy/spreads.nim` and the boxy.nim `elif` region should be
  **indent-only** — proves vita shader codegen is byte-identical; the only new surface is the
  3DS-derived GL flush/draw/grow, covered by desktop `nim check` + `test_opengl_backend`.
- **Extra host gates:** compile `tests/test_render2d_pica.nim` under `-d:ds3` (citro3d ABI,
  no hardware) and run `tests/test_opengl_backend.nim` (desktop).
- **VitaSDK present** on this machine, so the vita build gate is non-vacuous (build_vita.sh
  exits 0 as "pass for scope" only when the toolchain is absent).
- **Merge (not rebase) confirmed correct** — merge-base is master tip, master hasn't moved.
- **Scope / PR hygiene:** the faithful merge carries 3DS milestone examples, romfs binaries,
  setup-beads-3ds.sh, AGENTS.md/CLAUDE.md, the vita probes, and `.agents/plans/`. The user
  explicitly asked to commit `.agents/plans/vita-support/` and to "merge 3ds-support in", so
  do a FAITHFUL merge (drop nothing) and SURFACE a trim list to the user as a follow-up
  rather than unilaterally excluding. Confirm CI (`.github/workflows`) won't run the
  (now-fixed) test against vita examples.

## Risks / watch-items
- boxy.nim indentation: the vita `elif` block must match the 3DS `+1` indent level exactly,
  or Nim's whitespace parsing breaks.
- Make sure the vita `elif` references symbols that exist in the merged tree
  (`glslES1`, `blurXMainEs1`, `spreadXMainEs1`) — they're added in steps 3/4.
- `.gitignore` `assets/` (3DS) vs any vita need — vita doesn't use `assets/`, fine.
- Don't accidentally drop 3DS's `readImage`/`bindAttrib` restructure when inserting guards.
