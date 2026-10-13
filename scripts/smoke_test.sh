#!/bin/bash
# 本地回归：编译并执行冒烟测试（真实生产核心逻辑断言，无 Xcode 依赖）。
# 覆盖：校验规则、JSON 持久化 round-trip/损坏恢复/去重、日志脱敏、
#       状态展示映射（nil≠true）、复制命令模板、端点解析优先级、
#       静态/动态 SSH 命令、自动回退、Mixed 双协议探测、B+ HTTP CONNECT 状态和清理策略。

set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-$(uname -m)-apple-macos14.0}"
OUT="build/smoke"
mkdir -p build
SMOKE_SUPPORT=(tools/smoke/SmokeFakes.swift)
# Older release tags do not contain runtime regression sources.
for support in tools/smoke/RuntimeFakes.swift tools/smoke/RuntimeChecks.swift tools/smoke/RelayLifecycleChecks.swift; do
  if [ -f "$support" ]; then SMOKE_SUPPORT+=("$support"); fi
done

echo "== 编译冒烟测试可执行文件（App 生产源码 + tools/smoke）=="
swiftc -o "$OUT" -swift-version 5 -target "$TARGET" \
  ProxyBridge/Models/*.swift ProxyBridge/Persistence/*.swift ProxyBridge/Services/*.swift \
  ProxyBridge/Presentation/AppViewModel.swift \
  ProxyBridgeTests/MockServices.swift \
  "${SMOKE_SUPPORT[@]}" \
  tools/smoke/SmokeMain.swift

echo "== 执行 =="
"$OUT"
