#!/usr/bin/env bash
set -e

APP_NAME="SpotifyLyrics"
BUNDLE_DIR="/Applications/${APP_NAME}.app"
BUILD_DIR="$(pwd)/build"

echo "🔨 正在编译 ${APP_NAME}..."
mkdir -p "${BUILD_DIR}"
swiftc -O main.swift -o "${BUILD_DIR}/${APP_NAME}"

echo "📦 正在打包为 macOS App..."
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${BUNDLE_DIR}/Contents/MacOS/${APP_NAME}"

cat << 'EOF' > "${BUNDLE_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SpotifyLyrics</string>
    <key>CFBundleIdentifier</key>
    <string>com.mobai.SpotifyLyrics</string>
    <key>CFBundleName</key>
    <string>SpotifyLyrics</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>5.5</string>
    <key>CFBundleVersion</key>
    <string>5.5</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>SpotifyLyrics 需要控制 Spotify 以同步歌词与控制播放进度。</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

echo "🔏 正在进行 Ad-hoc 签名..."
codesign --force --deep --sign - "${BUNDLE_DIR}"

echo "✅ 构建完成！已安装至 ${BUNDLE_DIR}"
echo "🚀 运行命令: open /Applications/SpotifyLyrics.app"
