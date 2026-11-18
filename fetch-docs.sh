#!/bin/sh
# Fetches reference material into doc/generated/ (gitignored):
#   zig/langref.html   Zig 0.17.1 language reference
#   ref/rehlds/        ReHLDS + ReHLTV source at the commit the format notes were checked against
#   ref/dem/           the `dem` Rust crate 0.3.0 (independent GoldSrc demo parser)
# The Zig std source needs no fetching: $(zig env | grep lib_dir)/std/
set -eu
cd "$(dirname "$0")"
OUT=doc/generated
REHLDS_COMMIT=8305936010ccd038af7665a17527df5c53965f58

mkdir -p "$OUT/zig" "$OUT/ref"
curl -fsSL https://ziglang.org/documentation/0.17.1/ -o "$OUT/zig/langref.html"

if [ ! -d "$OUT/ref/rehlds/.git" ]; then
	git clone -q https://github.com/rehlds/ReHLDS.git "$OUT/ref/rehlds"
fi
git -C "$OUT/ref/rehlds" fetch -q origin "$REHLDS_COMMIT" 2>/dev/null || true
git -C "$OUT/ref/rehlds" checkout -q "$REHLDS_COMMIT"

if [ ! -d "$OUT/ref/dem" ]; then
	mkdir -p "$OUT/ref/dem"
	curl -fsSL https://static.crates.io/crates/dem/dem-0.3.0.crate | tar -xz -C "$OUT/ref/dem" --strip-components=1
fi

echo "done: $OUT"
echo "  HLTV: $OUT/ref/rehlds/rehlds/HLTV/  (common/DemoFile.cpp, Core/src/Server.cpp, Core/src/Delta.cpp, common/BitBuffer.cpp)"
echo "  dem:  $OUT/ref/dem/src/"
