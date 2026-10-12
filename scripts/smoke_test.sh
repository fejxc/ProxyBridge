#!/bin/bash
# 阶段 A 本地验证 ②：编译并执行冒烟测试（真实运行核心逻辑断言，无 Xcode 依赖）。
# 覆盖：校验规则、JSON 持久化 round-trip/损坏恢复/去重、日志脱敏、
#       状态展示映射（nil≠true）、复制命令模板、端点解析优先级、
#       Mock 隧道状态机时序 / 双连击去重 / 用户断开后零事件。

set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-$(uname -m)-apple-macos14.0}"
OUT="build/smoke"
mkdir -p build

echo "== 编译冒烟测试可执行文件（App 生产源码 + tools/smoke）=="
swiftc -o "$OUT" -swift-version 5 -target "$TARGET" \
  ProxyBridge/Models/*.swift ProxyBridge/Persistence/*.swift ProxyBridge/Services/*.swift \
  ProxyBridge/Presentation/AppViewModel.swift \
  ProxyBridgeTests/MockServices.swift \
  tools/smoke/SmokeFakes.swift \
  tools/smoke/SmokeMain.swift

echo "== 执行 =="
"$OUT"
