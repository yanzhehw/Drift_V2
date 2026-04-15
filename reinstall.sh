#!/bin/bash
#
# Clean reinstall of the Drift_V2 screensaver.
#
#   ./reinstall.sh            # stop, remove bundle, rebuild, install (keeps saved preset)
#   ./reinstall.sh --reset    # also clears saved preset preference
#   ./reinstall.sh --uninstall-only   # tear down without reinstalling
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

RESET_PREFS=false
UNINSTALL_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --reset)          RESET_PREFS=true ;;
        --uninstall-only) UNINSTALL_ONLY=true ;;
        -h|--help)
            sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

BOLD="\033[1m"; GREEN="\033[32m"; YELLOW="\033[33m"; RESET="\033[0m"
step() { printf "${BOLD}${GREEN}==>${RESET}${BOLD} %s${RESET}\n" "$1"; }
warn() { printf "${BOLD}${YELLOW}==> %s${RESET}\n" "$1"; }

BUNDLE_ID="com.local.DriftV2ScreenSaver"
INSTALL_PATH="$HOME/Library/Screen Savers/Drift_V2.saver"

# 1. Stop anything currently running the screensaver
step "Stopping screensaver/wallpaper agents..."
killall legacyScreenSaver 2>/dev/null || true
killall WallpaperAgent 2>/dev/null || true

# 2. Remove installed bundle
if [ -e "$INSTALL_PATH" ]; then
    step "Removing installed bundle: $INSTALL_PATH"
    rm -rf "$INSTALL_PATH"
else
    warn "No existing bundle found at $INSTALL_PATH"
fi

# 3. Optionally clear saved preferences
if [ "$RESET_PREFS" = true ]; then
    step "Clearing saved preferences..."
    rm -f "$HOME/Library/Preferences/ByHost/${BUNDLE_ID}".*.plist 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/${BUNDLE_ID}.plist" 2>/dev/null || true
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
fi

# 4. Optionally reinstall
if [ "$UNINSTALL_ONLY" = true ]; then
    step "Uninstall complete. Remember to remove Drift_V2 from System Settings > Wallpaper if it was set as a live wallpaper."
    exit 0
fi

if [ ! -x "$SCRIPT_DIR/install.sh" ]; then
    echo "install.sh not found or not executable at $SCRIPT_DIR/install.sh" >&2
    exit 1
fi

step "Running install.sh..."
"$SCRIPT_DIR/install.sh"

step "Done. If Drift_V2 was set as your live wallpaper, it will auto-respawn on all displays."
echo "   To disable wallpaper mode: System Settings > Wallpaper > pick a static image."
