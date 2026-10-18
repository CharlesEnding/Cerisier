#!/usr/bin/env bash
# Copies code files into a flat temp/ dir, keeping original file names.
set -euo pipefail

cd "$(dirname "$0")"
out=temp

rm -rf "$out"
mkdir -p "$out"

find . \
  \( -path ./.git -o -path ./bin -o -path ./temp -o -name nimcache -o -name node_modules \) -prune -o \
  -type f \( -name '*.nim' -o -name '*.nimble' -o -name '*.cfg' -o -name '*.js' -o -name '*.css' \
    -o -name '*.html' -o -name '*.py' -o -name '*.json' -o -name '*.sh' \) -print0 |
while IFS= read -r -d '' f; do
  name="$(basename "$f")"
  if [[ -e "$out/$name" ]]; then
    echo "Skipped (name collision): $f" >&2
    continue
  fi
  cp "$f" "$out/$name"
done

echo "Copied $(find "$out" -type f | wc -l) files to $out/"
