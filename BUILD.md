# BUILD · 构建与运行指南

## 环境要求

| 场景 | 要求 |
|---|---|
| Xcode 构建（正式路径） | macOS 14+，Xcode 15+（含 macOS 14 SDK；Xcode 16 亦可打开工程） |
| 免 Xcode 构建（本仓库验证路径） | Command Line Tools（Swift 6.0 编译器，`xcode-select --install`） |

不需要付费 Apple Developer 账户：工程设置了 `CODE_SIGNING_ALLOWED = NO`，本地构建/测试均不签名。

## 路径 1：Xcode（推荐）

```bash
# 打开
open ProxyBridge.xcodeproj

# 命令行构建 + 测试（等价于 Xcode 里 ⌘R / ⌘U）
xcodebuild -project ProxyBridge.xcodeproj -scheme ProxyBridge -configuration Debug build
xcodebuild -project ProxyBridge.xcodeproj -scheme ProxyBridge test
# 或一键：bash scripts/xcode_test.sh
```

- 运行：菜单栏出现 ⇄ 图标（应用是 LSUIElement，无 Dock 图标）。
- 设置窗口：点面板齿轮，或系统 ⌘,（应用激活时）。
- Scheme 已共享（`xcshareddata/xcschemes/ProxyBridge.xcscheme`），CI 可直接 `-scheme ProxyBridge`。

## 路径 2：Command Line Tools（无完整 Xcode）

```bash
bash scripts/typecheck.sh    # ① App 模块 -emit-module 编译检查（0 error）
                            # ② 测试代码类型检查（XCTest shim，编译级）
                            # ③ Swift 6 语言模式预检
bash scripts/smoke_test.sh   # 编译 + 执行生产源码回归断言（含 v2 动态 SOCKS5 与 B+ 路径）
bash scripts/build_app.sh    # swiftc 链接 build/ProxyBridge.app（ad-hoc 签名 + 应用图标）
bash scripts/install_app.sh  # 安装到 /Applications 并启动（日常使用推荐）
```

说明：
- CLT 不含公开 XCTest.framework，`xcodebuild test` 无法执行——因此提供 `tools/smoke` 作为真实执行证据；XCTest 断言已做编译级检查，运行需要完整 Xcode。
- `build_app.sh [目标三元组]` 可交叉编译（默认 `arm64-apple-macos14.0`；Intel Mac 传 `x86_64-apple-macos14.0`）。

## 工程要点

- `objectVersion = 56` 的传统 pbxproj（显式 PBXFileReference），Xcode 14–16 均可打开；Xcode 打开后可能提示升级工程格式，属正常。
- `SWIFT_VERSION = 5.0`（Swift 5 语言模式）：Xcode 15（Swift 5.9/5.10）与 Xcode 16（Swift 6 编译器）都能编译；`scripts/typecheck.sh` 第 ③ 步验证过 Swift 6 语言模式也可通过。
- `GENERATE_INFOPLIST_FILE = YES` + `INFOPLIST_KEY_LSUIElement = YES`（菜单栏应用形态）。
- 无任何第三方依赖、无 SPM 包。
- zh-Hans 为开发语言（`Localizable.strings` 基础设施就位，文案集中在视图/ViewModel 常量）。

## 常见问题

| 症状 | 处理 |
|---|---|
| `xcodebuild: error: tool 'xcodebuild' requires Xcode` | 本机只有 CLT。`sudo xcode-select -s /Applications/Xcode.app` 后重试，或走路径 2 |
| 测试 target 报找不到 TEST_HOST | 先构建 App target（scheme 的 test action 已配置依赖，直接 `test` 会先构建宿主） |
| 菜单栏看不到图标 | 系统设置 → 控制中心 → 菜单栏；或检查是否有同 ID 旧实例（活动监视器搜 ProxyBridge） |
| 想重置全部配置 | 删除 `~/Library/Application Support/ProxyBridge/` |
