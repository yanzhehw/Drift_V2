#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$ROOT_DIR/target/lifecycle-tests"
VIEW_SOURCE="${DRIFT_VIEW_SOURCE:-$ROOT_DIR/drift/objc/DriftV2ScreenSaverView.m}"
mkdir -p "$TEST_DIR"

clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
    -I "$ROOT_DIR/drift/objc" -I "$ROOT_DIR/drift/include" \
    "$ROOT_DIR/drift/tests/lifecycle.m" "$VIEW_SOURCE" \
    -framework ScreenSaver -framework AppKit -framework QuartzCore -framework CoreGraphics \
    -o "$TEST_DIR/DriftLifecycleTests"

# Run the same view in both host identities: legacyScreenSaver surfaces are
# remotely presented and cannot use their source window's occlusion state.
STATUS=0
for HOST in ordinary remote; do
    APP="$TEST_DIR/$HOST.app"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$TEST_DIR/DriftLifecycleTests" "$APP/Contents/MacOS/DriftLifecycleTests"
    cp "$ROOT_DIR/drift/thumbnail.png" "$APP/Contents/Resources/thumbnail.png"
    BUNDLE_ID="com.local.DriftV2LifecycleTests"
    if [ "$HOST" = remote ]; then
        BUNDLE_ID="com.apple.ScreenSaver.Engine.legacyScreenSaver.DriftTests"
    fi
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DriftLifecycleTests</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    "$APP/Contents/MacOS/DriftLifecycleTests" || STATUS=1
done
exit "$STATUS"
