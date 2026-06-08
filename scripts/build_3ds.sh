#!/usr/bin/env bash
# Nintendo 3DS build pipeline for boxy examples
#
# Pipeline stages:
#   0. resolve pinned Shady (clean checkout of birbparty/shady@$SHADY_COMMIT)
#   1. nim compile --define:ds3 (nim_3ds.cfg copied → nim.cfg) →  build/<name>.elf
#        The PICA200 vertex shader is assembled INLINE during this compile by
#        Shady's toPicaShbin (src/boxy/backends/render2d_pica.nim), which runs
#        picasso via staticExec — there is no separate .v.pica/.shbin file.
#   2. smdhtool / bannertool                                   →  build/<name>.smdh  (if icons present)
#   3. 3dsxtool                                                →  build/<name>.3dsx
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
#   - picasso            (from 3dstools) — invoked by Shady toPicaShbin at Nim-compile time
#   - smdhtool           (from 3dstools) or bannertool
#   - git                (to fetch the pinned Shady commit from public GitHub)
#
# Environment:
#   DEVKITPRO   devkitPro root (default: /opt/devkitpro)
#   DEVKITARM   devkitARM toolchain (default: $DEVKITPRO/devkitARM)
#   SHADY_SRC   override: REPO ROOT of a shady checkout at the pinned commit
#               (the script uses its src/ subdir and verifies HEAD == the pin).
#               If unset, the script clones the pinned commit into build/shady-pin.
#               Do NOT point this at a dirty/working shady tree; set
#               SHADY_ALLOW_ANY=1 only to deliberately build against another commit.
#
# NOTE: This script calls 'nim compile' directly — NOT 'nimble build' — to
# skip nimble dependency resolution for windy, which does not cross-compile
# for ARMv6K.  Other nimble deps (bitty, pixie) must already be installed in
# the nimble cache (~/.nimble/pkgs) before running this script.
# The ds3 build imports Shady ONLY for toPicaShbin codegen (under -d:shadyNoPixie,
# set in nim_3ds.cfg, so pixie's CPU-sim runtime never enters the ARM binary).
# Shady is pinned (below) to a specific public commit that has toPicaShbin;
# released/upstream Shady does not. Desktop builds are unaffected — they use the
# nimby.lock / nimble Shady and never call toPicaShbin.
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
# picasso is required at Nim-compile time: Shady's toPicaShbin invokes it via
# staticExec to assemble the vertex shader inline. git is needed to fetch the
# pinned Shady commit.
for cmd in nim 3dsxtool arm-none-eabi-ar picasso git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd not found." >&2
    echo "Install devkitPro 3ds-dev and ensure nim/git are in PATH:" >&2
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

# --- stage 0: resolve pinned Shady (for toPicaShbin codegen) ---
# The PICA200 vertex shader is assembled inline at Nim-compile time by Shady's
# toPicaShbin (src/boxy/backends/render2d_pica.nim). That macro exists only on
# Shady's PICA200 branch, so we pin a SPECIFIC public commit — not the moving
# branch tip (which has at times been mid-development and not compiled).
#
# SHADY_COMMIT: last commit verified to build both desktop and ds3 + has
# toPicaShbin. Bump deliberately after verifying a newer commit.
#
# DURABILITY: this pin is a bare SHA reachable via $SHADY_BRANCH. If that branch
# is ever rebased/force-pushed so this commit becomes unreachable, a fresh clone
# can no longer fetch it. For long-term stability, ask the shady maintainer to
# cut an IMMUTABLE TAG at this commit and switch SHADY_BRANCH to that tag name
# (git clone --branch <tag> is then exact and rebase-proof).
SHADY_REPO="https://github.com/birbparty/shady.git"
SHADY_BRANCH="matt.spurlin/3ds-pica200-support"
SHADY_COMMIT="061cf6b90ba6c8ffc99921d9dca752bb2f0c7b5d"

if [[ -n "${SHADY_SRC:-}" ]]; then
  # Caller-provided checkout. SHADY_SRC is the REPO ROOT of a shady clone.
  # We verify it is at the pinned commit and (warn if) not clean, then use its
  # src/ subdir for --path. Override the commit check with SHADY_ALLOW_ANY=1.
  if [[ ! -d "$SHADY_SRC/src" ]]; then
    echo "Error: SHADY_SRC=$SHADY_SRC is not a shady repo root (no src/ dir)." >&2
    echo "  Point SHADY_SRC at the root of a clean shady checkout @ ${SHADY_COMMIT:0:9}." >&2
    exit 1
  fi
  src_head="$(git -C "$SHADY_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ "$src_head" != "$SHADY_COMMIT" && "${SHADY_ALLOW_ANY:-0}" != "1" ]]; then
    echo "Error: SHADY_SRC is at $src_head, not the pinned ${SHADY_COMMIT}." >&2
    echo "  Check out the pin (git -C \"$SHADY_SRC\" checkout $SHADY_COMMIT)," >&2
    echo "  unset SHADY_SRC to auto-fetch the pin, or set SHADY_ALLOW_ANY=1 to override." >&2
    exit 1
  fi
  if ! git -C "$SHADY_SRC" diff --quiet 2>/dev/null; then
    echo "Warning: SHADY_SRC working tree is dirty — building against uncommitted shady edits." >&2
  fi
  echo "Using caller-provided Shady at $SHADY_SRC (@ ${src_head:0:9})."
  SHADY_PATH="$SHADY_SRC/src"
else
  # Clone/checkout the pinned commit into build/shady-pin (gitignored).
  SHADY_PIN_DIR="$BUILD_DIR/shady-pin"
  if [[ "$(git -C "$SHADY_PIN_DIR" rev-parse HEAD 2>/dev/null)" != "$SHADY_COMMIT" ]]; then
    echo "Fetching pinned Shady ${SHADY_COMMIT:0:9} from $SHADY_REPO ..."
    rm -rf "$SHADY_PIN_DIR"
    git clone --quiet --branch "$SHADY_BRANCH" "$SHADY_REPO" "$SHADY_PIN_DIR"
    git -C "$SHADY_PIN_DIR" checkout --quiet "$SHADY_COMMIT"
  fi
  echo "Pinned Shady ready at $SHADY_PIN_DIR (@ ${SHADY_COMMIT:0:9})."
  SHADY_PATH="$SHADY_PIN_DIR/src"
fi

# --- stage 1: compile Nim → ELF (assembles the shader inline via toPicaShbin) ---
echo "Compiling $TARGET for Nintendo 3DS..."
nim compile \
  --define:ds3 \
  --path:"$SHADY_PATH" \
  -o:"$BUILD_DIR/$APP_NAME.elf" \
  "$TARGET"

# --- stage 2: SMDH metadata ---
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

# --- stage 3: package .3dsx ---
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
