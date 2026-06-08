## render2d_pica.nim — boxy's PICA200 2D vertex shader, single source of truth.
##
## ds3-only. The `render2dVert` Nim proc below is the authoritative shader; it is
## compiled to a PICA200 `.shbin` at Nim-compile time by Shady's `toPicaShbin`
## macro (which runs `picasso` via staticExec) and embedded inline. No committed
## `.v.pica`, no separate picasso build stage, no `staticRead` of a build file —
## one source of truth, assembled on every ds3 build.
##
## Compile-time requirements (ds3 build only — see scripts/build_3ds.sh):
##   - Shady with `toPicaShbin` on the Nim path. Pinned to the public commit
##     github.com/birbparty/shady@061cf6b (branch matt.spurlin/3ds-pica200-support).
##     Released Shady does NOT have it; build_3ds.sh provides it via --path to a
##     clean checkout of that commit.
##   - `-d:shadyNoPixie` (set in nim_3ds.cfg) so Shady's pixie-dependent CPU-sim
##     runtime is not compiled into the ARM binary. `toPicaShbin` codegen needs
##     no pixie.
##   - `picasso` (devkitPro) on PATH at compile time; build_3ds.sh puts it there.
##
## Guarded `when defined(ds3)` so non-ds3 tooling (desktop build, `nim doc
## --project`, LSP) never imports Shady's PICA backend or invokes picasso.
##
## NOTE: type-check the ds3 surface with `nim compile`, NOT `nim check` — Shady's
## toPicaShbin uses staticExec+error(), which `nim check` mis-handles (spurious
## "picasso failed") even when picasso assembles fine.
##
## ABI contract the citro3d backend binds to (see citro3d_backend.nim):
##   - uniform by name: `projection` (-> .fvec projection[4])
##   - attribute order: inPos->v0 (position), inUv->v1 (uv), inColor->v2 (color);
##     Shady assigns v-registers in parameter order, so the param order is ABI.
##   - outputs: position / texcoord0 / color
##   - color: GPU_UNSIGNED_BYTE is un-normalized on PICA200, so the shader maps
##     [0,255] -> [0,1] via *1/255 and clamps with min(...,1).

when defined(ds3):
  import shady, vmath

  proc render2dVert(
    gl_Position: var Vec4,
    projection: Uniform[Mat4],
    inPos: Vec2,
    inUv: Vec2,
    inColor: Vec4,
    outUv: var Vec2,
    outColor: var Vec4
  ) =
    gl_Position = projection * vec4(inPos.x, inPos.y, 0.0, 1.0)
    outUv = inUv
    outColor = min(inColor * (1.0/255.0), vec4(1.0, 1.0, 1.0, 1.0))

  ## The assembled `.shbin` bytes (DVLB container), ready for DVLB_ParseFile.
  ## Errors loudly at compile time with picasso's diagnostics if assembly fails.
  const render2dShbin* = toPicaShbin(render2dVert)

  ## The picasso `.v.pica` assembly text, from the SAME proc. Exposed so the ABI
  ## guard test (tests/test_render2d_pica.nim) can assert the citro3d ABI tokens
  ## without duplicating render2dVert. Compile-time only; not used at runtime.
  const render2dPicaSrc* = toPica(render2dVert)
