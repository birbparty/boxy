# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

## 3DS Build & Verification

### Building 3DS examples

```bash
# Always use the build script — do NOT run nim compile directly for ds3
scripts/build_3ds.sh examples/<name>.nim <output>
# e.g.: scripts/build_3ds.sh examples/milestone6_3ds.nim milestone6_3ds
# Output: build/<output>.3dsx
```

The build script requires devkitARM (at `/opt/devkitpro/devkitARM`) and pre-built shaders.
It manages `nim.cfg` automatically via `nim_3ds.cfg`; do not edit `nim.cfg` directly.

**SMDH + romfs quirk:** If the `romfs/` directory is non-empty, some `3dsxtool` versions
require an SMDH file or they emit a misleading "Cannot open SMDH file!" error. The build
script auto-falls-back to any existing `build/*.smdh`. Build `basic_3ds` first if you
need a base SMDH.

### Running on Azahar (Nintendo 3DS emulator)

Azahar is installed at `/Applications/Azahar.app`.

```bash
# Launch a .3dsx
/Applications/Azahar.app/Contents/MacOS/azahar --windowed build/<name>.3dsx &
AZAHAR_PID=$!
```

**Screenshot workflow for verification:**

```bash
# 1. Launch Azahar in background, wait for it to render (5-6 seconds)
/Applications/Azahar.app/Contents/MacOS/azahar --windowed build/file.3dsx &
sleep 6
# 2. Bring Azahar to front
osascript -e 'tell application "System Events" to tell process "azahar" to set frontmost to true'
sleep 1
# 3. Full-screen capture (3024×1964 Retina)
screencapture -x /tmp/azahar_shot.png
# 4. Crop the Azahar 3DS display area (top-left window, game screen starts ~y=90px Retina)
ffmpeg -i /tmp/azahar_shot.png -vf "crop=800:700:0:90" /tmp/azahar_crop.png -y
# 5. Kill Azahar
kill $AZAHAR_PID 2>/dev/null || true
# 6. Read the cropped image
```

**Always kill all Azahar instances before starting a new run** to avoid accumulating background processes:
```bash
pkill -x azahar 2>/dev/null; sleep 1
```

**Comparison pattern:** Run `basic_3ds.3dsx` first to get a reference screenshot, then compare
against the feature under test. Both should show the same 4-quadrant test image
(Red TL, Green TR, Blue BL, Yellow BR) over dark blue (0x000080FF) background.

### PICA200 / citro3d rendering conventions (verified on Azahar 2026-06-04)

- **RTT framebuffer V-axis:** V=0 = bottom (standard GPU convention). The PICA200 rasterizer
  writes clip_y=+1 (logical top) to the HIGHEST V position in the texture, not V=0. Do NOT
  invert V in compositeLayer — the V=0=bottom mapping is correct.

- **Quad triangulation matters for partial composites.** `compositeLayer` renders the RTT as a
  full-screen quad split into two triangles by a diagonal. If the image falls entirely on one
  side of this diagonal, only one triangle shows image content (looks like a triangular cutout).
  Use vertex order `v0=BL, v1=BR, v2=TL, v3=TR` so the diagonal runs BR→TL (`clip_y=clip_x`),
  which bisects the typical image position and spans both triangles.

- **Single-flush-per-frame constraint:** The citro3d quad batch (`quadVtxBuf`) may only be
  submitted ONCE per C3D frame. On ds3, call `pushLayer` BEFORE any `drawImage`, and do NOT
  call `drawImage` after `popLayer` in the same frame. Violations raise `BoxyError` (enforced
  via the `ds3FlushUsed` guard in `boxy.nim`).

- **Layer RTT clear:** `bindTarget` clears the layer RTT unconditionally on every call
  (matching GL's per-push `clearColor()`). This prevents stale frame content from ghosting
  through transparent regions in reused RTTs.
