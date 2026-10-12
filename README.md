# ProxyBridge（macOS 原生菜单栏应用）

> 当前开发版本：**1.1.0（阶段 D）** · macOS SSH 反向代理工具
> 目标：把「Mac 本地代理 → SSH 反向转发 → 远端 Linux 服务器可用」做成有真实健康状态的菜单栏工具。

## 这个仓库是什么

SwiftUI 菜单栏应用（`MenuBarExtra` + 独立设置窗口），已实现 SSH 隧道及运行时恢复：

| 层 | 状态 |
|---|---|
| 工程与构建 | ✅ `.xcodeproj`（App + XCTest target，macOS 14+），可 `xcodebuild` 构建 |
| 数据模型与校验 | ✅ ServerProfile / LocalProxyEndpoint / TunnelSnapshot + 纯函数校验（白名单反注入） |
| 持久化 | ✅ `~/Library/Application Support/ProxyBridge/`（profiles.json / settings.json，原子写） |
| 菜单栏面板 + 设置窗口 | ✅ 按原型结构实现，ViewModel 注入服务，View 无业务逻辑 |
| 本地代理检测 | ✅ **真实实现**：`SCDynamicStore` 读取 + 变化通知防抖 + `/usr/bin/curl` 逐协议实测（HTTP/SOCKS5 分开验证，407/TLS/超时/拒绝分类呈现） |
| SSH 隧道 | ✅ **真实实现**：`/usr/bin/ssh` 参数数组直启（StrictHostKeyChecking 强制、BatchMode、远端固定 127.0.0.1）、宽限期+退出分类、远端一次性 curl 端到端验证、App 退出清理子进程 |
| 登录启动 / 自动重连 | ✅ SMAppService 注册与状态显示；网络故障退避重连，认证/指纹失败停止重试 |
| 周期检查 / 异常通知 | ✅ 独立本地与远端周期；异常去重、持续降级提醒，需系统通知授权 |
| 睡眠 / 唤醒 / 启动连接 | ✅ 睡眠清理，唤醒恢复允许的会话；启动只连接明确勾选的服务器 |

**诚实性约定**：生产装配下 SSH 隧道与代理检测均为真实实现；`connected` 严格等于「本地代理已验证 + ssh 存活 + 远端 curl 验证成功」，缺 curl/超时一律 degraded（未验证 ≠ 可用）；用户手动断开为终态、之后绝不自动重连；App 退出终止全部自身 ssh 子进程。

## 目录结构

```
ProxyBridge/
├── ProxyBridge.xcodeproj        # Xcode 工程（objectVersion 56，Xcode 14/15/16 可打开）
├── ProxyBridge/                 # App target 源码
│   ├── App/ProxyBridgeApp.swift # @main：MenuBarExtra + Settings 场景
│   ├── Models/                  # 数据模型 + 校验（纯函数）
│   ├── Persistence/             # JSON 仓库（目录可注入，供测试）
│   ├── Services/                # 日志脱敏、SSH 隧道及本地代理检测
│   └── Presentation/            # AppViewModel + 全部 SwiftUI 视图与设计令牌
├── ProxyBridgeTests/            # XCTest 与仅测试目标使用的替身
├── tools/
│   ├── smoke/SmokeMain.swift    # 无 Xcode 环境的冒烟测试（142 项断言，真实执行）
│   ├── smoke/SmokeFakes.swift   # 冒烟专用进程替身（驱动生产协调器）
│   └── xctest-shim/             # XCTest 编译级类型检查 shim（仅本地检查用，不入工程）
├── scripts/
│   ├── typecheck.sh             # swiftc 全模块编译检查（App + 测试代码）
│   ├── smoke_test.sh            # 编译并执行冒烟测试
│   ├── build_app.sh             # 不依赖 Xcode 直接产出可运行 .app（本地调试用）
│   └── xcode_test.sh            # 有完整 Xcode 时的 xcodebuild build + test
└── docs/
    ├── PHASE_A/B/C_REPORT.md    # 各阶段交付报告（通过/失败/未验证/阻塞）
    └── evidence/                # 运行证据（截图等）
```

## 下载与安装（无需开发工具）

在 [GitHub Releases](https://github.com/fejxc/ProxyBridge/releases/latest) 下载 `ProxyBridge-版本号-universal.dmg`，适用于 macOS 14+ 的 Apple Silicon 和 Intel Mac。

打开 DMG，将 `ProxyBridge.app` 拖入 `Applications`，随后从应用程序文件夹启动。当前为 ad-hoc 签名、未经过 Apple 公证；首次运行若被阻止，确认下载来源后可按 [Apple 官方说明](https://support.apple.com/102445) 在系统设置的「隐私与安全性」中允许打开。

每台 Mac 需自行配置代理客户端、服务器及 SSH 主机指纹；安装包不包含任何用户配置、密码或私钥。

自动打包流程及发布方法见 [docs/RELEASE.md](docs/RELEASE.md)。

## 快速开始

### 有完整 Xcode 的 Mac（推荐）

```bash
open ProxyBridge.xcodeproj          # Xcode 打开，直接 ⌘R 运行
# 或命令行：
xcodebuild -project ProxyBridge.xcodeproj -scheme ProxyBridge build
bash scripts/xcode_test.sh          # 构建 + XCTest 全量测试
```

### 只有 Command Line Tools 的 Mac（本仓库的验证路径）

```bash
bash scripts/typecheck.sh           # swiftc 全模块类型检查（App + 测试代码）
bash scripts/smoke_test.sh          # 142 项核心逻辑断言（真实执行，含状态机序列与真实 ssh 进程证据）

# 日常安装（推荐）：构建 + 装入 /Applications + 自动启动
bash scripts/install_app.sh
# 之后随时打开：Spotlight 搜「ProxyBridge」/ 启动台 / Finder 双击 /Applications/ProxyBridge.app
# 或仅构建不安装：bash scripts/build_app.sh && open build/ProxyBridge.app
```

## 使用（阶段 C：全部为真实行为）

1. 双击应用会打开设置窗口；应用已运行时再次双击会把同一个窗口带到前台，关闭窗口后菜单栏服务继续运行。运行后菜单栏出现 ⇄ 图标。图标按状态切换 SF Symbol 形态并带 VoiceOver 状态文本；**五色状态语义以面板内的彩色状态标签为准**（颜色永远伴随文字）。
2. 首次为空状态 → 「打开设置，添加服务器」：名称/主机/SSH 端口/用户名/认证方式（校验不通过无法保存；删除需二次确认）。
3. 「本地代理」页显示**真实检测结果**（本机系统代理 + curl 逐协议实测）；也可手动指定回环端点。
4. 面板「连接」执行真实序列：本地代理验证 → 前置检查（ssh/密钥文件）→ 启动 `/usr/bin/ssh -N -T -R 127.0.0.1:<远端>:127.0.0.1:<本地>`（StrictHostKeyChecking=yes）→ 宽限期确认转发 → **远端一次性 curl 端到端验证** → connected（绿）或如实 degraded/authRequired/error。
5. 首次连接未知主机会被拒绝（安全设计）：请先在终端手动 `ssh <user>@<host>` 核对指纹写入 known_hosts，再回 App 连接。
6. 「检查连接」复核本地 + 远端（带冷却）；「复制远端代理命令」按实测协议生成 export 示例（未验证时自带提醒注释）；断开后**绝不自动重连**；网络意外断线则按各服务器的自动重连设置恢复。

## 应用图标

应用图标使用蓝色双向隧道 Logo，外围白底已移除为透明背景。图标源图位于 `ProxyBridge/Resources/AppIcon.png`，发布资源为 `ProxyBridge/Resources/ProxyBridge.icns`，CLI 构建与 Xcode 工程共用。

更换原图后运行 `bash scripts/generate_icon.sh`，生成标准 macOS 多尺寸图标；之后重新构建 App 或 DMG。

## 运行时恢复与系统授权

- 各服务器可开启自动重连。网络故障按 1、2、4、8 秒逐步退避，上限 60 秒；稳定连接 60 秒后重置退避。认证、指纹和转发配置错误需要人工处理，不会无限尝试密码。
- 本地检查默认 30 秒，不创建远端 SSH；远端检查默认 60 秒，通过 curl 验证真实代理。未能验证会降级，不保留旧绿色结论。
- 睡眠清理所属 SSH 进程，唤醒后仅恢复允许自动重连且此前活动的连接；手动断开、关闭自动重连或认证终态不会恢复。
- 通用设置可注册登录项，显示已启用/等待批准/失败的实际状态；应用不会在启动时自动重新注册用户已撤销的登录项。
- 点击「授权通知」由系统询问。连接错误按服务器冷却 5 分钟，持续降级 60 秒才提醒；断开、恢复和关闭通知会取消待发提醒。通知正文不含服务器地址、用户名或凭据。
- 多个密码请求会排队；密码未记住时，自动重连仍需在界面重新输入。

阶段 D 的验收和未验证项见 [docs/PHASE_D_REPORT.md](docs/PHASE_D_REPORT.md)。

## 排障

- **配置文件损坏**：启动日志会提示已把 `profiles.json` 改名为 `profiles.corrupt-<时间>.json` 并以空配置启动。
- **存储位置**：`~/Library/Application Support/ProxyBridge/`（删掉即重置）。
- **看日志**：面板 → 查看日志；或 `log stream --predicate 'subsystem == "dev.sunyun.ProxyBridge"'`。
- **登录启动**：通用设置开启；以系统实际注册状态为准。如提示等待授权，到系统设置的「通用 → 登录项」确认。只有明确勾选「App 启动后自动连接」的服务器才会在启动时连接。
- **重装/升级**：重跑 `bash scripts/install_app.sh`（会自动停止旧实例后覆盖）。
- **构建细节与已知限制**：见 [BUILD.md](BUILD.md)、[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)。

## 安全设计要点（阶段 A–C 已落实）

- host/username 字符白名单校验、端口必须数字——模型层排除 shell 注入面；SSH/远端探测全程参数数组直启 `/usr/bin/ssh`，**不经 shell**。
- `StrictHostKeyChecking=yes` 强制（写死在 builder，有逐字断言测试）；远程绑定固定 `127.0.0.1`（常量，无修改途径）。
- 远端探测脚本为受控常量全等断言（`testRemoteProbeScriptIsExactConstant`）：数字端口 + 白名单 URL + `command -v curl`，无任何用户自由文本。
- curl 探测首参 `-q` 跳过 `~/.curlrc`（防配置劫持，已实测）；ssh 环境仅透传 PATH/HOME/SSH_AUTH_SOCK（有断言）。
- 不保存密钥内容/密码；identityFile 仅路径引用（含空格逐字保真）；日志入库前剥离 ANSI 并遮挡密钥路径/凭据。
- 三态语义 `nil=未验证 ≠ true=已验证`；`connected` 必须三层全绿；error/authRequired 终态绝不被健康检查或迟到探测翻绿（有竞态回归测试）。
- 用户断开 = 终态（零 ghost 事件，双层钉死）；进程清理只杀本 App 句柄（SIGTERM→2s SIGKILL 升级），App 退出时 `willTerminate` 全量清理。
