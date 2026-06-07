#!/usr/bin/env bash
# Nintendo 3DS build pipeline for boxy examples
#
# Pipeline stages:
#   1. picasso shaders/render2d.v.pica                         →  build/render2d.shbin  (if present)
#   2. nim compile --define:ds3 (nim_3ds.cfg copied → nim.cfg) →  build/<name>.elf
#   3. smdhtool / bannertool                                   →  build/<name>.smdh     (if icons present)
#   4. 3dsxtool                                                →  build/<name>.3dsx
#
# NOTE: Shader (stage 1) precedes Nim compile (stage 2) so that staticRead("../build/render2d.shbin")
# in example files resolves correctly at compile time.
#
# Usage:
#   scripts/build_3ds.sh <target.nim> [<output-name>]
#
#   target.nim   Nim source file to compile (e.g. examples/basic_3ds.nim)
#   output-name  Base name for .elf / .3dsx / .smdh   (default: boxy3ds)
#
# Example (milestone 5 — full boxy API gate):
#   scripts/build_3ds.sh examples/basic_3ds.nim basic_3ds
#
# Prerequisites (install via dkp-pacman -S 3ds-dev):
#   - nim            (Nim compiler, in PATH)
#   - arm-none-eabi-ar   (from devkitARM — GNU ar, not BSD ar; needed for the libdl stub)
#   - 3dsxtool           (from 3dstools)
#   - picasso            (from 3dstools)
#   - smdhtool           (from 3dstools) or bannertool
#
# Environment:
#   DEVKITPRO   devkitPro root (default: /opt/devkitpro)
#   DEVKITARM   devkitARM toolchain (default: $DEVKITPRO/devkitARM)
#
# NOTE: This script calls 'nim compile' directly — NOT 'nimble build' — to
# skip nimble dependency resolution for windy, which does not cross-compile
# for ARMv6K.  Other nimble deps (bitty, pixie) must already be installed in
# the nimble cache (~/.nimble/pkgs) before running this script.
# Note: shady is desktop-only (guarded by 'when not defined(ds3)') and is NOT
# required for 3DS builds.
#
# NOTE: nim_3ds.cfg is copied to nim.cfg so Nim auto-discovers it.  Nim has
# no --config flag; auto-discovery is the only supported mechanism.  nim.cfg
# is removed on EXIT by the cleanup trap and must not be edited directly.

set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
  echo "Error: no target specified." >&2
  echo "Usage: scripts/build_3ds.sh <target.nim> [<output-name>]" >&2
  echo "No 3DS-ready example exists yet; pass a ds3-guarded .nim source." >&2
  exit 1
fi

TARGET="$1"
APP_NAME="${2:-boxy3ds}"
BUILD_DIR="build"
ROMFS_DIR="romfs"

# devkitPro environment
export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export DEVKITARM="${DEVKITARM:-$DEVKITPRO/devkitARM}"
export PATH="$DEVKITPRO/tools/bin:$DEVKITARM/bin:$PATH"

# --- toolchain gate ---
for cmd in nim 3dsxtool arm-none-eabi-ar; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd not found." >&2
    echo "Install devkitPro 3ds-dev and ensure nim is in PATH:" >&2
    echo "  dkp-pacman -S 3ds-dev" >&2
    echo "  export DEVKITPRO=/opt/devkitpro" >&2
    exit 1
  fi
done

mkdir -p "$BUILD_DIR"
mkdir -p "$ROMFS_DIR"

# nim_3ds.cfg → nim.cfg: Nim loads nim.cfg by auto-discovery (no --config flag exists).
# Guard against clobbering a user-created nim.cfg — the project has none, but be safe.
if [[ -f nim.cfg ]]; then
  echo "Error: nim.cfg already exists in the project root." >&2
  echo "This script needs to write nim.cfg for cross-compilation. Remove or rename it first." >&2
  exit 1
fi
cp nim_3ds.cfg nim.cfg

# Stub archives for POSIX libraries Nim injects but 3DS lacks.
# nim_3ds.cfg passes -L. so the linker finds these stubs in the project root.
# Uses arm-none-eabi-ar (GNU ar from devkitARM) — BSD ar rejects zero-member archives.
#   libdl.a  — Nim injects -ldl for --os:linux targets
#   librt.a  — pixie/times.nim triggers -lrt (POSIX realtime extensions)
# WARNING: these are EMPTY stubs. Any code that calls symbols from these
# libraries (e.g. clock_gettime from librt) will link but crash at runtime.
# Do not add real realtime-clock or dynamic-linking dependencies to 3DS builds.
"$DEVKITARM/bin/arm-none-eabi-ar" rcs libdl.a
"$DEVKITARM/bin/arm-none-eabi-ar" rcs librt.a

trap 'rm -f libdl.a librt.a nim.cfg' EXIT

# --- stage 0 (opt-in): regenerate shaders/render2d.v.pica from its Nim source ---
# Off by default — the committed shaders/render2d.v.pica is authoritative, so a
# normal/CI build needs neither Nim-on-host nor the (unmerged) Shady toPica
# branch. Set REGEN_SHADER=1 to regenerate from tools/gen_render2d_pica.nim
# before assembling. SHADY_SRC overrides the Shady checkout path.
# Fails SOFT: a regen failure only warns. Note `toPica` runs at the generator's
# Nim-compile time (a `const`), so a failed regen aborts BEFORE the file is
# rewritten — the committed file is left intact (no partial/truncated write).
# If a successful-but-wrong regen ever emitted a bad shader, stage 1's picasso
# call below fails loudly (exit 1); a broken shader can never ship silently.
if [[ "${REGEN_SHADER:-0}" == "1" ]]; then
  SHADY_SRC="${SHADY_SRC:-$HOME/git/shady/src}"
  if command -v nim &>/dev/null && [[ -d "$SHADY_SRC" ]]; then
    echo "Regenerating shaders/render2d.v.pica (REGEN_SHADER=1)..."
    if nim r --hints:off -d:shadyNoPixie --path:"$SHADY_SRC" \
        tools/gen_render2d_pica.nim shaders/render2d.v.pica; then
      echo "Regenerated shaders/render2d.v.pica from tools/gen_render2d_pica.nim"
    else
      echo "Warning: shader regen failed — keeping committed shaders/render2d.v.pica." >&2
    fi
  else
    echo "Warning: REGEN_SHADER=1 but nim or Shady src ($SHADY_SRC) missing — keeping committed .v.pica." >&2
  fi
fi

# --- stage 1: PICA200 vertex shader (must precede Nim compile so staticRead finds the .shbin) ---
if [[ -f "shaders/render2d.v.pica" ]]; then
  if command -v picasso &>/dev/null; then
    echo "Compiling PICA200 vertex shader..."
    picasso shaders/render2d.v.pica -o "$BUILD_DIR/render2d.shbin"
  else
    echo "Error: picasso not found but shaders/render2d.v.pica exists." >&2
    echo "  The .shbin is staticRead at Nim compile time; the build will fail without it." >&2
    echo "  Install via: dkp-pacman -S 3ds-dev" >&2
    exit 1
  fi
fi

# --- stage 2: compile Nim → ELF ---
echo "Compiling $TARGET for Nintendo 3DS..."
nim compile \
  --define:ds3 \
  -o:"$BUILD_DIR/$APP_NAME.elf" \
  "$TARGET"

# --- stage 3: SMDH metadata ---
# 3dsxtool REQUIRES an SMDH whenever --romfs is passed (otherwise it fails with
# the misleading "Cannot open SMDH file!"). Examples that read from romfs:/ — e.g.
# basic_3ds.nim, clckr_surface_3ds.nim — therefore need an SMDH. We always try to
# generate one, falling back to devkitPro's stock icon so a fresh clone builds
# without committing binary icon assets (assets/ is .gitignore'd).
#
# NOTE: bannertool and smdhtool arg order validated against bannertool 1.1.1 and
# smdhtool 0.0.1. Verify with --help if your installed versions differ.
# The small (24x24) icon is OPTIONAL for smdhtool; bannertool needs both.
ICON48="${ICON48:-assets/icon48.png}"
ICON24="${ICON24:-assets/icon24.png}"
# Fall back to libctru's stock 48x48 icon when no project icon is provided.
DEFAULT_ICON="$DEVKITPRO/libctru/default_icon.png"
if [[ ! -f "$ICON48" && -f "$DEFAULT_ICON" ]]; then
  ICON48="$DEFAULT_ICON"
fi
SMDH_TITLE="${SMDH_TITLE:-$APP_NAME}"
SMDH_DESC="${SMDH_DESC:-Boxy 2D rendering}"
SMDH_AUTHOR="${SMDH_AUTHOR:-boxy}"

if [[ -f "$ICON48" ]]; then
  echo "Generating SMDH metadata (icon: $ICON48)..."
  if command -v bannertool &>/dev/null && [[ -f "$ICON24" ]]; then
    bannertool makesmdh \
      -s "$SMDH_TITLE" -l "$SMDH_DESC" -p "$SMDH_AUTHOR" \
      -i "$ICON48" -si "$ICON24" \
      -o "$BUILD_DIR/$APP_NAME.smdh"
  elif command -v smdhtool &>/dev/null; then
    # smdhtool's trailing small-icon arg is optional; pass ICON24 only if present.
    if [[ -f "$ICON24" ]]; then
      smdhtool --create "$SMDH_TITLE" "$SMDH_DESC" "$SMDH_AUTHOR" \
        "$ICON48" "$BUILD_DIR/$APP_NAME.smdh" "$ICON24"
    else
      smdhtool --create "$SMDH_TITLE" "$SMDH_DESC" "$SMDH_AUTHOR" \
        "$ICON48" "$BUILD_DIR/$APP_NAME.smdh"
    fi
  else
    echo "Warning: neither bannertool nor smdhtool found — skipping SMDH." >&2
    echo "  3dsxtool will fail if this target reads from romfs:/." >&2
  fi
else
  echo "Note: no icon found (looked for $ICON48 and $DEFAULT_ICON) — building without SMDH." >&2
  echo "  Set ICON48 (and optionally ICON24) to provide one. romfs targets require an SMDH." >&2
fi

# --- stage 4: package .3dsx ---
echo "Packaging .3dsx..."
TOOL_ARGS=("$BUILD_DIR/$APP_NAME.elf" "$BUILD_DIR/$APP_NAME.3dsx")

# Determine if romfs will be included (non-empty directory).
ROMFS_ARGS=()
if [[ -n "$(find "$ROMFS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
  ROMFS_ARGS+=("--romfs=$ROMFS_DIR")
fi

# Add SMDH if available.
# NOTE: some versions of 3dsxtool require an SMDH when --romfs is specified
# and emit the misleading "Cannot open SMDH file!" error when it is absent.
# Workaround: if no per-target SMDH was generated but romfs is needed, fall
# back to any existing SMDH in the build directory.
if [[ -f "$BUILD_DIR/$APP_NAME.smdh" ]]; then
  TOOL_ARGS+=("--smdh=$BUILD_DIR/$APP_NAME.smdh")
elif [[ ${#ROMFS_ARGS[@]} -gt 0 ]]; then
  FALLBACK_SMDH=$(find "$BUILD_DIR" -maxdepth 1 -name "*.smdh" | head -1)
  if [[ -n "$FALLBACK_SMDH" ]]; then
    echo "Note: using fallback SMDH ($FALLBACK_SMDH) — no per-target SMDH generated." >&2
    TOOL_ARGS+=("--smdh=$FALLBACK_SMDH")
  else
    echo "Warning: romfs requested but no SMDH available; 3dsxtool may fail." >&2
    echo "  Run 'scripts/build_3ds.sh examples/basic_3ds.nim basic_3ds' with icons first," >&2
    echo "  or set ICON48 and ICON24 env vars to generate a new SMDH." >&2
  fi
fi

TOOL_ARGS+=("${ROMFS_ARGS[@]}")
3dsxtool "${TOOL_ARGS[@]}"

echo "Built: $BUILD_DIR/$APP_NAME.3dsx"
