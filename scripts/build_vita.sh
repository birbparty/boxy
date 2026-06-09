#!/usr/bin/env bash
# boxy Sony PS Vita build: nim -> ARM ELF -> .velf -> eboot.bin -> param.sfo -> .vpk
#
# Usage:  scripts/build_vita.sh [src.nim] [TITLE_ID]
#   src.nim   default examples/vita_shader_spike.nim
#   TITLE_ID  default BOXY00001 (4 letters + 5 digits)
#
# Prereqs (see .agents/plans/vita-support/graphics-and-toolchain.md):
#   - VitaSDK at $VITASDK (default /usr/local/vitasdk); vdpm bootstrap
#   - vitaGL:  vdpm install vitaGL
#   - vita-aware opengl fork resolved by Nim:  (cd ~/git/opengl && nimble install -y)
set -euo pipefail
cd "$(dirname "$0")/.."

export VITASDK="${VITASDK:-/usr/local/vitasdk}"
export PATH="$VITASDK/bin:$PATH"
GCC="$VITASDK/bin/arm-vita-eabi-gcc"
AR="$VITASDK/bin/arm-vita-eabi-ar"

SRC="${1:-examples/vita_shader_spike.nim}"
BASE="$(basename "$SRC" .nim)"
TITLE_ID="${2:-BOXY00001}"
APP_TITLE="boxy $BASE"

# Toolchain-absent is a PASS for scope (exit 0), matching configy's gate — lets the
# repo's verification run on machines without VitaSDK without reporting a failure.
if [[ ! -x "$GCC" ]] || ! command -v vita-elf-create >/dev/null 2>&1 \
   || ! command -v vita-pack-vpk >/dev/null 2>&1; then
  echo "[build_vita] VitaSDK (arm-vita-eabi-gcc / vita-* tools) not found — skipping."
  echo "[build_vita] This is a PASS for scope (toolchain not installed)."
  exit 0
fi

cleanup() { rm -f nim.cfg librt.a "$BASE.velf" eboot.bin param.sfo; rm -rf vpk_stage; }
trap cleanup EXIT

# nim_vita.cfg -> nim.cfg so Nim auto-discovers the Vita toolchain/flags.
cp nim_vita.cfg nim.cfg

# vitaGL needs the dedicated-CDRAM display-surface patch (birbparty/vitaGL#1) or the
# screen is black on real hardware. Until that's in the sysroot, prefer a locally-built
# patched vitaGL if present. $HOME does NOT expand inside nim.cfg, so inject the -L here
# (shell-expanded) at the TOP of nim.cfg, before the sysroot -L, so -lvitaGL resolves to
# the patched copy. Override the location with BOXY_VITAGL_DIR; skipped if absent.
VITAGL_DIR="${BOXY_VITAGL_DIR:-$HOME/git/vitaGL}"
if [[ -f "$VITAGL_DIR/libvitaGL.a" ]]; then
  printf '%s\n' "--passL:\"-L$VITAGL_DIR\"" | cat - nim.cfg > nim.cfg.tmp && mv nim.cfg.tmp nim.cfg
  echo "[build_vita] using locally-patched vitaGL: $VITAGL_DIR/libvitaGL.a"
fi

# Nim injects -lrt for os:linux; Vita has no librt. Empty stub on the link path (-L.).
"$AR" rcs librt.a

echo "[build_vita] Compiling $SRC ..."
nim c -d:vita -d:release --out:"$BASE" "$SRC"

echo "[build_vita] ELF -> velf (the -Wl,-q relocation gate) ..."
vita-elf-create "$BASE" "$BASE.velf"
vita-make-fself "$BASE.velf" eboot.bin
vita-mksfoex -s "TITLE_ID=$TITLE_ID" "$APP_TITLE" param.sfo

echo "[build_vita] Packaging .vpk ..."
mkdir -p vpk_stage/sce_sys vpk_stage/data
cp eboot.bin vpk_stage/
cp param.sfo vpk_stage/sce_sys/
# Bundle any example assets (reachable at app0:data/ on the Vita). Optional.
[ -d data ] && cp -r data/* vpk_stage/data/ 2>/dev/null || true
( cd vpk_stage && zip -qr "../$BASE.vpk" . )

echo "[build_vita] Done: $BASE.vpk"
