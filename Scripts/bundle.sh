#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=EdgeNotes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/release/EdgeNotesApp "$APP/Contents/MacOS/EdgeNotesApp"
codesign --force --sign - "$APP"
echo "Built $APP"
