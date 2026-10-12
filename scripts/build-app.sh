#!/usr/bin/env bash
# Build FlowClone.app (an .app bundle is required for microphone / Accessibility permissions).
#   scripts/build-app.sh             # build only
#   scripts/build-app.sh --install   # replace /Applications/FlowClone.app and relaunch
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/FlowClone.app"

swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/FlowClone"

LIB="$("$ROOT/scripts/build-mlx-metallib.sh")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FlowClone"
# MLX kernels; MLXTextModel points MLX at this copy (GPU.metallib).
cp "$LIB" "$APP/Contents/Resources/mlx.metallib"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature with a designated requirement pinned to the bundle identifier
# instead of the default (the binary's cdhash, which changes every build). macOS
# privacy grants (Accessibility, Microphone) are checked against this requirement,
# so they survive rebuilds — without a certificate, which shells detached from the
# GUI session (IDEs, agents, tmux) can't use. Trade-off: any ad-hoc app claiming
# the identifier "dev.local.flowclone" would match, acceptable for a local build.
codesign --force --sign - --identifier dev.local.flowclone \
  -r='designated => identifier "dev.local.flowclone"' "$APP"
echo "Built $APP"

# --install: replace /Applications/FlowClone.app and relaunch (only one copy may run).
if [[ "${1:-}" == "--install" ]]; then
  pkill -x FlowClone || true
  rm -rf /Applications/FlowClone.app
  mv "$APP" /Applications/
  open /Applications/FlowClone.app
  echo "Installed and launched /Applications/FlowClone.app"
fi
