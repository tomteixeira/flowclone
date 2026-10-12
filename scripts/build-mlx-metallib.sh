#!/usr/bin/env bash
# Compile MLX's Metal kernels into mlx.metallib and print its path.
# SwiftPM (`swift build`) can't compile .metal files, and MLX fails at its first
# GPU op without the library ("Failed to load the default metallib"). The result
# is cached per mlx-swift version. Also copied next to the debug and release
# binaries so `swift run` / `.build/*/FlowClone --transcribe` work too.
# Needs the Metal Toolchain once: xcodebuild -downloadComponent MetalToolchain
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT="$ROOT/.build/checkouts/mlx-swift"
[[ -d "$CHECKOUT" ]] || swift package resolve --package-path "$ROOT" >&2
SRC="$CHECKOUT/Source/Cmlx/mlx-generated/metal"
VERSION="$(git -C "$CHECKOUT" describe --tags 2>/dev/null || git -C "$CHECKOUT" rev-parse --short HEAD)"
OUT="$ROOT/.build/mlx-metallib/$VERSION"
LIB="$OUT/mlx.metallib"

if [[ ! -f "$LIB" ]]; then
  if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "error: Metal Toolchain missing; run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi
  rm -rf "$OUT" && mkdir -p "$OUT/air"
  # Flags from mlx-swift's xcode/xcconfig/Cmlx.xcconfig (MTL_COMPILER_FLAGS).
  while IFS= read -r f; do
    xcrun -sdk macosx metal -Wall -Wextra -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions \
      -I "$SRC" -c "$f" -o "$OUT/air/$(basename "${f%.metal}").air" >&2
  done < <(find "$SRC" -name '*.metal')
  xcrun -sdk macosx metallib "$OUT"/air/*.air -o "$LIB" >&2
fi

for config in debug release; do
  BIN_DIR="$ROOT/.build/arm64-apple-macosx/$config"
  [[ -d "$BIN_DIR" ]] && cp "$LIB" "$BIN_DIR/mlx.metallib"
done
echo "$LIB"
