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
        <string>$APP/Contents/MacOS/MacHealth</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

launchctl unload "$AGENT" 2>/dev/null || true
launchctl load "$AGENT"

# Launch directly so an unsigned local build does not depend on LaunchServices.
# If an instance is already running, the launch request may return non-zero;
# installation itself is still complete in that case.
"$APP/Contents/MacOS/MacHealth" >/dev/null 2>&1 &
echo "Installed. Mac Health is running in the menu bar and will start automatically at login."
echo "Uninstall any time with ./uninstall.sh"
