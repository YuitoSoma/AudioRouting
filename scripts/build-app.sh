#!/bin/zsh
# Builds AudioRouting.app (Release, arm64) and installs it.
# Usage: scripts/build-app.sh [install-dir]   (default: /Applications)
set -euo pipefail

root=${0:A:h:h}
install_dir=${1:-/Applications}
app_name=AudioRouting.app

cd "$root"
tools/xcodegen/bin/xcodegen generate --quiet
xcodebuild build \
    -project AudioRouting.xcodeproj \
    -scheme AudioRouting \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build \
    -quiet

built="build/Build/Products/Release/$app_name"
codesign --verify --strict "$built"

# Quit a running copy so its taps and aggregate devices are torn down before replacing it.
if pgrep -xq AudioRouting; then
    osascript -e 'with timeout of 10 seconds' -e 'tell application id "local.audiorouting.AudioRouting" to quit' -e 'end timeout' || true
    for _ in {1..50}; do pgrep -xq AudioRouting || break; sleep 0.1; done
fi

rm -rf "$install_dir/$app_name"
ditto "$built" "$install_dir/$app_name"
echo "Installed $install_dir/$app_name"
