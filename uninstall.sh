#!/bin/bash
set -e

BUNDLE_ID="com.machealth.monitor"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

pkill -f "MacHealth.app/Contents/MacOS/MacHealth" 2>/dev/null || true
launchctl unload "$AGENT" 2>/dev/null || true
rm -f "$AGENT"
rm -rf "$HOME/Applications/MacHealth.app"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "Uninstalled Mac Health."
