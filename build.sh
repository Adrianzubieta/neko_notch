#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
bundle_dir=$(mktemp -d "${TMPDIR:-/tmp}/nekonotch-build.XXXXXX")
trap 'rm -rf "$bundle_dir"' EXIT
app="$bundle_dir/NekoNotch.app"
framework="$app/Contents/Frameworks/MediaRemoteAdapter.framework"
adapter="ThirdParty/MediaRemoteAdapter"
mkdir -p build/ModuleCache build/ClangCache "$app/Contents/MacOS" "$app/Contents/Resources" "$framework/Resources"
swift -module-cache-path build/ModuleCache Scripts/GenerateIcon.swift build/AppIcon.iconset
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date -u +%Y%m%d%H%M%S)" "$app/Contents/Info.plist"
cp Resources/MediaRemote-Info.plist "$framework/Resources/Info.plist"
cp "$adapter/bin/mediaremote-adapter.pl" "$app/Contents/Resources/"
cp "$adapter/LICENSE" "$app/Contents/Resources/MediaRemote-LICENSE.txt"
swiftc -module-cache-path build/ModuleCache Bridge/ClaudeStatusline.swift -o "$app/Contents/Resources/ClaudeStatusline" -target arm64-apple-macosx14.2
clang -dynamiclib -fobjc-arc -fmodules -fmodules-cache-path=build/ClangCache -I"$adapter/src" -I"$adapter/include" "$adapter"/src/adapter/*.m "$adapter"/src/private/*.m "$adapter"/src/utility/*.m -framework Foundation -framework AppKit -framework UniformTypeIdentifiers -o "$framework/MediaRemoteAdapter" -mmacosx-version-min=14.2
clang -c -fobjc-arc -fmodules -fmodules-cache-path=build/ClangCache Sources/AppMixer.m -o build/AppMixer.o -mmacosx-version-min=14.2
swiftc -module-cache-path build/ModuleCache -parse-as-library Sources/*.swift build/AppMixer.o -o "$app/Contents/MacOS/MiMac" -framework SwiftUI -framework AppKit -framework IOKit -framework SystemConfiguration -framework CoreAudio -target arm64-apple-macosx14.2
xattr -cr "$app"
codesign --force --sign - "$framework"
for attempt in 1 2 3; do
    xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
    xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
    if codesign --force --sign - "$app" && codesign --verify --deep --strict "$app"; then
        ditto --norsrc --noextattr --noqtn "$app" build/NekoNotch.app
        printf 'App creada: %s/build/NekoNotch.app\n' "$PWD"
        exit 0
    fi
done
printf 'No se pudo firmar la app. Revisá los metadatos de Finder/iCloud.\n' >&2
exit 1
