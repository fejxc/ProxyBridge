#!/bin/bash
# 阶段 A 本地验证 ③：不依赖 Xcode，直接用 swiftc 链接出可运行的 .app。
# 产物：build/ProxyBridge.app（未签名，仅本机调试用）。
# 注意：正式构建仍应使用 Xcode / xcodebuild（见 BUILD.md）。

set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_DEFAULT="arm64-apple-macos14.0"
TARGET="${1:-$TARGET_DEFAULT}"
APP="build/ProxyBridge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "== 链接可执行文件（target: ${TARGET} ）=="
swiftc -o "$APP/Contents/MacOS/ProxyBridge" \
  -swift-version 5 -target "$TARGET" \
  ProxyBridge/App/*.swift ProxyBridge/Models/*.swift ProxyBridge/Persistence/*.swift \
  ProxyBridge/Services/*.swift ProxyBridge/Presentation/*.swift

echo "== 写入 Info.plist =="
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>ProxyBridge</string>
	<key>CFBundleIdentifier</key><string>dev.sunyun.ProxyBridge</string>
	<key>CFBundleName</key><string>ProxyBridge</string>
	<key>CFBundleDisplayName</key><string>ProxyBridge</string>
	<key>CFBundleIconFile</key><string>ProxyBridge</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "== 生成应用图标（缺失时）=="
if [ ! -f "build/icon/ProxyBridge.icns" ]; then
	mkdir -p build/icon
	swift tools/make_icon.swift build/icon/icon_1024.png
	ICONSET="build/icon/AppIcon.iconset"
	rm -rf "$ICONSET" && mkdir -p "$ICONSET"
	for s in 16 32 128 256 512; do
		sips -z $s $s build/icon/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
		d=$((s*2))
		sips -z $d $d build/icon/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
	done
	iconutil -c icns "$ICONSET" -o build/icon/ProxyBridge.icns
fi
cp build/icon/ProxyBridge.icns "$APP/Contents/Resources/ProxyBridge.icns"

cp ProxyBridge/Resources/zh-Hans.lproj/Localizable.strings "$APP/Contents/Resources/Localizable.strings" 2>/dev/null || true
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
cp ProxyBridge/Resources/zh-Hans.lproj/Localizable.strings "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"

echo "== Ad-hoc 签名（本地运行，无开发者账户要求）=="
codesign --force --sign - "$APP" 2>/dev/null || echo "（codesign 跳过/失败：本地 unsigned 通常仍可运行）"

echo "构建完成：$APP"
ls -la "$APP/Contents/MacOS"
