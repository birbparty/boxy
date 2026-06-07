## Tests for shaders/render2d.v.pica — the committed PICA200 2D vertex shader.
##
## Two tiers, mirroring Shady's own tests/test_pica.nim (skip-when-absent):
##
##  1. ALWAYS (no Shady branch required, only a file read + optional picasso):
##     - the committed .v.pica carries every ABI token the citro3d backend binds
##       to (uniform-by-name, v0/v1/v2 attribute registers, output semantics);
##     - if picasso is on PATH, the committed file assembles and the .shbin lands
##       in the expected size class (~328 bytes). Skipped (not failed) otherwise.
##
##  2. -d:picaDriftCheck (needs the Shady toPica branch + picasso): regenerate
##     via tools/gen_render2d_pica.nim and assert byte-equality with the committed
##     file, so the artifact can't drift from its Nim source of truth.
##       SHADY_SRC overrides the default $HOME/git/shady/src.
##
## Usage:
##   nim c -r tests/test_render2d_pica.nim                  # tier 1
##   nim c -d:picaDriftCheck -r tests/test_render2d_pica.nim # tier 1 + 2

import std/[os, osproc, strutils]

const repoRoot = currentSourcePath.parentDir.parentDir
const shaderPath = repoRoot / "shaders" / "render2d.v.pica"

var failures = 0

proc check(cond: bool, msg: string) =
  if cond:
    echo "PASS: ", msg
  else:
    echo "FAIL: ", msg
    inc failures

proc skip(msg: string) =
  echo "SKIP: ", msg

# ---------------------------------------------------------------------------
# Tier 1a: ABI tokens (host binds to these; assert only ABI-bound surface, NOT
# Shady's internal alias/constant names or register allocation).
# ---------------------------------------------------------------------------
let src = readFile(shaderPath)

check(".fvec projection[4]" in src,
  "uniform declared by name: .fvec projection[4]")

# Attribute register order: position->v0, uv->v1, color->v2. Shady names each
# input alias after the proc parameter, so these alias lines double as a
# semantic check — a parameter reorder in render2dVert would change them and is
# caught here without needing the Shady branch (the byte-exact tier-2 drift
# check catches it too, but only when the branch is present). If Shady ever
# changes its alias-naming convention this assertion will fail loudly and the
# expected names below should be updated to match (the ABI itself binds by
# register, not alias, so such a change is not an ABI break).
check(".alias inPos v0" in src, "attribute: inPos -> v0 (position)")
check(".alias inUv v1" in src, "attribute: inUv -> v1 (uv)")
check(".alias inColor v2" in src, "attribute: inColor -> v2 (color)")

check(".out outpos position" in src, "output semantic: outpos position")
check(".out outtc0 texcoord0" in src, "output semantic: outtc0 texcoord0")
check(".out outclr color" in src, "output semantic: outclr color")

check("DO NOT EDIT" in src, "generated-file banner present")

# ---------------------------------------------------------------------------
# Tier 1b: assemble oracle (cheap, strong) — only when picasso is available.
# ---------------------------------------------------------------------------
let picasso = findExe("picasso")
if picasso.len == 0:
  skip("picasso not on PATH — assemble oracle skipped")
else:
  let outShbin = getTempDir() / "boxy_render2d_test.shbin"
  let (outp, code) = execCmdEx(
    picasso & " " & quoteShell(shaderPath) & " -o " & quoteShell(outShbin))
  check(code == 0, "committed .v.pica assembles via picasso")
  if code != 0:
    echo "  picasso output:\n", outp
  elif fileExists(outShbin):
    let sz = getFileSize(outShbin)
    # Requester observed 328 bytes; assert the same size class, not an exact
    # byte count (allocation/constant pooling could shift it slightly).
    check(sz > 200 and sz < 512,
      "assembled .shbin in expected size class (got " & $sz & " bytes)")
    removeFile(outShbin)

# ---------------------------------------------------------------------------
# Tier 2: drift check — committed file must equal a fresh regeneration.
# Gated: needs the Shady toPica branch + picasso, so it stays off by default.
# ---------------------------------------------------------------------------
when defined(picaDriftCheck):
  proc normalize(s: string): string =
    ## Tolerate trailing-whitespace / line-ending noise; compare content.
    var lines: seq[string]
    for line in s.splitLines: lines.add line.strip(leading = false)
    while lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)
    lines.join("\n")

  let nim = findExe("nim")
  let shadySrc = getEnv("SHADY_SRC", getHomeDir() / "git" / "shady" / "src")
  if nim.len == 0:
    skip("nim not on PATH — drift check skipped")
  elif not dirExists(shadySrc):
    skip("Shady src not found at " & shadySrc & " (set SHADY_SRC) — drift check skipped")
  elif picasso.len == 0:
    skip("picasso not on PATH — drift check skipped")
  else:
    let gen = repoRoot / "tools" / "gen_render2d_pica.nim"
    let tmpOut = getTempDir() / "boxy_render2d_regen.v.pica"
    let cmd = nim & " r --hints:off -d:shadyNoPixie --path:" &
      quoteShell(shadySrc) & " " & quoteShell(gen) & " " & quoteShell(tmpOut)
    let (outp, code) = execCmdEx(cmd)
    check(code == 0, "generator runs (tools/gen_render2d_pica.nim)")
    if code != 0:
      echo "  generator output:\n", outp
    elif fileExists(tmpOut):
      let regen = normalize(readFile(tmpOut))
      let committed = normalize(src)
      check(regen == committed,
        "committed shaders/render2d.v.pica matches fresh regeneration")
      if regen != committed:
        echo "  DRIFT: regenerate and commit with:"
        echo "    nim r -d:shadyNoPixie --path:" & shadySrc &
          " tools/gen_render2d_pica.nim shaders/render2d.v.pica"
      removeFile(tmpOut)
else:
  skip("drift check off (compile with -d:picaDriftCheck to enable)")

if failures > 0:
  echo failures, " check(s) FAILED"
  quit(1)
echo "All render2d.v.pica checks passed."
