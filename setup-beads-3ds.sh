#!/bin/bash
# Project: boxy
# Change: Add Nintendo 3DS citro3d backend
# Generated: 2026-05-29

set -e

# Initialize beads if needed
if [ ! -d ".beads" ]; then
    bd init
fi

echo "Creating 3DS citro3d backend task graph..."

# ============================================================
# Phase 0A — Codebase Analysis (no dependencies, run immediately)
# ============================================================

ANALYZE_EMSCRIPTEN=$(bd create "Analyze Emscripten conditional compilation pattern in boxy" \
  -d "Read src/boxy.nim (lines 3–10 imports/exports, lines 338–358 enterRawOpenGLMode/exitRawOpenGLMode) and src/boxy/shaders.nim (full file) to map every 'when defined(emscripten):' guard. Document: which imports are guarded vs. not, how shady DSL shader-definition procs are compiled out, and how the Emscripten pattern falls short for 3DS (it only changes GLSL version strings — it does not restructure the Boxy type or guard import opengl). This analysis drives backend_interface.nim design." \
  -p 0 -l analysis --silent)

ANALYZE_BOXY_TYPE=$(bd create "Analyze Boxy type GL fields and import graph for backend extraction" \
  -d "Read src/boxy.nim lines 1–62. Map every GL-specific field: tmpFramebuffer GLuint (line 36), layerFramebuffers seq[GLuint] (line 39), vertexArrayId GLuint (line 54), atlasTexture/tmpTexture Texture (line 35), positions/colors/uvs/indices Buffer tuples (lines 59–62). Also catalogue: unconditional 'import opengl, shady, pixie' (line 3), 'export atlasVert, atlasMain, maskMain' (line 6), 'export pixie' (line 8) — these three must be guarded as a unit since blends.nim defines the exported symbols using shady DSL. Read grow() (lines 384–496) to confirm it is a GPU FBO blit (not CPU re-upload) requiring atlas as both render target and sample source. Output a design note listing the higher-level operations the backend interface must expose." \
  -p 0 -l analysis --silent)

INVESTIGATE_PIXIE=$(bd create "Investigate pixie/nimsimd/zippy cross-compilation for ARMv6K" \
  -d "Determine whether pixie + nimsimd + zippy can cross-compile for ARMv6K under arm-none-eabi-gcc with --gc:arc. Check: (1) pixie's nimsimd dependency gates SIMD intrinsics on 'when defined(amd64)' — verify ARMv6K path compiles cleanly; (2) zippy has no SIMD dependency issues known; (3) pixie is imported unconditionally in src/boxy.nim:3 and src/boxy/textures.nim — this is a hard blocker for any boxy image-loading code on 3DS. Document outcome: if pixie compiles as-is, note it; if it does not, document the fallback cost (disables one-color tile optimisation, bordered tile splitting, CPU mipmap chain, drawImage LOD selection). Decision must be explicit before Phase 3 citro3d_backend.nim work begins." \
  -p 0 -l analysis --silent)

ANALYZE_RAYLIB_REF=$(bd create "Analyze raylib-nim-multiplatform 3DS build reference" \
  -d "Read /Users/punk1290/git/raylib-nim-multiplatform/nim_3ds.cfg (compiler config: devkitARM paths, -march=armv6k -mtune=mpcore -mfloat-abi=hard, passC/passL flags), scripts/build_3ds.sh (full pipeline: nim compile → arm-none-eabi-gcc → smdh → romfs → 3dsxtool → .3dsx), and config.nims for the ds3 defined block (--gc:arc, useMalloc, nimAllocPagesViaMalloc, noSignalHandler, opt:size). Also read src/bindings/raylib_console.nim for {.importc.}/{.header.} FFI binding style. Document all reusable patterns for boxy's nim_3ds.cfg and build_3ds.sh." \
  -p 0 -l analysis --silent)

# ============================================================
# Phase 0B — Backend Interface Extraction (SEQUENTIAL — no parallelism allowed)
# ============================================================

DESIGN_BACKEND_IFACE=$(bd create "Design backend_interface.nim: platform-agnostic interface and type plan" \
  -d "Produce a written design (as comments in a stub file) for src/boxy/backends/backend_interface.nim. Must include: (1) GL-free Filter, Wrap, Texture type definitions replacing src/boxy/textures.nim lines 6–23 which currently embed GL_NEAREST/GL_REPEAT/GLenum constants; (2) higher-level GPU operations: blitAtlasToNewAtlas(old, new) for grow(), compositeLayer(blendMode, tint) for popLayer(), beginAtlasTarget()/endAtlasTarget() for atlas-as-RTT on PICA200 VRAM; (3) explicit analysis of every site in boxy.nim that interleaves bookkeeping with GL calls and cannot be separated by field-wrapping alone (grow lines 384–496, popLayer lines 710–724); (4) object graph design that avoids Boxy↔Backend reference cycles — ARC has no cycle collector (--gc:orc incompatible with this target). No implementation yet." \
  -p 0 -l prep --silent)

IMPL_BACKEND_IFACE=$(bd create "Implement src/boxy/backends/backend_interface.nim" \
  -d "Create src/boxy/backends/backend_interface.nim with the design from the prior task. Must provide: GL-free Filter (filterDefault/filterNearest/filterLinear), Wrap (wDefault/wRepeat/wClampToEdge/wMirroredRepeat), and Texture types; abstract Backend type/interface with procs: blitAtlasToNewAtlas, compositeLayer(blendMode, tint), beginAtlasTarget, endAtlasTarget, flush, uploadTile, createAtlasTexture, deleteTexture; and any shared enums/constants needed by both opengl_backend.nim and citro3d_backend.nim. Compile-check that the file builds standalone with 'nim check'." \
  -p 0 -l impl --silent)

EXTRACT_OPENGL_BACKEND=$(bd create "Extract OpenGL implementation to src/boxy/backends/opengl_backend.nim" \
  -d "Create src/boxy/backends/opengl_backend.nim implementing the Backend interface from backend_interface.nim. Move all GL-specific logic out of src/boxy.nim: tmpFramebuffer/layerFramebuffers/vertexArrayId management, all glGen*/glBind*/glDelete* calls, the FBO blit in grow() as blitAtlasToNewAtlas, the blend-state + shader-swap logic in popLayer() as compositeLayer, beginAtlasTarget/endAtlasTarget. Preserve 1:1 behavioural equivalence with the existing OpenGL path — no feature changes, only reorganization. Verify with existing desktop examples (basic_windy.nim, basic_glfw.nim, basic_sdl2.nim) still compile." \
  -p 0 -l impl --silent)

RESTRUCTURE_BOXY_TYPE=$(bd create "Restructure Boxy type in boxy.nim to use backend interface; guard imports" \
  -d "Edit src/boxy.nim: (1) Replace GL-specific fields (tmpFramebuffer GLuint line 36, layerFramebuffers seq[GLuint] line 39, vertexArrayId GLuint line 54) with a Backend object using the interface from backend_interface.nim; (2) Guard 'import opengl, shady, pixie' (line 3) + 'export atlasVert, atlasMain, maskMain' (line 6) + 'export pixie' (line 8) together under 'when not defined(ds3):' — these three must be guarded as a unit because blends.nim defines the exported shader symbols using shady DSL; (3) Guard atlasTexture.writeFile call in grow() error path (lines 393–394) as 'when not defined(emscripten) and not defined(ds3):'; (4) Add no-op stubs for enterRawOpenGLMode/exitRawOpenGLMode on ds3 with a documented warning. Verify: desktop examples still compile and run unchanged on macOS." \
  -p 0 -l impl --silent)

# Dependencies for Phase 0B (strictly sequential)
bd dep add $DESIGN_BACKEND_IFACE $ANALYZE_EMSCRIPTEN
bd dep add $DESIGN_BACKEND_IFACE $ANALYZE_BOXY_TYPE
bd dep add $IMPL_BACKEND_IFACE $DESIGN_BACKEND_IFACE
bd dep add $EXTRACT_OPENGL_BACKEND $IMPL_BACKEND_IFACE
bd dep add $RESTRUCTURE_BOXY_TYPE $EXTRACT_OPENGL_BACKEND

# ============================================================
# Phase 1 — Toolchain Bootstrap (parallel with Phase 0B after ANALYZE_RAYLIB_REF)
# ============================================================

NIM_3DS_CFG=$(bd create "Create nim_3ds.cfg for devkitARM cross-compilation" \
  -d "Create nim_3ds.cfg at the boxy repo root. Based on /Users/punk1290/git/raylib-nim-multiplatform/nim_3ds.cfg. Set: cc=gcc, arm.linux.gcc.path=/opt/devkitpro/devkitARM/bin, arm.linux.gcc.exe/linkerexe=arm-none-eabi-gcc, --passC flags (-march=armv6k -mtune=mpcore -mfloat-abi=hard -mtp=soft -D__3DS__ -DARM11 -I/opt/devkitpro/libctru/include -I/opt/devkitpro/citro3d/include), --passL flags (-specs=3dsx.specs -march=armv6k -mtune=mpcore -mfloat-abi=hard -L/opt/devkitpro/libctru/lib -L/opt/devkitpro/citro3d/lib -lcitro3d -lctru -lm). Include --os:linux --cpu:arm." \
  -p 0 -l prep --silent)

CONFIG_NIMS_DS3=$(bd create "Add ds3 target block to examples/config.nims" \
  -d "Edit examples/config.nims to add a 'when defined(ds3):' block parallel to the existing emscripten block. Flags: --gc:arc, --mm:arc, -d:useMalloc, --define:nimAllocPagesViaMalloc, --define:noSignalHandler, --opt:size, --cpu:arm, --os:linux, --noMain:on (3DS has its own main via libctru). Also suppress windy/opengl linking for ds3 target. The config.nims root (not examples/) does not exist yet — if boxy needs a root config.nims for the build script, create it with just the ds3 block." \
  -p 0 -l prep --silent)

BUILD_SCRIPT=$(bd create "Create scripts/build_3ds.sh full build pipeline" \
  -d "Create scripts/build_3ds.sh (chmod +x). Full pipeline: (1) nim compile --define:ds3 --config:nim_3ds.cfg -o:build/boxy3ds.elf <target.nim>; (2) picasso shaders/render2d.v.pica -o build/render2d.shbin (compile PICA200 vertex shader); (3) smdh generation via bannertool or smdhtool; (4) romfs directory structure at romfs/ with assets; (5) 3dsxtool build/boxy3ds.elf build/boxy3ds.3dsx --smdh=build/boxy3ds.smdh --romfs=romfs/. Document devkitPro PATH requirements. Script must skip nimble dep resolution for windy (windy will not cross-compile for ARMv6K). Derives from /Users/punk1290/git/raylib-nim-multiplatform/scripts/build_3ds.sh patterns." \
  -p 0 -l prep --silent)

TOOLCHAIN_GATE=$(bd create "Verify toolchain gate: blank .3dsx boots on Azahar (milestone 1)" \
  -d "Compile and run a minimal Nim program (no boxy, no pixie — just a main() that initialises gfxInitDefault, sleeps one frame via aptMainLoop, calls gfxExit and returns) through the full pipeline: nim compile → arm-none-eabi-gcc → 3dsxtool → .3dsx. Verify the resulting .3dsx launches without crashing on Azahar emulator (macOS). This is Success Criteria milestone 1 — no boxy rendering work may begin until this gate passes. Document any devkitPro PATH or toolchain issues encountered." \
  -p 0 -l testing --silent)

# Toolchain chain dependencies
bd dep add $NIM_3DS_CFG $ANALYZE_RAYLIB_REF
bd dep add $CONFIG_NIMS_DS3 $ANALYZE_RAYLIB_REF
bd dep add $BUILD_SCRIPT $NIM_3DS_CFG
bd dep add $BUILD_SCRIPT $CONFIG_NIMS_DS3
bd dep add $TOOLCHAIN_GATE $BUILD_SCRIPT

# ============================================================
# Phase 2 — Bindings and Shader (parallel after TOOLCHAIN_GATE)
# ============================================================

BINDINGS_CITRO3D=$(bd create "Write Nim FFI bindings for raw citro3d (src/boxy/bindings/citro3d.nim)" \
  -d "Create src/boxy/bindings/citro3d.nim using {.importc.}/{.header.} pragmas. Bind: C3D_Init, C3D_Fini, C3D_Tex struct, C3D_TexInit, C3D_TexInitVRAM (atlas must be VRAM-resident to serve as both render target and sample source for grow()), C3D_TexUpload, C3D_TexFlush, C3D_RenderTarget, C3D_RenderTargetCreate, C3D_RenderTargetCreateFromTex, C3D_RenderTargetSetOutput, C3D_DrawElements, C3D_TexEnv*, C3D_TexEnvSrc, C3D_TexEnvOp, C3D_TexEnvFunc, C3D_TexEnvColor, C3D_AlphaBlend, C3D_AttrInfo*, C3D_BufInfo*, C3D_FixedAttrib*. Reference: https://github.com/devkitPro/citro3d headers and https://github.com/rust3ds/citro3d-rs for binding style. Follow FFI style from /Users/punk1290/git/raylib-nim-multiplatform/src/bindings/raylib_console.nim." \
  -p 0 -l impl --silent)

BINDINGS_LIBCTRU=$(bd create "Write Nim FFI bindings for libctru GFX, DVLB shader loading (libctru_gfx.nim)" \
  -d "Create src/boxy/bindings/libctru_gfx.nim. Bind libctru GFX: gfxInitDefault, gfxSwapBuffers, gfxExit, gfxSet3D. Bind libctru DVLB shader loading (needed for verifying .shbin path at milestone 2): DVLB_ParseFile (returns DVLB_s*), shaderProgramInit, shaderProgramSetVsh, shaderProgramBind, shaderProgramFree. Bind APT: aptMainLoop. Bind OS sleep: svcSleepThread. These bindings must be available for the bindings-link gate (milestone 2) which requires C3D_Init/C3D_Fini + DVLB_ParseFile + shaderProgramInit to all link and run." \
  -p 1 -l impl --silent)

BINDINGS_HID=$(bd create "Write Nim FFI bindings for libctru HID input (libctru_hid.nim)" \
  -d "Create src/boxy/bindings/libctru_hid.nim. Bind: hidScanInput, hidKeysDown, hidKeysHeld, hidKeysUp, KEY_START, KEY_A, KEY_B enum constants. These are required for the aptMainLoop example loop (examples/basic_3ds.nim must poll hidKeysDown to handle exit via KEY_START). Without HID bindings the example will compile but be uninterruptible on hardware." \
  -p 2 -l impl --silent)

PICA200_SHADER=$(bd create "Write PICA200 vertex shader shaders/render2d.v.pica and picasso integration" \
  -d "Create shaders/render2d.v.pica: PICA200 assembly vertex shader for UV-mapped quads. Attributes: position (vec4 at v0), UV (vec2 at v1), color (vec4 at v2). Outputs: result.position, result.texcoord0, result.color. Apply the orthographic projection uniform. If citro3d does not auto-normalise GPU_UNSIGNED_BYTE colour attributes (u8 [0,255] → float [0,1]) — verify this against citro3d C3D_AttrInfo docs — add explicit divide by 255 in shader; silent tint corruption results if missed. Integrate picasso into scripts/build_3ds.sh: 'picasso shaders/render2d.v.pica -o build/render2d.shbin'. Document: output register layout (result.position → v0, result.texcoord0 → v1, result.color → v2) must exactly match C3D_AttrInfo configured in citro3d_backend.nim — mismatch produces silent vertex corruption. Consult https://github.com/devkitPro/picasso Manual.md for .pica syntax." \
  -p 0 -l impl --silent)

BINDINGS_LINK_GATE=$(bd create "Verify bindings+link gate: C3D_Init + .shbin load links and runs (milestone 2)" \
  -d "Build a minimal .3dsx that: calls gfxInitDefault, calls C3D_Init(displayBufSize), loads render2d.shbin via DVLB_ParseFile, calls shaderProgramInit + shaderProgramSetVsh + shaderProgramBind, then calls C3D_Fini and gfxExit. No graphics output required. Verify the .3dsx launches without crashing on Azahar. This is Success Criteria milestone 2 — it confirms citro3d links, the .shbin embed/load path works, and shaderProgramInit does not abort. Fix any linker errors (missing -lcitro3d, -lctru flags) before proceeding." \
  -p 0 -l testing --silent)

# Phase 2 dependencies
bd dep add $BINDINGS_CITRO3D $TOOLCHAIN_GATE
bd dep add $BINDINGS_LIBCTRU $TOOLCHAIN_GATE
bd dep add $BINDINGS_HID $TOOLCHAIN_GATE
bd dep add $PICA200_SHADER $TOOLCHAIN_GATE
bd dep add $BINDINGS_LINK_GATE $BINDINGS_CITRO3D
bd dep add $BINDINGS_LINK_GATE $BINDINGS_LIBCTRU
bd dep add $BINDINGS_LINK_GATE $PICA200_SHADER

# ============================================================
# Phase 3 — citro3d Backend Implementation
# (SEQUENTIAL — all tasks write citro3d_backend.nim; converges chains A and B)
# ============================================================

SWIZZLE_UTIL=$(bd create "Implement Morton/Z-order swizzle utility in citro3d_backend.nim" \
  -d "Add Morton-tiling (Z-order) swizzle utility to src/boxy/backends/citro3d_backend.nim. The PICA200 requires textures in GPU_RGBA8 8×8 Z-order block layout (not linear). boxy writes atlas tiles at offsets of '(index mod tileRun) * (tileSize + tileMargin)' — with tileMargin in the mix these are almost never multiples of 8, so a naive memcpy silently garbles output. Implement: proc swizzleTileIntoAtlas(src: ptr uint8, srcW, srcH: int, dstAtlas: ptr uint8, atlasW, atlasStride, dstX, dstY: int) that writes RGBA8 pixels in 8×8 Morton order at the correct aligned destination offset. Test against the single-quad gate (milestone 3): upload a known 16×16 test texture via this utility, render it, verify pixel output is visually correct on Azahar." \
  -p 0 -l impl --silent)

ATLAS_TEXTURE=$(bd create "Implement atlas texture management in citro3d_backend.nim (VRAM + POT)" \
  -d "Add atlas texture management to src/boxy/backends/citro3d_backend.nim. Requirements: (1) Allocate atlas with C3D_TexInitVRAM (not C3D_TexInit) — the atlas must be simultaneously a sample source AND a render target for grow()/blitAtlasToNewAtlas; GPU_RGBA8 format; power-of-two dimensions starting at 512×512. (2) Implement createAtlasTexture(size: int): C3D_Tex. (3) Implement uploadTile(tex: C3D_Tex, src: ptr uint8, srcW, srcH, dstX, dstY: int) using the swizzle utility from prior task. (4) Model VRAM budget explicitly: atlas at 512² = ~1 MB, at 1024² = ~4 MB, PICA200 VRAM ≈ 6 MB total; set maxAtlasSize cap such that atlas + RTT layers fit in VRAM. Document the cap and rationale." \
  -p 0 -l impl --silent)

BLIT_ATLAS=$(bd create "Implement blitAtlasToNewAtlas in citro3d_backend.nim (GPU blit for grow())" \
  -d "Implement blitAtlasToNewAtlas(old, new: C3D_Tex) in src/boxy/backends/citro3d_backend.nim. This mirrors grow() (boxy.nim lines 384–496) on PICA200: create a C3D_RenderTargetCreateFromTex on the new atlas texture, bind it as render target, draw the old atlas as a full-screen quad using C3D_DrawElements (TEV set to pass-through, no blending), then restore the previous render target. This is the critical path for atlas growth — the atlas must be VRAM-resident (C3D_TexInitVRAM) to serve as both render target and sample source simultaneously. Note: this is NOT a CPU memcpy; it is a GPU draw call, consistent with the OpenGL FBO blit in grow()." \
  -p 0 -l impl --silent)

QUAD_BATCHING=$(bd create "Implement quad batching via C3D_DrawElements in citro3d_backend.nim" \
  -d "Implement the vertex/index buffer pipeline and flush path in src/boxy/backends/citro3d_backend.nim. Match boxy's existing quad layout: position (float32 × 2 per vertex), UV (float32 × 2), colour (uint8 × 4). Configure C3D_AttrInfo to match the render2d.v.pica shader output register layout (v0=position, v1=UV, v2=colour). Confirm u8 colour auto-normalisation: if citro3d does NOT normalise GPU_UNSIGNED_BYTE colour attributes to float [0,1], the shader must divide by 255 — silent tint corruption if missed. Implement flush() as: upload vertex data to GPU linear memory, call C3D_DrawElements(GPU_TRIANGLES, indexCount, GPU_UNSIGNED_SHORT, indexPtr). QuadLimit constant remains 10,921 (same as OpenGL path)." \
  -p 0 -l impl --silent)

SINGLE_QUAD_GATE=$(bd create "Verify single quad gate: Morton-tiled textured quad renders on Azahar (milestone 3)" \
  -d "Build a minimal .3dsx that renders a single hardcoded textured quad bypassing pixie and the boxy atlas entirely. Steps: manually create a 16×16 RGBA8 test image in memory, upload it to a C3D_TexInitVRAM texture via the swizzle utility (Morton-tiled, POT), configure TEV for pass-through (GPU_REPLACE), configure one draw call via C3D_DrawElements, render at 400×240 (with 90° rotation in ortho matrix for PICA200 top screen). Verify pixel output is visually correct on Azahar — this tests the swizzle/upload/TEV/draw path in isolation. Success Criteria milestone 3." \
  -p 0 -l testing --silent)

RTT_LAYERS=$(bd create "Implement render-to-texture layer system in citro3d_backend.nim" \
  -d "Implement compositeLayer(blendMode, tint), beginAtlasTarget, endAtlasTarget in src/boxy/backends/citro3d_backend.nim for pushLayer/popLayer round-trips. Requirements: (1) Layer textures must be allocated with C3D_TexInitVRAM + C3D_RenderTargetCreateFromTex; (2) Layer texture dimensions must be padded to 512×256 POT (boxy currently uses frameSize=400×240 — must pad); all 5 affected sites must receive POT padding: addLayerTexture (boxy.nim lines 149–166), tmpTexture (lines 660–672), popLayer (lines 730–731), copyLowerToCurrent (lines 799–800), beginFrame resize path (lines 962–967); (3) UV/projection math adjusted at all these sites to account for the padding; (4) VRAM budget: per-layer 512×256 RTT ≈ 512 KB; cap layer count so total VRAM (atlas + layers) fits in ~6 MB." \
  -p 0 -l impl --silent)

ROTATED_PROJ=$(bd create "Implement rotated framebuffer projection for PICA200 top screen" \
  -d "Edit src/boxy/backends/citro3d_backend.nim to bake a 90° rotation into the orthographic projection matrix for the PICA200 top screen. The top screen is physically 240×400 (rotated); raw citro3d requires this rotation in the ortho proj or output appears sideways. boxy's current proj setup is set in beginFrame (boxy.nim around line 962) as 'proj = ortho(0, frameSize.x, frameSize.y, 0, -1000, 1000)' — on ds3 this must incorporate the 90° CCW rotation. Apply the rotation by composing mat4Rotate with the ortho matrix. Verify: test quad rendered in SINGLE_QUAD_GATE should appear upright (not sideways) on Azahar after this change." \
  -p 0 -l impl --silent)

TEV_BLENDMODES=$(bd create "Implement TEV configuration for blend modes in citro3d_backend.nim" \
  -d "Implement TEV and alpha-blend configuration for the 4 achievable blend modes in src/boxy/backends/citro3d_backend.nim. (1) NormalBlend: TEV pass-through (GPU_REPLACE), C3D_AlphaBlend with SRC_ALPHA/ONE_MINUS_SRC_ALPHA. (2) MultiplyBlend: TEV combiner set to GPU_MODULATE on RGB channels. (3) ScreenBlend: TEV set to GPU_ADD with adjusted operands. (4) AddBlend: TEV GPU_ADD, C3D_AlphaBlend with GL_ONE/GL_ONE equivalent. (5) MaskBlend: implement via C3D fixed-function blend factors (GPU_ZERO, GPU_SRC_COLOR) — maskShader is lost (no fragment shader on PICA200); document this degraded behaviour explicitly in code comment. (6) All other blend modes: no-op stub that emits a single stderr warning on first use and falls back to NormalBlend. (7) No-op stubs for GPU readback procs readImage/writeFile/readAtlas/getImage with documented warning." \
  -p 0 -l impl --silent)

ARC_SAFE_UPLOADS=$(bd create "Audit and fix ARC-safe GPU upload lifetimes in citro3d_backend.nim" \
  -d "Audit all sites in src/boxy/backends/citro3d_backend.nim where temporary Nim seq or Image objects are passed to citro3d GPU upload functions (e.g., image.data[0].addr passed to C3D_TexUpload). ARC may free the seq before async GPU DMA completes, causing silent corruption. Fix: either (a) call C3D_TexFlush immediately after each upload (synchronous) and before the seq goes out of scope, or (b) use an explicit retained staging buffer (seq held at Boxy level). Also verify: the Boxy↔Backend object graph has no reference cycles — ARC has no cycle collector (--gc:orc incompatible with devkitARM target); backend must not hold a back-reference to Boxy. Verify exception unwinding works under noSignalHandler + devkitARM + ARC by triggering BoxyError in a test path." \
  -p 0 -l impl --silent)

PIXIE_CROSS_GATE=$(bd create "Verify pixie cross-compilation gate: pixie.newImage on 3DS (milestone 4)" \
  -d "Build a .3dsx that imports pixie, calls pixie.newImage(4, 4, rgbx(255, 0, 0, 255)) and returns cleanly. This confirms the pixie + nimsimd + zippy stack cross-compiles for ARMv6K under devkitARM + ARC GC. If pixie fails to compile as-is, implement the documented fallback strategy from the INVESTIGATE_PIXIE task (guard all pixie usage, disable one-color tile optimisation and CPU mipmap chain on ds3). The fallback decision must be finalised and committed before proceeding to basic_3ds.nim example. Success Criteria milestone 4." \
  -p 0 -l testing --silent)

# Phase 3 chain dependencies
bd dep add $SWIZZLE_UTIL $BINDINGS_LINK_GATE
bd dep add $SWIZZLE_UTIL $RESTRUCTURE_BOXY_TYPE
bd dep add $ATLAS_TEXTURE $SWIZZLE_UTIL
bd dep add $BLIT_ATLAS $ATLAS_TEXTURE
bd dep add $QUAD_BATCHING $BLIT_ATLAS
bd dep add $SINGLE_QUAD_GATE $QUAD_BATCHING
bd dep add $RTT_LAYERS $SINGLE_QUAD_GATE
bd dep add $ROTATED_PROJ $RTT_LAYERS
bd dep add $TEV_BLENDMODES $ROTATED_PROJ
bd dep add $ARC_SAFE_UPLOADS $TEV_BLENDMODES
bd dep add $PIXIE_CROSS_GATE $ARC_SAFE_UPLOADS
bd dep add $PIXIE_CROSS_GATE $INVESTIGATE_PIXIE
bd dep add $PIXIE_CROSS_GATE $BUILD_SCRIPT

# ============================================================
# Phase 4 — Wire ds3 Conditionals Into Core Files
# (mostly parallel — each touches a different file)
# ============================================================

WIRE_BOXY_NIM=$(bd create "Wire ds3 conditionals into src/boxy.nim" \
  -d "Edit src/boxy.nim to dispatch to citro3d_backend on ds3. (1) Add 'when defined(ds3): import boxy/backends/citro3d_backend' alongside the opengl_backend import; (2) Guard 'import opengl, shady, pixie' (line 3) + 'export atlasVert, atlasMain, maskMain' (line 6) + 'export pixie' (line 8) together as a unit under 'when not defined(ds3):' — these three must be guarded together because blends.nim defines the exported shader symbols using shady DSL; (3) Guard atlasTexture.writeFile error path (lines 393–394) as 'when not defined(emscripten) and not defined(ds3):'; (4) No-op enterRawOpenGLMode/exitRawOpenGLMode on ds3 with a stderr warning. Verify: all desktop examples (basic_windy.nim, basic_glfw.nim, basic_sdl2.nim) still compile on macOS without any changes." \
  -p 0 -l impl --silent)

WIRE_SHADERS_NIM=$(bd create "Wire ds3 conditionals into src/boxy/shaders.nim" \
  -d "Edit src/boxy/shaders.nim to skip OpenGL shader compilation on ds3. (1) Guard 'import opengl, shady' at the top under 'when not defined(ds3):'; (2) Guard all shady DSL shader-definition procs (any proc that calls toGLSL(...) or uses shady DSL functions) under 'when not defined(ds3):' — shady is a compile-time codegen dependency that runs in the Nim VM; guarding its import makes these procs unavailable on ds3 so all call sites must also be guarded; (3) The Shader type and its fields (programId: GLuint, attribs, uniforms) need a ds3-compatible stub or backend-interface abstraction. Verify shaders.nim compiles under ds3 define without importing opengl." \
  -p 1 -l impl --silent)

WIRE_BUFFERS_NIM=$(bd create "Wire ds3 conditionals into src/boxy/buffers.nim" \
  -d "Edit src/boxy/buffers.nim (54 lines total) to skip OpenGL vertex/index buffer allocation on ds3. Guard all glGen*/glBind*/glBufferData* calls under 'when not defined(ds3):'. The Buffer type fields (including any GLuint IDs) must either use backend-interface types or be guarded. On ds3, buffer management is handled entirely in citro3d_backend.nim via citro3d linear memory. Verify file compiles under ds3 define without importing opengl." \
  -p 1 -l impl --silent)

WIRE_TEXTURES_NIM=$(bd create "Wire ds3 conditionals into src/boxy/textures.nim" \
  -d "Edit src/boxy/textures.nim to use GL-free types on ds3. (1) Guard 'import opengl, pixie' at the top; (2) Replace Filter/Wrap enum definitions (lines 6–23) that use GL_NEAREST/GL_REPEAT/GL_CLAMP_TO_EDGE/GL_MIRRORED_REPEAT/GLenum constants with 'when defined(ds3):' branches using the platform-agnostic Filter/Wrap types from backend_interface.nim; (3) Replace Texture field types (componentType/format/internalFormat: GLenum, textureId: GLuint) with ds3-compatible versions on ds3; (4) Guard GPU readback procs readImage (lines 185–196, depends on glGetTexImage which has no citro3d equivalent) and writeFile (lines 198–202) under 'when not defined(ds3):' with no-op stubs and a documented warning for the partial-API table. Verify file compiles under ds3 define." \
  -p 1 -l impl --silent)

WIRE_BLENDS_NIM=$(bd create "Wire ds3 conditionals into src/boxy/blends.nim" \
  -d "Edit src/boxy/blends.nim (201 lines). (1) Guard all shady DSL shader-definition procs (procs using srcTexture/dstTexture Uniform[Sampler2d] and blendMode Uniform[int32] from shady) under 'when not defined(ds3):' — the 11 blend modes requiring per-pixel dstTexture sampling are infeasible on PICA200; (2) On ds3, all blend modes other than Normal/Multiply/Screen/Add must no-op to NormalBlend with a single stderr warning emitted on first use per mode — document this explicitly in code comments; (3) MaskBlend: classify explicitly as achievable via C3D fixed-function blend factors but without maskShader (fragment shader unavailable) — document the degraded behaviour in a comment and in the partial-API table task; (4) Guard 'export atlasVert, atlasMain, maskMain' consistently with boxy.nim changes. Verify file compiles under ds3 define." \
  -p 1 -l impl --silent)

WIRE_BLURS_NIM=$(bd create "Wire ds3 conditionals into src/boxy/blurs.nim" \
  -d "Edit src/boxy/blurs.nim (39 lines). Guard all content under 'when not defined(ds3):'. On ds3, blurEffect must be a no-op stub that emits a single documented warning on first call. Note: dropShadowEffect (boxy.nim lines 887–954) drives blur shaders directly and is also infeasible — add a no-op guard in boxy.nim for dropShadowEffect on ds3. Document both as unsupported in the partial-API table task." \
  -p 2 -l impl --silent)

WIRE_SPREADS_NIM=$(bd create "Wire ds3 conditionals into src/boxy/spreads.nim" \
  -d "Edit src/boxy/spreads.nim (56 lines). Guard all content under 'when not defined(ds3):'. On ds3, spreadEffect must be a no-op stub that emits a single documented warning on first call. Both blurEffect and spreadEffect are multi-tap fragment effects with no TEV equivalent on PICA200. Document as unsupported in the partial-API table task." \
  -p 2 -l impl --silent)

NIMBLE_WINDY_BYPASS=$(bd create "Bypass windy nimble dependency for ds3 target in boxy.nimble" \
  -d "Edit boxy.nimble to prevent the windy >= 0.4.4 dependency from being resolved or built when targeting ds3. windy is a desktop windowing library that will not cross-compile for ARMv6K. Options: (1) Add a conditional require if nimble supports it; (2) Document that users must pass --noNimbleDeps or use a custom nimble.lock that excludes windy for ds3 builds; (3) Ensure build_3ds.sh bypasses nimble dependency resolution entirely (nim compile with explicit --path flags, not 'nimble build'). Also ensure examples that import windy (basic_windy.nim, multiple_windows.nim) are not compiled by build_3ds.sh." \
  -p 1 -l impl --silent)

# Phase 4 dependencies
bd dep add $WIRE_BOXY_NIM $ARC_SAFE_UPLOADS
bd dep add $WIRE_SHADERS_NIM $RESTRUCTURE_BOXY_TYPE
bd dep add $WIRE_BUFFERS_NIM $RESTRUCTURE_BOXY_TYPE
bd dep add $WIRE_TEXTURES_NIM $RESTRUCTURE_BOXY_TYPE
bd dep add $WIRE_BLENDS_NIM $TEV_BLENDMODES
bd dep add $WIRE_BLURS_NIM $RESTRUCTURE_BOXY_TYPE
bd dep add $WIRE_SPREADS_NIM $RESTRUCTURE_BOXY_TYPE
bd dep add $NIMBLE_WINDY_BYPASS $BUILD_SCRIPT

# ============================================================
# Phase 5 — Example, Gates, Docs
# ============================================================

BASIC_3DS_EXAMPLE=$(bd create "Create examples/basic_3ds.nim: newBoxy → addImage → drawImage" \
  -d "Create examples/basic_3ds.nim: minimal boxy program for 3DS. Structure: (1) import boxy, libctru_gfx bindings, libctru_hid bindings; (2) gfxInitDefault; (3) newBoxy(400, 240); (4) load a test image from RomFS (romfs:/test.png) via pixie; (5) bx.addImage(\"test\", image); (6) main loop: aptMainLoop check, hidScanInput, bx.beginFrame, bx.drawImage(\"test\", vec2(10,10)), bx.endFrame, gfxSwapBuffers; (7) exit on KEY_START. RomFS layout: romfs/test.png (a small test image committed to examples/data/). Note: main loop ownership stays in the example (not boxy) — consistent with boxy's existing host-owns-the-loop design. Script build_3ds.sh must be updated to point to this example." \
  -p 1 -l impl --silent)

ATLAS_DRAWIMAGE_GATE=$(bd create "Verify atlas+drawImage gate: basic_3ds.nim renders on Azahar (milestone 5)" \
  -d "Run basic_3ds.nim through the full build pipeline and verify on Azahar: newBoxy → addImage → drawImage renders a visible image at 400×240 with NormalBlend. Also verify: the same source file compiles and displays correctly on macOS via the OpenGL path ('nim r examples/basic_3ds.nim' without --define:ds3 after adding desktop windowing to the example). Check that the PICA200 rotated projection is correct (image appears upright, not sideways). Success Criteria milestone 5." \
  -p 0 -l testing --silent)

RTT_GATE=$(bd create "Verify RTT gate: pushLayer/popLayer NormalBlend round-trip on Azahar (milestone 6)" \
  -d "Write a test .3dsx (or extend basic_3ds.nim) that exercises the full RTT path: bx.pushLayer(), bx.drawImage(...), bx.popLayer(blendMode=NormalBlend). Verify pixel output is correct on Azahar — the composited layer should appear correctly over the base render. The test MUST explicitly use blendMode=NormalBlend (this is the only mode that exercises the full RTT path without requiring infeasible fragment shading). MaskBlend and ScreenBlend are separately verifiable only if their TEV implementations are complete. Success Criteria milestone 6." \
  -p 0 -l testing --silent)

REGRESSION_GATE=$(bd create "Verify regression gate: desktop examples compile and run on macOS (milestone 7)" \
  -d "After all 'when defined(ds3):' changes are applied, verify all existing desktop examples compile and run unchanged on macOS: 'nim r examples/basic_windy.nim', 'nim r examples/basic_glfw.nim', 'nim r examples/basic_sdl2.nim'. Also spot-check: examples/blending.nim (exercises blend modes), examples/blur.nim (exercises blurEffect), examples/masking.nim (exercises MaskBlend). The 'when defined(ds3):' guards must be transparent — no regressions on non-ds3 builds. Success Criteria milestone 7." \
  -p 0 -l testing --silent)

PARTIAL_API_DOCS=$(bd create "Document partial-API table and 3DS build prerequisites in README" \
  -d "Update README.md with: (1) Partial-API table: which boxy features work on 3DS (Normal/Multiply/Screen/Add blend modes, drawImage, pushLayer/popLayer with NormalBlend, addImage) vs. which are no-ops with warnings (all other blend modes → NormalBlend fallback, MaskBlend → degraded without maskShader, blurEffect, spreadEffect, dropShadowEffect, readImage, getImage, readAtlas, writeFile, enterRawOpenGLMode, exitRawOpenGLMode); (2) Build prerequisites: devkitPro devkitARM, citro3d, picasso, 3dsxtool, Azahar emulator; (3) Build steps: 'chmod +x scripts/build_3ds.sh && scripts/build_3ds.sh examples/basic_3ds.nim'; (4) Known constraints: atlas maxAtlasSize cap (VRAM budget), layer count cap, pixie cross-compilation status and any fallback applied." \
  -p 2 -l docs --silent)

# Phase 5 dependencies
bd dep add $BASIC_3DS_EXAMPLE $WIRE_BOXY_NIM
bd dep add $BASIC_3DS_EXAMPLE $WIRE_SHADERS_NIM
bd dep add $BASIC_3DS_EXAMPLE $WIRE_BUFFERS_NIM
bd dep add $BASIC_3DS_EXAMPLE $WIRE_TEXTURES_NIM
bd dep add $BASIC_3DS_EXAMPLE $WIRE_BLENDS_NIM
bd dep add $BASIC_3DS_EXAMPLE $WIRE_BLURS_NIM
bd dep add $BASIC_3DS_EXAMPLE $WIRE_SPREADS_NIM
bd dep add $BASIC_3DS_EXAMPLE $NIMBLE_WINDY_BYPASS
bd dep add $BASIC_3DS_EXAMPLE $PIXIE_CROSS_GATE
bd dep add $ATLAS_DRAWIMAGE_GATE $BASIC_3DS_EXAMPLE
bd dep add $RTT_GATE $ATLAS_DRAWIMAGE_GATE
bd dep add $REGRESSION_GATE $WIRE_BOXY_NIM
bd dep add $REGRESSION_GATE $WIRE_SHADERS_NIM
bd dep add $REGRESSION_GATE $WIRE_BUFFERS_NIM
bd dep add $REGRESSION_GATE $WIRE_TEXTURES_NIM
bd dep add $REGRESSION_GATE $WIRE_BLENDS_NIM
bd dep add $REGRESSION_GATE $WIRE_BLURS_NIM
bd dep add $REGRESSION_GATE $WIRE_SPREADS_NIM
bd dep add $PARTIAL_API_DOCS $TEV_BLENDMODES
bd dep add $PARTIAL_API_DOCS $WIRE_BLENDS_NIM
bd dep add $PARTIAL_API_DOCS $WIRE_BLURS_NIM
bd dep add $PARTIAL_API_DOCS $WIRE_SPREADS_NIM
bd dep add $PARTIAL_API_DOCS $RTT_GATE

echo ""
echo "3DS citro3d task graph created! View with:"
echo "  bd ready              # List unblocked tasks (start here)"
echo "  bd graph              # Show full dependency graph"
echo "  bd list               # List all beads"
