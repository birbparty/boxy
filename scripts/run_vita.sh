#!/usr/bin/env bash
# Install + run a boxy Vita .vpk in the Vita3K emulator. Builds first if missing.
#
# Usage:  scripts/run_vita.sh [src.nim]
#   src.nim   default examples/vita_shader_spike.nim
#
# NOTE: Vita3K requires PS Vita firmware installed first (File -> Install Firmware).
# Vita3K loads at the link base and HIDES -Wl,-q relocation bugs and the
# libshacccg.suprx requirement — confirm anything important on real hardware.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-examples/vita_shader_spike.nim}"
BASE="$(basename "$SRC" .nim)"
VPK="$BASE.vpk"
VITA3K="${VITA3K:-/Applications/Vita3K.app/Contents/MacOS/Vita3K}"

if [ ! -f "$VPK" ]; then
  echo "[run_vita] $VPK not found — building ..."
  bash scripts/build_vita.sh "$SRC"
fi
if [ ! -f "$VPK" ]; then
  echo "[run_vita] Build produced no $VPK (VitaSDK likely absent). Cannot run." >&2
  exit 1
fi
if [ ! -x "$VITA3K" ]; then
  echo "[run_vita] Vita3K not found at $VITA3K (override with VITA3K=...)." >&2
  exit 1
fi

exec "$VITA3K" "$PWD/$VPK"
