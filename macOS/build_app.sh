#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$OUTPUT_DIR/MingCam.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_TMP="$SCRIPT_DIR/.build_tmp"

echo "🔨 正在編譯 MingCam 原生 macOS 應用程式..."

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_TMP"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

# Workaround for CommandLineTools duplicate SwiftBridging modulemap
echo "// empty" > "$BUILD_TMP/empty.modulemap"
cat << EOF > "$BUILD_TMP/vfs.yaml"
{
  "version": 0,
  "case-sensitive": "false",
  "roots": [
    {
      "name": "/Library/Developer/CommandLineTools/usr/include/swift",
      "type": "directory",
      "contents": [
        {
          "name": "module.modulemap",
          "type": "file",
          "external-contents": "$BUILD_TMP/empty.modulemap"
        }
      ]
    }
  ]
}
EOF

SDK_PATH=$(xcrun --show-sdk-path)

swiftc \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx14.0 \
    -swift-version 5 \
    -vfsoverlay "$BUILD_TMP/vfs.yaml" \
    -Xcc -ivfsoverlay -Xcc "$BUILD_TMP/vfs.yaml" \
    -O \
    "$SCRIPT_DIR/Sources/Models.swift" \
    "$SCRIPT_DIR/Sources/GlobalHotkeyManager.swift" \
    "$SCRIPT_DIR/Sources/RegionOverlayWindow.swift" \
    "$SCRIPT_DIR/Sources/SnipastePinWindow.swift" \
    "$SCRIPT_DIR/Sources/ScreenshotEngine.swift" \
    "$SCRIPT_DIR/Sources/ScreenRecorderEngine.swift" \
    "$SCRIPT_DIR/Sources/ContentView.swift" \
    "$SCRIPT_DIR/Sources/MingCamApp.swift" \
    -framework SwiftUI \
    -framework AppKit \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreGraphics \
    -framework Carbon \
    -o "$MACOS_DIR/MingCam"

codesign --force --deep --sign - "$APP_BUNDLE"

echo "✅ 編譯完成：$APP_BUNDLE"
