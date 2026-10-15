#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
mkdir -p dist
# Omit Finder metadata and extended attributes that can invalidate local signatures.
ditto -c -k --norsrc --noextattr --noqtn --keepParent build/NekoNotch.app dist/NekoNotch-arm64.zip
(cd dist && shasum -a 256 NekoNotch-arm64.zip > SHA256SUMS.txt)
printf 'Descarga lista: %s/dist/NekoNotch-arm64.zip\n' "$PWD"
