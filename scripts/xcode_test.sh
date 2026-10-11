#!/bin/bash
# 装有完整 Xcode 的机器上执行：xcodebuild 构建 + XCTest 全量测试。
# 用法：bash scripts/xcode_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== xcodebuild -list =="
xcodebuild -list -project ProxyBridge.xcodeproj

echo "== Build（Debug）=="
xcodebuild -project ProxyBridge.xcodeproj -scheme ProxyBridge -configuration Debug build

echo "== Test（XCTest）=="
xcodebuild -project ProxyBridge.xcodeproj -scheme ProxyBridge test
