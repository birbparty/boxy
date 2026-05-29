#!/usr/bin/env bash
# Nintendo 3DS build pipeline for boxy examples
#
# Pipeline stages:
#   1. nim compile --define:ds3 --config:nim_3ds.cfg  →  build/<name>.elf
#   2. picasso shaders/render2d.v.pica                →  build/render2d.shbin  (if present)
#   3. smdhtool / bannertool                          →  build/<name>.smdh     (if icons present)
#   4. 3dsxtool                                       →  build/<name>.3dsx
#
# Usage:
#   scripts/build_3ds.sh [<target.nim>] [<output-name>]
#
#   target.nim   Nim source file to compile (default: examples/basic_windy.nim)
#   output-name  Base name for .elf / .3dsx / .smdh   (default: boxy3ds)
#
# Prerequisites (install via dkp-pacman -S 3ds-dev):
#   - arm-none-eabi-ar   (from devkitARM)
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
# for ARMv6K.  Other nimble deps (bitty, shady) must already be installed in
# the nimble cache (~/.nimble/pkgs) before running this script.

set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-examples/basic_windy.nim}"
APP_NAME="${2:-boxy3ds}"
BUILD_DIR="build"
ROMFS_DIR="romfs"

# devkitPro environment
export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export DEVKITARM="${DEVKITARM:-$DEVKITPRO/devkitARM}"
export PATH="$DEVKITPRO/tools/bin:$DEVKITARM/bin:$PATH"

# --- toolchain gate ---
for cmd in 3dsxtool arm-none-eabi-ar; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd not found." >&2
    echo "Install devkitPro 3ds-dev and set DEVKITPRO:" >&2
    echo "  dkp-pacman -S 3ds-dev" >&2
    echo "  export DEVKITPRO=/opt/devkitpro" >&2
    exit 1
  fi
done

mkdir -p "$BUILD_DIR"
mkdir -p "$ROMFS_DIR"

# libdl.a stub — Nim injects -ldl for --os:linux targets; 3DS has no libdl.
# nim_3ds.cfg passes -L. so the linker finds this stub in the project root.
"$DEVKITARM/bin/arm-none-eabi-ar" rcs libdl.a
trap 'rm -f libdl.a' EXIT

# --- stage 1: compile Nim → ELF ---
echo "Compiling $TARGET for Nintendo 3DS..."
nim compile \
  --define:ds3 \
  --config:nim_3ds.cfg \
  -o:"$BUILD_DIR/$APP_NAME.elf" \
  "$TARGET"

# --- stage 2: PICA200 vertex shader (optional) ---
if [[ -f "shaders/render2d.v.pica" ]]; then
  if command -v picasso &>/dev/null; then
    echo "Compiling PICA200 vertex shader..."
    picasso shaders/render2d.v.pica -o "$BUILD_DIR/render2d.shbin"
  else
    echo "Warning: picasso not found — skipping shader compilation." >&2
    echo "  Install via: dkp-pacman -S 3ds-dev" >&2
  fi
fi

# --- stage 3: SMDH metadata (optional, requires icon assets) ---
ICON48="${ICON48:-assets/icon48.png}"
ICON24="${ICON24:-assets/icon24.png}"
SMDH_TITLE="${SMDH_TITLE:-$APP_NAME}"
SMDH_DESC="${SMDH_DESC:-Boxy 2D rendering}"
SMDH_AUTHOR="${SMDH_AUTHOR:-boxy}"

if [[ -f "$ICON48" && -f "$ICON24" ]]; then
  echo "Generating SMDH metadata..."
  if command -v bannertool &>/dev/null; then
    bannertool makesmdh \
      -s "$SMDH_TITLE" -l "$SMDH_DESC" -p "$SMDH_AUTHOR" \
      -i "$ICON48" -si "$ICON24" \
      -o "$BUILD_DIR/$APP_NAME.smdh"
  elif command -v smdhtool &>/dev/null; then
    smdhtool --create "$SMDH_TITLE" "$SMDH_DESC" "$SMDH_AUTHOR" \
      "$ICON48" "$BUILD_DIR/$APP_NAME.smdh" "$ICON24"
  else
    echo "Warning: neither bannertool nor smdhtool found — skipping SMDH." >&2
  fi
else
  echo "Note: icon assets not found ($ICON48, $ICON24) — building .3dsx without SMDH." >&2
  echo "  Set ICON48 and ICON24 env vars to provide icons." >&2
fi

# --- stage 4: package .3dsx ---
echo "Packaging .3dsx..."
TOOL_ARGS=("$BUILD_DIR/$APP_NAME.elf" "$BUILD_DIR/$APP_NAME.3dsx")
[[ -f "$BUILD_DIR/$APP_NAME.smdh" ]] && TOOL_ARGS+=("--smdh=$BUILD_DIR/$APP_NAME.smdh")
TOOL_ARGS+=("--romfs=$ROMFS_DIR")
3dsxtool "${TOOL_ARGS[@]}"

echo "Done. Output: $BUILD_DIR/$APP_NAME.3dsx"
