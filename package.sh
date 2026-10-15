#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
mkdir -p dist
# Omit Finder metadata and extended attributes that can invalidate local signatures.
ditto -c -k --norsrc --noextattr --noqtn --keepParent build/NekoNotch.app dist/NekoNotch-universal.zip
(cd dist && shasum -a 256 NekoNotch-universal.zip > SHA256SUMS.txt)
printf 'Descarga lista: %s/dist/NekoNotch-universal.zip\n' "$PWD"
