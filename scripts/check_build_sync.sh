#!/bin/bash
# 双构建系统一致性检查：pbxproj（显式 PBXFileReference）↔ swiftc 脚本管线（glob 通配）。
# 背景：swiftc 脚本按目录通配编译，新增/删除文件自动纳入；pbxproj 需要手工增删
# 文件引用——漏改会导致「脚本构建通过、Xcode 工程缺文件」或反之的静默漂移。
# 本脚本对两份文件清单做双向 diff，任何一侧不一致即非零退出。CI 与本地 typecheck 前均可运行。

set -euo pipefail
cd "$(dirname "$0")/.."

PBXPROJ="ProxyBridge.xcodeproj/project.pbxproj"
[ -f "$PBXPROJ" ] || { echo "check_build_sync: 未找到 $PBXPROJ"; exit 1; }

python3 - "$PBXPROJ" <<'PY'
import re
import sys
from pathlib import Path

pbxproj = Path(sys.argv[1]).read_text()

# pbxproj 侧：PBXFileReference 中 lastKnownFileType = sourcecode.swift 的 path。
refs = re.findall(
    r"isa = PBXFileReference;[^}]*?lastKnownFileType = sourcecode\.swift;[^}]*?path = (\"[^\"]+\"|[^;]+?);",
    pbxproj,
)
pbx_names = [r.strip('"') for r in refs]

# 磁盘侧：App target 与测试 target 的源码目录（tools/ 是开发工具，不进 pbxproj，排除）。
disk = sorted(
    str(p) for d in ("ProxyBridge", "ProxyBridgeTests")
    for p in Path(d).rglob("*.swift")
)
disk_names = [Path(p).name for p in disk]

problems = []
pbx_dupes = {n for n in pbx_names if pbx_names.count(n) > 1}
if pbx_dupes:
    problems.append(f"pbxproj 内文件名重复（无法与目录一一对应）: {sorted(pbx_dupes)}")
disk_dupes = {n for n in disk_names if disk_names.count(n) > 1}
if disk_dupes:
    problems.append(f"源码目录内文件名重复: {sorted(disk_dupes)}")

pbx_set, disk_set = set(pbx_names), set(disk_names)
missing_in_pbx = sorted(disk_set - pbx_set)
if missing_in_pbx:
    problems.append(
        "磁盘上存在但 pbxproj 未引用（Xcode 工程将缺文件）:\n  "
        + "\n  ".join(p for p in disk if Path(p).name in missing_in_pbx)
    )
missing_on_disk = sorted(pbx_set - disk_set)
if missing_on_disk:
    problems.append(f"pbxproj 引用了磁盘上不存在的文件: {missing_on_disk}")

if problems:
    print("check_build_sync: 发现构建系统清单漂移")
    for p in problems:
        print(f"  - {p}")
    sys.exit(1)

print(f"check_build_sync: OK（{len(disk_set)} 个 Swift 文件，pbxproj 与目录一致）")
PY

# 冒烟测试管线显式点名了 Presentation 下的两个文件（其余视图不进冒烟可执行文件），
# 这些名字被移动或删除时，此处第一时间报错而不是等到 smoke_test 编译失败。
for f in ProxyBridge/Presentation/AppViewModel.swift ProxyBridge/Presentation/L10n.swift; do
  [ -f "$f" ] || { echo "check_build_sync: smoke 管线依赖的 $f 不存在"; exit 1; }
done

echo "check_build_sync: smoke 管线依赖文件在位"
