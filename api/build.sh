#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/.build"

echo "→ Installing dependencies..."
rm -rf "$BUILD"
pip3 install --quiet --platform manylinux2014_x86_64 \
  --target "$BUILD" \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  -r "$DIR/requirements.txt"

echo "→ Copying source files..."
cp "$DIR/main.py" "$DIR/athena.py" "$BUILD/"

echo "→ Zipping..."
rm -f "$DIR/lambda.zip"
cd "$BUILD"
zip -q -r "$DIR/lambda.zip" .

SIZE=$(du -sh "$DIR/lambda.zip" | cut -f1)
echo "✅  Built $DIR/lambda.zip ($SIZE)"
