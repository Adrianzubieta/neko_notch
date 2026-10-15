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
# Compile every native component for both supported Mac architectures.
for arch in arm64 x86_64; do
    arch_dir="$bundle_dir/$arch"
    mkdir -p "$arch_dir"
    swiftc -module-cache-path build/ModuleCache Bridge/ClaudeStatusline.swift -o "$arch_dir/ClaudeStatusline" -target "$arch-apple-macosx14.2"
    clang -arch "$arch" -dynamiclib -fobjc-arc -fmodules -fmodules-cache-path=build/ClangCache -I"$adapter/src" -I"$adapter/include" "$adapter"/src/adapter/*.m "$adapter"/src/private/*.m "$adapter"/src/utility/*.m -framework Foundation -framework AppKit -framework UniformTypeIdentifiers -o "$arch_dir/MediaRemoteAdapter" -mmacosx-version-min=14.2
    clang -arch "$arch" -c -fobjc-arc -fmodules -fmodules-cache-path=build/ClangCache Sources/AppMixer.m -o "$arch_dir/AppMixer.o" -mmacosx-version-min=14.2
    swiftc -module-cache-path build/ModuleCache -parse-as-library Sources/*.swift "$arch_dir/AppMixer.o" -o "$arch_dir/MiMac" -framework SwiftUI -framework AppKit -framework IOKit -framework SystemConfiguration -framework CoreAudio -target "$arch-apple-macosx14.2"
done
lipo -create "$bundle_dir/arm64/MiMac" "$bundle_dir/x86_64/MiMac" -output "$app/Contents/MacOS/MiMac"
lipo -create "$bundle_dir/arm64/ClaudeStatusline" "$bundle_dir/x86_64/ClaudeStatusline" -output "$app/Contents/Resources/ClaudeStatusline"
lipo -create "$bundle_dir/arm64/MediaRemoteAdapter" "$bundle_dir/x86_64/MediaRemoteAdapter" -output "$framework/MediaRemoteAdapter"
for binary in "$app/Contents/MacOS/MiMac" "$app/Contents/Resources/ClaudeStatusline" "$framework/MediaRemoteAdapter"; do
    lipo -verify_arch arm64 "$binary"
    lipo -verify_arch x86_64 "$binary"
done
codesign --force --sign - "$app/Contents/Resources/ClaudeStatusline"
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
