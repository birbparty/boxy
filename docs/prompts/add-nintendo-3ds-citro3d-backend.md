# Big Change Planning with Beads

## Agent Instructions

You are an expert software architect creating a comprehensive task breakdown for a change to an existing codebase. This task graph will be executed by AI agents working in parallel, coordinated through MCP Agent Mail with file reservations to prevent conflicts.

<quality_expectations>
Create a thorough, production-ready task graph. Include all necessary analysis, preparation, implementation, testing, and documentation tasks. Go beyond the basics — consider edge cases, error handling, security considerations, backwards compatibility, and integration points. Each task should be specific enough for an agent to execute independently without ambiguity.
</quality_expectations>

<critical_constraint>
You must NOT implement any of the changes yourself. Your ONLY output is a bash shell script containing `bd create` and `bd dep add` commands. Do NOT use `bd add` — the correct command is `bd create`. Do not write code. Do not create files other than the shell script. Do not modify existing files. Read and analyze the codebase, then produce the script.
</critical_constraint>

## Change Information

### Change Type
NEW_FEATURE

### Description
Add Nintendo 3DS as a new platform backend in boxy alongside existing OpenGL targets (macOS, Windows, Linux, Emscripten). Implement a citro3d path for the PICA200 GPU using `when defined(ds3):` conditionals throughout the core library. This is a **partial API port**: the full public Boxy API is preserved on all existing platforms; on 3DS a documented subset is supported (see PICA200 Constraints below for the specific blend modes and effects that are feasible vs. infeasible on this hardware).

Key facts about the target platform:
- GPU: DMP PICA200 (not OpenGL-compatible). No fragment shader — fragment processing uses the TEV (texture environment) unit configured via `C3D_TexEnv*` calls, not GLSL code.
- Only vertex shaders are user-programmable, written in PICA200 assembly (`.pica` files), compiled to `.shbin` by the picasso assembler.
- Rendering layer: **raw citro3d** (not citro2d) — this decision must be made and locked before any binding or backend work begins. citro2d is incompatible with boxy's architecture because it owns the vertex shader, resets TEV state per draw, and controls the coordinate system, which conflicts with boxy's atlas-UV addressing. Raw citro3d gives full control of the vertex shader, TEV, and draw calls needed to replicate boxy's batched quad pipeline.
- **`grow()` is a GPU FBO blit, not a CPU tile re-upload.** `boxy.nim:384–496` allocates a new atlas texture, attaches it to an FBO, and draws the old atlas into the new one via `drawUvRect`+`flush` — the CPU only renumbers tile indices. This means the atlas texture must be a **C3D color render target in VRAM** (`C3D_RenderTargetCreateFromTex`), not just a sampled texture. This roughly doubles the VRAM budget for the atlas (it must be both a render target and a sample source simultaneously). This is a key architectural constraint for the citro3d backend, not a routine "swizzle re-upload."
- Textures must be power-of-two dimensions in GPU_RGBA8 format, stored in Morton/Z-order tiled layout (not linear). **Critical sub-constraint:** boxy writes atlas tiles at offsets of `(index mod tileRun) * (tileSize + tileMargin)` — with `tileMargin` in the mix these offsets are almost never multiples of 8, but the PICA200 requires 8×8 Z-order swizzle alignment. Every sub-image upload requires re-swizzling into the tiled layout at the correct aligned offset; a simple memcpy will silently corrupt the atlas. The `growAtlas` full-repack path also needs swizzle-aware re-upload.
- No existing Nim bindings for citro3d — must be written from scratch using `{.importc.}` / `{.header.}` pragmas.
- Build toolchain: devkitPro/devkitARM (`arm-none-eabi-gcc`), with ARC GC (`--gc:arc`), malloc-based allocation, no signal handlers.
- **pixie/nimsimd/zippy cross-compilation is a hard prerequisite.** `src/boxy.nim:3` and `src/boxy/textures.nim` unconditionally import pixie; pixie depends on nimsimd which gates SIMD intrinsics on `when defined(amd64):`. This stack must cross-compile for ARMv6K under `arm-none-eabi-gcc` with ARC GC before any boxy image-loading code can run on 3DS. This is a blocking prerequisite that must be resolved before the backend implementation.
- Assets bundled in RomFS (`.romfs`), accessed via `romfs:/` prefix at runtime.
- Output format: `.3dsx` (ELF + metadata + RomFS, packaged by `3dsxtool`).
- Emulator: Azahar (macOS).

### Links to Relevant Documentation
- `/Users/punk1290/git/raylib-nim-multiplatform` — working 3DS Nim project; see `nim_3ds.cfg`, `scripts/build_3ds.sh`, `config.nims` for `defined(ds3)` patterns, and `src/bindings/raylib_console.nim` for FFI binding style
- `/Users/punk1290/git/clicky/docs/gaps-3ds.html` — gap analysis: 4 blockers, architectural constraints, path forward
- https://github.com/devkitPro/citro3d — citro3d C library (render targets, textures, vertex buffers)
- https://github.com/devkitPro/citro2d — citro2d C library (high-level 2D quad batching, built on citro3d)
- https://github.com/devkitPro/picasso — PICA200 vertex shader assembler; see Manual.md for `.pica` syntax
- https://github.com/rust3ds/citro3d-rs — best structural reference for wrapping citro3d in a non-C language
- https://github.com/skyforce77/ctrulib-nim — only existing Nim 3DS bindings (2015, abandoned, libctru only — reference only)

### Affected Areas
**Core source (all need `when defined(ds3):` conditionals):**
- `src/boxy.nim` — main renderer (1,176 lines): beginFrame/endFrame, atlas, layer system, quad batching. **Critical:** the `Boxy` type directly embeds `tmpFramebuffer: GLuint`, `layerFramebuffers: seq[GLuint]`, `vertexArrayId: GLuint` and GL-backed `Texture`/`Buffer`/`Shader` types (lines 32–62). These cannot be guarded with `when` in place — a backend interface / parallel type abstraction must be extracted first. Also: the top-level `import opengl, shady, pixie` (line 3) **and** `export atlasVert, atlasMain, maskMain` (line 6) and `export pixie` (line 8) must all be guarded together as a unit; `blends.nim` defines those exported symbols using shady DSL, so guarding the import while leaving the exports active will fail to compile. `enterRawOpenGLMode`/`exitRawOpenGLMode` (lines 338–358) are public GL-only procs that must be classified in the partial-API table (no-op or error on 3DS). Additionally the `atlasTexture.writeFile(...)` call in `grow()`'s error path at line 393–394 is currently guarded `when not defined(emscripten)` — must become `and not defined(ds3)`.
- `src/boxy/shaders.nim` — shader compilation (491 lines): skip OpenGL shader compile path on 3DS; `import opengl, shady` needs guarding at the import level. `shady` is a compile-time codegen dependency (`toGLSL(...)` runs in the Nim VM); guarding its import is more invasive than a single-line change — all shader-definition procs in blends.nim and shaders.nim that call shady DSL functions must also be conditionally compiled out.
- `src/boxy/blends.nim` — blend modes (201 lines): **only Normal, Multiply, Screen, and Add are achievable via fixed-function TEV combiners**. The remaining 11 modes require sampling `dstTexture` per-pixel — infeasible on PICA200. These must **no-op to Normal on 3DS** (documented). `MaskBlend` is a special case: `popLayer` at lines 710–724 handles it with `GL_ZERO, GL_SRC_COLOR` blending + the `maskShader` fragment program; MaskBlend must be explicitly classified (achievable via C3D fixed-function blend factors, but loses the maskShader — document the degraded behaviour).
- `src/boxy/blurs.nim` — Gaussian blur shaders (39 lines): **entirely infeasible on PICA200**. `blurEffect` must no-op on 3DS (documented). Note: `dropShadowEffect` (boxy.nim:887–954) drives blur shaders directly and is also infeasible.
- `src/boxy/spreads.nim` — alpha spread shaders (56 lines): **entirely infeasible on PICA200**. `spreadEffect` must no-op on 3DS (documented).
- `src/boxy/buffers.nim` — OpenGL vertex/index buffer management (54 lines)
- `src/boxy/textures.nim` — texture management (202 lines); imports pixie unconditionally — needs import guard. **Critical:** `Filter` and `Wrap` enum values are defined as GL constants (`filterNearest = GL_NEAREST`, `wRepeat = GL_REPEAT`, etc.) and `Texture` fields include `componentType, format, internalFormat: GLenum` (lines 6–23). Guarding `import opengl` here breaks these definitions — the backend interface must provide GL-free `Filter`, `Wrap`, and `Texture` type definitions. GPU readback procs `readImage` (lines 185–196) and `writeFile` (198–202) depend on `glGetTexImage` which has no citro3d equivalent — classify as no-op/unsupported on 3DS in the partial-API table. Same applies to `boxy.readAtlas` and `boxy.getImage`.

**New files (3DS-only):**
- `src/boxy/bindings/citro3d.nim` — Nim FFI for raw citro3d (C3D_Init, C3D_Tex, C3D_RenderTarget, C3D_DrawElements, C3D_TexEnv)
- `src/boxy/bindings/libctru_gfx.nim` — Nim FFI for libctru GFX (gfxInitDefault, gfxSwapBuffers, aptMainLoop)
- `src/boxy/backends/citro3d_backend.nim` — full 3DS renderer implementation
- `src/boxy/backends/backend_interface.nim` — **new**: platform-agnostic backend type/interface that both the OpenGL and citro3d paths satisfy; required before the existing core files can be conditionally split
- `shaders/render2d.v.pica` — PICA200 vertex shader for UV-mapped quads (position + UV + color attributes), compiled to `.shbin` by picasso and embedded in the build
- `nim_3ds.cfg` — Nim compiler config for devkitARM cross-compilation
- `scripts/build_3ds.sh` — complete build pipeline (nim compile → ELF → smdh → romfs → 3dsx)
- `examples/basic_3ds.nim` — minimal boxy example for 3DS

**Build infrastructure:**
- `boxy.nimble` — may need conditional deps for `ds3` target
- `config.nims` — add `ds3` target block (ARC GC, useMalloc, nimAllocPagesViaMalloc, noSignalHandler, opt:size)

### Success Criteria
The following milestones must be verified in order; each is a gate for the next:

1. **Toolchain gate**: A blank `.3dsx` (minimal Nim program — no boxy, no pixie, just `main()` that exits cleanly) compiles via the full pipeline (Nim → `arm-none-eabi-gcc` → `3dsxtool`) and launches to a non-crashing screen on Azahar. Confirms devkitPro is correctly wired.

2. **Bindings + link gate**: The citro3d Nim FFI (`src/boxy/bindings/citro3d.nim`) links successfully — a minimal `.3dsx` that calls `C3D_Init` / `C3D_Fini` and returns, with no graphics output required.

3. **Single quad gate**: A `.3dsx` renders a single hardcoded textured quad using a manually-uploaded, Morton-tiled, POT GPU_RGBA8 texture — **bypassing pixie and the atlas entirely**. This tests the swizzle/upload/TEV/draw path in isolation. Pixel output must be visually correct on Azahar.

4. **pixie cross-compilation gate**: The pixie + nimsimd + zippy stack cross-compiles for ARMv6K under devkitARM + ARC GC without errors. Confirmed by a `.3dsx` that calls `pixie.newImage(4, 4, rgbx(255,0,0,255))` and returns cleanly.

5. **Atlas + drawImage gate**: `examples/basic_3ds.nim` (newBoxy → addImage → drawImage) renders a visible image at 400×240 on Azahar with NormalBlend. The same source file compiles and displays correctly on macOS via the OpenGL path.

6. **RTT gate**: `pushLayer` / `popLayer` round-trips correctly on Azahar using **NormalBlend** (the only mode that exercises the full RTT path without requiring infeasible fragment shading). The test must explicitly use `blendMode=NormalBlend`; MaskBlend and ScreenBlend are separately verifiable if implemented.

7. **Regression gate**: All existing desktop examples (`basic_windy.nim`, `basic_glfw.nim`, `basic_sdl2.nim`) compile and run unchanged on macOS after all `when defined(ds3):` changes are applied.

### Constraints
- **Partial API parity only on 3DS.** The following boxy features must no-op with a documented warning on 3DS: blend modes other than Normal/Multiply/Screen/Add (MaskBlend is a special case — see blends.nim affected area); `blurEffect`; `spreadEffect`; `dropShadowEffect`; GPU readback procs (`readImage`, `getImage`, `readAtlas`, `writeFile`); `enterRawOpenGLMode`/`exitRawOpenGLMode`. All other platforms are unaffected.
- **pixie/nimsimd must cross-compile for ARMv6K** under devkitARM + ARC GC before image-loading works. If pixie cannot compile as-is, the fallback (raw RGBA without pixie) is more disruptive than "API shape": it disables the one-color tile optimisation, bordered tile splitting, and the entire CPU mipmap chain (meaning `drawImage`'s LOD selection has no mip levels to select from). This decision must be made against the real cost and documented explicitly before Phase 3 work begins.
- **Backend interface extraction is a strictly sequential prerequisite.** The interface must expose higher-level GPU operations (`blitAtlasToNewAtlas`, `compositeLayer(blendMode, tint)`, `beginAtlasTarget`/`endAtlasTarget`) — not just replace GLuint fields with getters. `grow()` and `popLayer()` interleave backend-agnostic bookkeeping with backend-specific GPU ops in ways that cannot be separated by field-wrapping alone.
- **The backend interface must define GL-free `Filter`, `Wrap`, and `Texture` types.** `src/boxy/textures.nim` lines 6–23 define enums with GL constant values and fields typed as `GLenum`. These break when `import opengl` is guarded. The backend interface must provide platform-agnostic versions of these types.
- **ARC/GC hazards.** (a) Temporary Nim seqs passed to citro3d GPU upload functions (e.g. `image.data[0].addr`) may be freed by ARC before async GPU DMA completes — use an explicit flush/sync or a retained staging buffer. (b) The `Boxy ↔ Backend` object graph must not create a reference cycle; ARC has no cycle collector (`--gc:orc` would be needed for cycles, but that's incompatible with this target). Design the backend interface to avoid back-references. (c) Confirm exception unwinding works under `noSignalHandler` + devkitARM + ARC — `BoxyError` is raised throughout and must not become a silent abort on 3DS.
- **citro2d is excluded.** The rendering layer is raw citro3d only (see Description for rationale).
- **windy must not be resolved for the 3DS target.** `boxy.nimble` unconditionally `requires "windy >= 0.4.4"` — a desktop windowing library that will not cross-compile for ARMv6K. The build pipeline must bypass nimble dependency resolution for windy (and examples that import it) when building for ds3.
- **`shbin` embedding decision must be explicit and gated.** The picasso `.pica → .shbin` step produces a binary blob that must be loaded at runtime via `DVLB_ParseFile`. The vertex shader's output register layout must exactly match the `C3D_AttrInfo` the citro3d backend configures — a mismatch produces silent vertex corruption. Gate 2 (bindings link) must include a `.shbin` load + `shaderProgramInit` call to verify this path before any draw calls.

---

## Your Task

Analyze this codebase change and create a comprehensive **Beads task graph** using the `bd` CLI. Beads provides dependency-aware, conflict-free task management for multi-agent execution.

Before creating the task graph, you MUST first analyze the affected areas of the codebase:

1. Check `docs/specs/` and `docs/adr/` for existing architectural decisions
2. Examine the directory/module structure of the affected areas listed above
3. Identify key interfaces, APIs, and integration points that must be preserved
4. Note existing test patterns and coverage in the affected areas
5. Assess risk areas where changes could break existing functionality

Use your analysis to make each bead specific — reference actual file paths, module names, and patterns you observed.

Then generate a shell script that creates the complete task graph.

**IMPORTANT: Your ONLY deliverable is a bash shell script with `bd create` commands. Not an implementation plan. Not a design document. Not a code review. A runnable `.sh` script.**

---

## Output Format

Generate a shell script that creates the full task graph. The script should:

1. **Initialize Beads** (if not already initialized)
2. **Create all beads** with appropriate priorities
3. **Establish dependencies** between beads
4. **Add labels** for phase grouping

### Example Output

```bash
#!/bin/bash
# Project: boxy
# Change: Add Nintendo 3DS citro3d backend
# Generated: 2026-05-29

set -e

# Initialize beads if needed
if [ ! -d ".beads" ]; then
    bd init
fi

echo "Creating change beads..."

# ========================================
# Phase 1: Analysis & Preparation
# ========================================

ANALYZE_CURRENT=$(bd create "Analyze current auth middleware implementation in src/auth/ — document all session token storage patterns and consumer dependencies" -p 0 --label analysis --silent)

IDENTIFY_DEPS=$(bd create "Map all modules importing from src/auth/ and catalog their usage patterns" -p 0 --label analysis --silent)

CHAR_TESTS=$(bd create "Add characterization tests capturing current auth middleware behavior before refactoring" -p 0 --label prep --silent)
bd dep add $CHAR_TESTS $ANALYZE_CURRENT

# ========================================
# Phase 2: Core Implementation
# ========================================

IMPL_NEW_STORAGE=$(bd create "Implement compliant session token storage in src/auth/session.ts replacing in-memory store" -p 0 --label impl --silent)
bd dep add $IMPL_NEW_STORAGE $CHAR_TESTS
bd dep add $IMPL_NEW_STORAGE $IDENTIFY_DEPS

IMPL_MIGRATION=$(bd create "Create migration script for existing session data to new storage format" -p 1 --label impl --silent)
bd dep add $IMPL_MIGRATION $IMPL_NEW_STORAGE

UPDATE_CONSUMERS=$(bd create "Update all consumer modules to use new auth middleware API surface" -p 1 --label impl --silent)
bd dep add $UPDATE_CONSUMERS $IMPL_NEW_STORAGE

# ========================================
# Phase 3: Testing & Validation
# ========================================

UNIT_TESTS=$(bd create "Add unit tests for new session storage implementation" -p 1 --label testing --silent)
bd dep add $UNIT_TESTS $IMPL_NEW_STORAGE

INTEGRATION_TESTS=$(bd create "Add integration tests for auth flow end-to-end with new middleware" -p 1 --label testing --silent)
bd dep add $INTEGRATION_TESTS $UPDATE_CONSUMERS

REGRESSION_CHECK=$(bd create "Run full regression suite and verify characterization tests still pass" -p 0 --label testing --silent)
bd dep add $REGRESSION_CHECK $INTEGRATION_TESTS
bd dep add $REGRESSION_CHECK $UNIT_TESTS

# ========================================
# Phase 4: Cleanup & Documentation
# ========================================

UPDATE_DOCS=$(bd create "Update auth middleware documentation and API reference" -p 2 --label docs --silent)
bd dep add $UPDATE_DOCS $REGRESSION_CHECK

CLEANUP=$(bd create "Remove deprecated session storage code and update changelog" -p 3 --label cleanup --silent)
bd dep add $CLEANUP $REGRESSION_CHECK

echo ""
echo "Bead graph created! View with:"
echo "  bd ready              # List unblocked tasks"
```

---

## Bead Creation Guidelines

### Priority Levels
- `-p 0` = Critical (blocking other work, or high-risk changes needing early validation)
- `-p 1` = High (important implementation work)
- `-p 2` = Medium (standard work)
- `-p 3` = Low (cleanup, nice-to-haves)

### Labels (Phase Grouping)
Use `--label` to group beads by phase:
- `analysis` - Understanding current state
- `prep` - Preparation work (characterization tests, feature flags, scaffolding)
- `impl` - Core implementation
- `testing` - Test coverage
- `migration` - Data/code migration
- `docs` - Documentation updates
- `cleanup` - Post-rollout cleanup

### Dependency Rules
1. Never create cycles
2. Analysis tasks should complete before implementation begins
3. Characterization tests should exist before changing code
4. Use `bd dep add CHILD PARENT` (child depends on parent completing first)
5. Parallel work should share a common ancestor, not depend on each other

### Task Granularity
- Each bead should be completable in **under 750 lines of code changed**
- Tasks should be atomic enough for one agent to complete without coordination
- If a task requires multiple file areas, consider splitting by file area

---

## Change-Specific Considerations

### For New Features
- Start with analysis of similar existing features
- Consider feature flag for gradual rollout
- Plan for A/B testing if relevant
- Include documentation and changelog updates

### Platform Backend Pattern (follow Emscripten precedent)
The existing Emscripten backend (added in recent commits) is the closest precedent. Study how `when defined(emscripten):` is used in `src/boxy.nim` and `src/boxy/shaders.nim` to understand the conditional compilation pattern to replicate for `when defined(ds3):`. **However note:** the Emscripten port only changes GLSL version strings — it does not restructure the `Boxy` type or guard the `import opengl` line. The 3DS port requires both, which is a deeper change.

### Backend Interface Extraction (blocking prerequisite)
Before any `when defined(ds3):` work can be applied to the existing core files, the `Boxy` type must be restructured. Currently lines 32–62 of `src/boxy.nim` embed GL-specific fields (`tmpFramebuffer: GLuint`, `layerFramebuffers: seq[GLuint]`, `vertexArrayId: GLuint`) and GL-backed types. The interface must expose **higher-level operations**, not just abstract the fields:
- `blitAtlasToNewAtlas(old, new)` — because `grow()` is a GPU blit, not a CPU re-upload; the atlas must simultaneously be a render target and a sample source
- `compositeLayer(blendMode, tint)` — because `popLayer()` contains platform-specific blend state, shader swaps, and tmp-texture ping-pong interleaved with bookkeeping
- `beginAtlasTarget()` / `endAtlasTarget()` — to support atlas-as-RTT on PICA200 VRAM

Additionally, `backend_interface.nim` must define GL-free `Filter`, `Wrap`, and `Texture` types because textures.nim lines 6–23 define enums using GL constants as values and fields typed as `GLenum`. The `Boxy ↔ Backend` object graph must not form a reference cycle (ARC has no cycle collector). This is **sequential, design-first work** — no parallel agent fan-out until it is complete.

### PICA200 Constraints
- **Rendering layer: raw citro3d only.** citro2d is excluded (see Description).
- **No fragment shader.** Only Normal, Multiply, Screen, and Add blend modes are achievable via fixed-function TEV combiners. The remaining 11 modes must no-op to Normal on 3DS (document this explicitly in code and README).
- **blurEffect and spreadEffect: no-op on 3DS.** Both are multi-tap fragment effects with no TEV equivalent.
- **Vertex shader:** write one `.pica` shader handling UV-mapped quads (position + UV + color attributes) using the picasso assembler.
- **Morton/Z-order tiling — alignment constraint:** boxy's atlas tile offsets are computed as `(index mod tileRun) * (tileSize + tileMargin)`. With `tileMargin` involved, these are almost never multiples of 8. The PICA200 requires 8×8 Z-order swizzle blocks. Every sub-image atlas write requires a proper swizzle-aware copy. A naive memcpy silently garbles output. The `grow()` path is a GPU FBO blit (not a CPU re-upload — see Description), so `grow()` handles its own re-layout; the swizzle utility is primarily for incremental `addImage` tile uploads.
- **Layer textures must be power-of-two.** boxy currently sizes layers to `frameSize` (400×240). On 3DS these must be padded to 512×256 POT dimensions, with the projection and UV math adjusted. Affected sites: `addLayerTexture` (lines 149–166), `tmpTexture` (lines 660–672), `popLayer` (lines 730–731), `copyLowerToCurrent` (lines 799–800), and the `beginFrame` resize path (lines 962–967) which resets layers back to `frameSize` and must also apply POT padding.
- **Rotated framebuffer projection.** The PICA200 top screen is physically 240×400 (rotated); raw citro3d requires a 90° rotation baked into the orthographic projection matrix. boxy's current `proj: Mat4` setup (set in `beginFrame`) does not include this rotation — output will appear sideways without it.
- **VRAM budget — revised.** The atlas must be both a render target and a sample source (see `grow()` note in Description), so it must be allocated with `C3D_TexInitVRAM`. PICA200 VRAM is ~6 MB. Atlas as RTT at 512² × RGBA8 ≈ 1 MB + RTT overhead; at 1024² ≈ 4 MB + overhead. Per-layer 512×256 RTTs add ~512 KB each. Total VRAM budget must be explicitly modelled and the atlas auto-grow cap set accordingly. Default `atlasSize=512` is safest starting point.
- **Vertex color normalization.** `boxy.nim:274` sets `colors.buffer.normalized = true`, relying on OpenGL to auto-normalize u8 [0,255] → float [0,1] for the vertex color attribute. citro3d's attribute configuration for `GPU_UNSIGNED_BYTE` must be confirmed to do the same; if it does not, the `.pica` vertex shader must divide by 255 explicitly. Silent tint/colour corruption if missed.
- **Render-to-texture for `pushLayer`/`popLayer`:** use `C3D_TexInitVRAM` + `C3D_RenderTargetCreateFromTex`. Switching render targets mid-frame has flush costs; benchmark this path. RTT gate (milestone 6) must use NormalBlend explicitly.
- **Main loop ownership:** `gfxSwapBuffers` / `aptMainLoop` / the polling loop must live in the example (not boxy), consistent with boxy's existing host-owns-the-loop design.

### Toolchain Bootstrap is the Critical Path
The milestones in Success Criteria must be completed in order. Each gate is a dependency for the next. No boxy rendering work should begin until gate 1 (toolchain) is verified.

---

## File Reservation Planning

```
# PHASE 1 — sequential (backend interface extraction, no parallelism):
# src/boxy/backends/backend_interface.nim  — NEW, define first
# src/boxy/backends/opengl_backend.nim     — NEW, extract existing GL impl here
# src/boxy.nim                             — restructure Boxy type, guard imports

# PHASE 2 — parallel (new 3DS-only files, no contention):
# src/boxy/bindings/citro3d.nim
# src/boxy/bindings/libctru_gfx.nim
# src/boxy/backends/citro3d_backend.nim
# shaders/render2d.v.pica
# nim_3ds.cfg
# scripts/build_3ds.sh

# PHASE 3 — sequential (wire ds3 conditionals into remaining core files):
# src/boxy/shaders.nim     — guard import + skip GL compile on ds3
# src/boxy/buffers.nim     — skip GL buffer alloc on ds3
# src/boxy/textures.nim    — guard import + skip GL texture calls on ds3
# src/boxy/blends.nim      — no-op unsupported modes on ds3
# src/boxy/blurs.nim       — no-op on ds3
# src/boxy/spreads.nim     — no-op on ds3

# PHASE 4 — can parallelize:
# examples/basic_3ds.nim
# config.nims (ds3 target block)
```

---

## Verification Steps

After generating the script:

1. **Run it**: `chmod +x setup-beads.sh && ./setup-beads.sh`
2. **Check ready work**: `bd ready` should show toolchain analysis/setup tasks first

---

## Completeness Checklist

Ensure your task graph includes:

**Phase 0 — Prerequisites (sequential, must complete before any parallel work):**
- [ ] Resolve citro2d vs. raw citro3d decision (documented: raw citro3d, see Description)
- [ ] Investigate pixie/nimsimd/zippy cross-compilation for ARMv6K + devkitARM + ARC GC; document outcome and fallback strategy if pixie cannot compile as-is
- [ ] Analysis of Emscripten conditional compilation pattern in src/boxy.nim and src/boxy/shaders.nim
- [ ] Analysis of boxy.nim lines 32–62 (Boxy type GL fields) and lines 3–5 (unconditional opengl/pixie imports) to design backend interface
- [ ] Design and implement `src/boxy/backends/backend_interface.nim`: platform-agnostic interface including higher-level ops (`blitAtlasToNewAtlas`, `compositeLayer`, `beginAtlasTarget`/`endAtlasTarget`) and GL-free `Filter`, `Wrap`, `Texture` type definitions; design must avoid `Boxy ↔ Backend` reference cycles (ARC has no cycle collector)
- [ ] Extract existing OpenGL implementation into `src/boxy/backends/opengl_backend.nim`; restructure `Boxy` type to use backend interface; guard `import opengl, shady` at the module level **and** `export atlasVert, atlasMain, maskMain` (line 6) and `export pixie` (line 8) as a unit

**Phase 1 — Toolchain:**
- [ ] Analysis of raylib-nim-multiplatform nim_3ds.cfg and build_3ds.sh for toolchain reference
- [ ] nim_3ds.cfg creation (devkitARM paths, ARC GC flags, ARMv6K architecture flags: -march=armv6k -mtune=mpcore -mfloat-abi=hard)
- [ ] config.nims ds3 target block (--gc:arc, --mm:arc, useMalloc, nimAllocPagesViaMalloc, noSignalHandler, opt:size)
- [ ] scripts/build_3ds.sh pipeline (nim compile → smdh → romfs → 3dsxtool → .3dsx)
- [ ] Toolchain verification gate: blank .3dsx boots on Azahar (Success Criteria milestone 1)

**Phase 2 — Bindings and shader (can run in parallel after Phase 1):**
- [ ] Nim FFI bindings for raw citro3d (C3D_Init, C3D_Fini, C3D_Tex, C3D_TexInit, C3D_TexInitVRAM, C3D_TexUpload, C3D_RenderTarget, C3D_RenderTargetCreate, C3D_RenderTargetCreateFromTex, C3D_DrawElements, C3D_TexEnv, C3D_TexEnvSrc, C3D_TexEnvOp, C3D_TexEnvFunc, C3D_AlphaBlend)
- [ ] Nim FFI bindings for libctru GFX (gfxInitDefault, gfxSwapBuffers, aptMainLoop, gfxExit) and libctru DVLB shader loading (DVLB_ParseFile, shaderProgramInit, shaderProgramBind)
- [ ] Nim FFI bindings for libctru HID (hidScanInput, hidKeysDown) — needed for aptMainLoop example
- [ ] PICA200 vertex shader: shaders/render2d.v.pica (position + UV + color attributes; include explicit /255 normalisation for u8 colour if citro3d does not auto-normalise GPU_UNSIGNED_BYTE attributes); integrate picasso into build_3ds.sh (.pica → .shbin; decision on RomFS embed vs `--incbin` must be explicit); verify output register layout matches C3D_AttrInfo configuration
- [ ] Bindings link gate: minimal .3dsx calling C3D_Init/C3D_Fini **and** loading the .shbin via DVLB_ParseFile + shaderProgramInit links and runs (Success Criteria milestone 2)

**Phase 3 — citro3d backend implementation (sequential within, some sub-tasks parallel):**
- [ ] citro3d_backend.nim: swizzle/Morton-tiling utility — 8×8 Z-order tile writer for GPU_RGBA8 for incremental `addImage` tile uploads at non-8-aligned atlas offsets; tested against the single-quad gate (Success Criteria milestone 3)
- [ ] citro3d_backend.nim: atlas texture — `C3D_TexInitVRAM` (atlas must be both sample source and render target for `grow()`); POT dimensions; Morton-tiled incremental upload; VRAM budget modelled explicitly with growth cap
- [ ] citro3d_backend.nim: `blitAtlasToNewAtlas` — GPU blit from old atlas to new atlas via `C3D_RenderTargetCreateFromTex` + draw call (mirrors `grow()` logic on PICA200)
- [ ] citro3d_backend.nim: quad batching via C3D_DrawElements; vertex format matching boxy's quad layout; confirm u8 colour auto-normalisation or add /255 in shader
- [ ] citro3d_backend.nim: render-to-texture (`compositeLayer` / `beginAtlasTarget`/`endAtlasTarget`) — `C3D_TexInitVRAM` + `C3D_RenderTargetCreateFromTex`; layer textures padded to 512×256 POT; UV/projection adjusted at all affected sites (addLayerTexture lines 149–166, tmpTexture 660–672, popLayer 730–731, copyLowerToCurrent 799–800, beginFrame resize 962–967)
- [ ] citro3d_backend.nim: rotated framebuffer projection — bake 90° rotation into orthographic proj matrix for top screen (physically 240×400)
- [ ] citro3d_backend.nim: TEV configuration for Normal, Multiply, Screen, Add; MaskBlend via C3D fixed-function blend factors (document maskShader loss); no-op stub for all other blend modes + GPU readback procs + enterRawOpenGLMode/exitRawOpenGLMode (logs warning on first use)
- [ ] Confirm ARC-safe GPU upload lifetimes: any temporary Nim seq/Image passed to citro3d upload functions must be kept alive until GPU DMA completes (explicit flush or retained staging buffer)
- [ ] pixie cross-compilation gate (Success Criteria milestone 4)

**Phase 4 — Wire conditionals into core files:**
- [ ] src/boxy.nim: when defined(ds3): conditionals wired to citro3d_backend; guard `import opengl, shady, pixie` (line 3), `export atlasVert, atlasMain, maskMain` (line 6), `export pixie` (line 8) as a unit; guard `atlasTexture.writeFile(...)` in grow() error path (line 393–394) to `when not defined(emscripten) and not defined(ds3)`; no-op `enterRawOpenGLMode`/`exitRawOpenGLMode` on ds3
- [ ] src/boxy/shaders.nim: guard `import opengl, shady` + all shady DSL shader-definition procs on ds3
- [ ] src/boxy/buffers.nim: skip GL buffer allocation on ds3
- [ ] src/boxy/textures.nim: guard `import opengl, pixie`; use backend-interface GL-free `Filter`/`Wrap`/`Texture` types on ds3; no-op `readImage`, `writeFile` on ds3 with documented warning
- [ ] src/boxy/blends.nim: no-op unsupported blend modes on ds3 with documented warning; guard shady DSL shader-definition procs
- [ ] src/boxy/blurs.nim: no-op blurEffect on ds3 with documented warning
- [ ] src/boxy/spreads.nim: no-op spreadEffect on ds3 with documented warning
- [ ] boxy.nimble: ensure windy dependency is not resolved/built for ds3 target (conditional require or build bypass)

**Phase 5 — Example, regression, docs:**
- [ ] examples/basic_3ds.nim: newBoxy → addImage → drawImage at 400×240; RomFS asset structure
- [ ] Atlas + drawImage gate on Azahar (Success Criteria milestone 5)
- [ ] RTT gate: pushLayer/popLayer round-trip on Azahar (Success Criteria milestone 6)
- [ ] Regression gate: basic_windy.nim, basic_glfw.nim, basic_sdl2.nim compile and run on macOS (Success Criteria milestone 7)
- [ ] Documentation: partial-API table (which blend modes/effects work on 3DS), build prerequisites, build steps in README
