#!/bin/bash
set -e
cd "$(dirname "$0")"

BUNDLE_ID="com.machealth.monitor"
APP="$HOME/Applications/MacHealth.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

echo "Building Mac Health..."
./build.sh

echo "Registering login item..."
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT"

open "$APP"
echo "Installed. Mac Health is running in the menu bar and will start automatically at login."
echo "Uninstall any time with ./uninstall.sh"
