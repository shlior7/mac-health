#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/MacHealth.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc main.swift -parse-as-library -o "$APP/Contents/MacOS/MacHealth" \
    -framework SwiftUI -framework AppKit

cp Info.plist "$APP/Contents/Info.plist"

echo "Built: $APP"
