#!/bin/bash
# 阶段 A 本地验证 ①：swiftc 全模块类型检查（App + XCTest 测试代码）
# 适用：只装了 Command Line Tools（无完整 Xcode）的开发机。
# 说明：XCTest 断言运行需完整 Xcode；这里用 tools/xctest-shim 做编译级检查，
#       真实测试执行请在装有 Xcode 的 Mac 上跑 scripts/xcode_test.sh。

set -uo pipefail
cd "$(dirname "$0")/.."

TARGET="arm64-apple-macos14.0"
BUILD_DIR="build/typecheck"
mkdir -p "$BUILD_DIR"

echo "== [1/4] 生成 XCTest shim swiftmodule（仅本机类型检查用）=="
swiftc -emit-module tools/xctest-shim/XCTest.swift \
  -module-name XCTest \
  -emit-module-path "$BUILD_DIR/XCTest.swiftmodule" \
  -swift-version 5 -target "$TARGET" || exit 1

echo "== [2/4] App 模块编译检查（-emit-module，等价完整编译前端）=="
swiftc -emit-module \
  ProxyBridge/App/*.swift ProxyBridge/Models/*.swift ProxyBridge/Persistence/*.swift \
  ProxyBridge/Services/*.swift ProxyBridge/Presentation/*.swift \
  -module-name ProxyBridge -enable-testing \
  -emit-module-path "$BUILD_DIR/ProxyBridge.swiftmodule" \
  -swift-version 5 -target "$TARGET" || exit 1
echo "App 模块检查通过（0 error）"

echo "== [3/4] 测试代码类型检查（@testable import ProxyBridge + XCTest shim）=="
swiftc -typecheck ProxyBridgeTests/*.swift \
  -I "$BUILD_DIR" \
  -swift-version 5 -target "$TARGET" || exit 1
echo "测试代码检查通过（0 error）"

echo "== [4/4] Swift 6 语言模式兼容性预检（App 模块，允许并发告警）=="
if swiftc -emit-module \
  ProxyBridge/App/*.swift ProxyBridge/Models/*.swift ProxyBridge/Persistence/*.swift \
  ProxyBridge/Services/*.swift ProxyBridge/Presentation/*.swift \
  -module-name ProxyBridgeS6 -enable-testing \
  -emit-module-path "$BUILD_DIR/ProxyBridgeS6.swiftmodule" \
  -swift-version 6 -target "$TARGET" 2>"$BUILD_DIR/swift6.log"; then
  echo "Swift 6 语言模式：通过"
else
  echo "Swift 6 语言模式：未通过（不影响阶段 A 交付，工程使用 Swift 5 语言模式）—— 详见 $BUILD_DIR/swift6.log"
fi

echo "typecheck: OK"
