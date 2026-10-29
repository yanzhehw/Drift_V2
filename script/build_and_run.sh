#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
APP_NAME="DriftPreview"
BUILD_DIR="$ROOT_DIR/target/preview-host"
APP="$BUILD_DIR/$APP_NAME.app"

# Support the isolated toolchain used for local verification, without changing
# the user's shell profile or installing Rust outside this repository.
if ! command -v cargo >/dev/null 2>&1 && [ -x "$ROOT_DIR/target/toolchain/cargo/bin/cargo" ]; then
    export CARGO_HOME="$ROOT_DIR/target/toolchain/cargo"
    export RUSTUP_HOME="$ROOT_DIR/target/toolchain/rustup"
    export PATH="$CARGO_HOME/bin:$PATH"
fi

case "$MODE" in run|--verify|--debug|--logs|--telemetry) ;; *)
    echo "Usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2;; esac

# Only stop this development preview; never interrupt the system saver host.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
"$ROOT_DIR/drift/build.sh"
mkdir -p "$APP/Contents/MacOS"
clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
    "$ROOT_DIR/drift/tests/preview.m" -framework AppKit -framework ScreenSaver \
    -framework QuartzCore -framework Metal -o "$APP/Contents/MacOS/$APP_NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>com.local.DriftV2Preview</string>
<key>CFBundleName</key><string>Drift Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"

case "$MODE" in
    run) open -n "$APP" ;;
    --debug) lldb -- "$APP/Contents/MacOS/$APP_NAME" ;;
    --logs|--telemetry)
        open -n "$APP"
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --verify)
        rm -f "$BUILD_DIR/verification.json"
        open -n -W --stdout "$BUILD_DIR/verification.stdout.log" \
            --stderr "$BUILD_DIR/verification.stderr.log" "$APP" --args --verify
        /usr/bin/python3 - "$BUILD_DIR/verification.json" <<'PY'
import json, sys
with open(sys.argv[1]) as result:
    report = json.load(result)
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["passed"] else 1)
PY
        ;;
esac
