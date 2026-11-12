#!/bin/bash
# Renders every README screenshot from the real views, in English and Thai, to
# docs/screens/<lang>/. Fake sensors only: nothing real is touched.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
BIN="$(swift build --show-bin-path)/AFKPug"
SCENES=(setup idle timer working limit grace music battery away white)

for lang in en th; do
  OUT="docs/screens/$lang"
  mkdir -p "$OUT"
  for scene in "${SCENES[@]}"; do
    SIM_DIR="$(mktemp -d)"
    AFKPUG_SIM=1 AFKPUG_SIM_DIR="$SIM_DIR" "$BIN" --render-screen "$scene" "$OUT/$scene.png" --lang "$lang"
    rm -rf "$SIM_DIR"
  done
  for step in 1 2 3 4 5 6 7 8 9 10 11; do
    SIM_DIR="$(mktemp -d)"
    mkdir -p "$SIM_DIR/home/.claude" "$SIM_DIR/home/.codex" "$SIM_DIR/home/.cursor"
    AFKPUG_SIM=1 AFKPUG_SIM_DIR="$SIM_DIR" "$BIN" --render-onboarding "$OUT/welcome-$step.png" --step "$step" --lang "$lang"
    rm -rf "$SIM_DIR"
  done
done
