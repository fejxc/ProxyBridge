#!/bin/bash
# 构建 + 安装到 /Applications（本机日常使用的正式安装方式）。
# 用法：bash scripts/install_app.sh [目标三元组]   # 默认 arm64-apple-macos14.0
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SOURCE="build/ProxyBridge.app"
APP_DEST="/Applications/ProxyBridge.app"
RUN_ID="/Applications/ProxyBridge.app/Contents/MacOS/ProxyBridge"

echo "== 构建 =="
bash scripts/build_app.sh "${1:-}"

echo "== 停止正在运行的实例（仅限本 App 的安装路径/构建路径）=="
pkill -f "$RUN_ID" 2>/dev/null || true
pkill -f "$(pwd)/build/ProxyBridge.app/Contents/MacOS/ProxyBridge" 2>/dev/null || true
sleep 1

echo "== 安装到 /Applications =="
rm -rf "$APP_DEST"
cp -R "$APP_SOURCE" "$APP_DEST"

# 清除隔离属性：本机构建的可信产物，避免「已损坏/无法验证」提示
xattr -dr com.apple.quarantine "$APP_DEST" 2>/dev/null || true

echo "== 启动 =="
open "$APP_DEST"
sleep 2
if pgrep -f "$RUN_ID" > /dev/null; then
    echo "✅ 已安装并启动：/Applications/ProxyBridge.app"
    echo "   之后可随时通过 Spotlight（⌘空格 搜 ProxyBridge）、启动台或 Finder 双击打开。"
else
    echo "⚠️ 安装完成但启动确认超时，请手动打开 /Applications/ProxyBridge.app"
    exit 1
fi
