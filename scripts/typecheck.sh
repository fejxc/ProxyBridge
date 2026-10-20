#!/bin/bash
# 阶段 A 本地验证 ①：swiftc 全模块类型检查（App + XCTest 测试代码）
# 两套环境自适应：
# - 完整 Xcode 环境（CI/开发机）：测试代码直接对真实 XCTest 做类型检查（跳过 shim，
#   避免与 SDK 里的真实 XCTest.swiftmodule 撞车）
# - 仅 CLT 环境（本地开发机）：生成 XCTest shim 后做编译级检查
set -uo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-$(uname -m)-apple-macos14.0}"
BUILD_DIR="build/typecheck"
mkdir -p "$BUILD_DIR"

XCODE_DEVELOPER=$(xcode-select -p)
XCTEST_FRAMEWORKS="$XCODE_DEVELOPER/Platforms/MacOSX.platform/Developer/Library/Frameworks"
XCTEST_SWIFT_MODULES="$XCODE_DEVELOPER/Platforms/MacOSX.platform/Developer/usr/lib"
SWIFT_PLATFORM_LIBRARY="$(dirname "$(dirname "$(xcrun --find swiftc)")")/lib/swift/macosx"
if [ -d "$XCTEST_FRAMEWORKS/XCTest.framework" ]; then
  HAS_XCODE=1
  echo "== 环境检测：完整 Xcode（使用真实 XCTest）=="
else
  HAS_XCODE=0
  echo "== 环境检测：仅 Command Line Tools =="
fi

echo "== [0/4] 构建系统清单一致性（pbxproj ↔ swiftc 脚本）=="
bash "$(dirname "$0")/check_build_sync.sh" || exit 1

echo "== [1/4] App 模块编译检查（-emit-module，等价完整编译前端）=="
swiftc -emit-module \
  ProxyBridge/App/*.swift ProxyBridge/Models/*.swift ProxyBridge/Persistence/*.swift \
  ProxyBridge/Services/*.swift ProxyBridge/Presentation/*.swift \
  -module-name ProxyBridge -enable-testing \
  -emit-module-path "$BUILD_DIR/ProxyBridge.swiftmodule" \
  -swift-version 5 -target "$TARGET" || exit 1
echo "App 模块检查通过（0 error）"

if [ "$HAS_XCODE" = "0" ]; then
  echo "== [2/4] 生成 XCTest shim swiftmodule（仅本机类型检查用）=="
  swiftc -emit-module tools/xctest-shim/XCTest.swift \
    -module-name XCTest \
    -emit-module-path "$BUILD_DIR/XCTest.swiftmodule" \
    -swift-version 5 -target "$TARGET" || exit 1

  echo "== [3/4] 测试代码类型检查（XCTest shim）=="
  swiftc -typecheck ProxyBridgeTests/*.swift \
    -I "$BUILD_DIR" \
    -swift-version 5 -target "$TARGET" || exit 1
  echo "测试代码检查通过（0 error）"
else
  # Remove an old CLT shim if this checkout is reused with a full Xcode toolchain.
  rm -f "$BUILD_DIR/XCTest.swiftmodule" "$BUILD_DIR/XCTest.swiftdoc" "$BUILD_DIR/XCTest.swiftsourceinfo"
  echo "== [3/4] 测试代码类型检查（真实 XCTest + @testable 模块）=="
  swiftc -typecheck ProxyBridgeTests/*.swift \
    -I "$BUILD_DIR" -I "$XCTEST_SWIFT_MODULES" -I "$SWIFT_PLATFORM_LIBRARY" -F "$XCTEST_FRAMEWORKS" \
    -swift-version 5 -target "$TARGET" || exit 1
  echo "测试代码检查通过（0 error）"
fi

echo "== [4/4] Swift 6 语言模式兼容性预检（App 模块，允许并发告警）=="
if swiftc -emit-module \
  ProxyBridge/App/*.swift ProxyBridge/Models/*.swift ProxyBridge/Persistence/*.swift \
  ProxyBridge/Services/*.swift ProxyBridge/Presentation/*.swift \
  -module-name ProxyBridgeS6 -enable-testing \
  -emit-module-path "$BUILD_DIR/ProxyBridgeS6.swiftmodule" \
  -swift-version 6 -target "$TARGET" 2>"$BUILD_DIR/swift6.log"; then
  echo "Swift 6 语言模式：通过"
else
  echo "Swift 6 语言模式：未通过（不影响交付，工程使用 Swift 5 语言模式）—— 详见 $BUILD_DIR/swift6.log"
fi

echo "typecheck: OK"
