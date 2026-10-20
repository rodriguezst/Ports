#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Ports.app must be built on macOS with Xcode or the Xcode Command Line Tools." >&2
    exit 1
fi

ports_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ports_root"
ports_build_args=(--configuration release --product Ports)
case "${1:-}" in
    "") ;;
    --universal) ports_build_args+=(--arch arm64 --arch x86_64) ;;
    *) echo "Usage: $0 [--universal]" >&2; exit 1 ;;
esac

swift build "${ports_build_args[@]}"
ports_bin_dir="$(swift build "${ports_build_args[@]}" --show-bin-path)"
ports_app="$ports_root/build/Ports.app"
mkdir -p "$ports_app/Contents/MacOS" "$ports_app/Contents/Resources"
cp "$ports_bin_dir/Ports" "$ports_app/Contents/MacOS/Ports"
cp Resources/Info.plist "$ports_app/Contents/Info.plist"
chmod 755 "$ports_app/Contents/MacOS/Ports"
plutil -lint "$ports_app/Contents/Info.plist"

ports_iconset="$ports_root/build/Ports.iconset"
mkdir -p "$ports_iconset"
swift scripts/generate-icon.swift "$ports_iconset"
iconutil --convert icns --output "$ports_app/Contents/Resources/Ports.icns" "$ports_iconset"

# Ad-hoc signing makes a local/CI app bundle. Set CODESIGN_IDENTITY to use a
# Developer ID certificate installed in the build machine's Keychain.
codesign --force --sign "${CODESIGN_IDENTITY:--}" --timestamp=none "$ports_app"
codesign --verify --strict --verbose=2 "$ports_app"
echo "Built $ports_app"
