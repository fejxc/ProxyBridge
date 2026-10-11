# ProxyBridge（macOS 原生菜单栏应用）

> 版本：MVP 0.1.0 · **阶段 B（本地代理自动检测）**
> 目标：把「Mac 本地代理 → SSH 反向转发 → 远端 Linux 服务器可用」做成有真实健康状态的菜单栏工具。

## 这个仓库是什么

SwiftUI 菜单栏应用（`MenuBarExtra` + 独立设置窗口），当前完成阶段 A + B：

| 层 | 状态 |
|---|---|
| 工程与构建 | ✅ `.xcodeproj`（App + XCTest target，macOS 14+），可 `xcodebuild` 构建 |
| 数据模型与校验 | ✅ ServerProfile / LocalProxyEndpoint / TunnelSnapshot + 纯函数校验（白名单反注入） |
| 持久化 | ✅ `~/Library/Application Support/ProxyBridge/`（profiles.json / settings.json，原子写） |
| 菜单栏面板 + 设置窗口 | ✅ 按原型结构实现，ViewModel 注入服务，View 无业务逻辑 |
| 本地代理检测 | ✅ **真实实现**：`SCDynamicStore` 读取 + 变化通知防抖 + `/usr/bin/curl` 逐协议实测（HTTP/SOCKS5 分开验证，407/TLS/超时/拒绝分类呈现） |
| SSH 隧道 | 🎭 **Mock 演示**（阶段 C 接真实 SSH） |
| 登录启动 / 自动重连 | ⏳ 阶段 D（UI 中明确标注未生效） |

**诚实性约定**：检测结果与演示行为严格区分（`isLive`）——真实 curl 验证显示「已验证」，Mock 显示「已验证 · 演示」；任何绿色状态都有真实网络证据或明确演示标注。

## 目录结构

```
ProxyBridge/
├── ProxyBridge.xcodeproj        # Xcode 工程（objectVersion 56，Xcode 14/15/16 可打开）
├── ProxyBridge/                 # App target 源码
│   ├── App/ProxyBridgeApp.swift # @main：MenuBarExtra + Settings 场景
│   ├── Models/                  # 数据模型 + 校验（纯函数）
│   ├── Persistence/             # JSON 仓库（目录可注入，供测试）
│   ├── Services/                # LogStore/脱敏、TunnelService 协议 + Mock、检测协议 + Mock
│   └── Presentation/            # AppViewModel + 全部 SwiftUI 视图与设计令牌
├── ProxyBridgeTests/            # XCTest（9 个文件；阶段 A 范围）
├── tools/
│   ├── smoke/SmokeMain.swift    # 无 Xcode 环境的冒烟测试（73 项断言，真实执行）
│   └── xctest-shim/             # XCTest 编译级类型检查 shim（仅本地检查用，不入工程）
├── scripts/
│   ├── typecheck.sh             # swiftc 全模块编译检查（App + 测试代码）
│   ├── smoke_test.sh            # 编译并执行冒烟测试
│   ├── build_app.sh             # 不依赖 Xcode 直接产出可运行 .app（本地调试用）
│   └── xcode_test.sh            # 有完整 Xcode 时的 xcodebuild build + test
└── docs/
    ├── PHASE_A_REPORT.md        # 阶段 A 交付报告（通过/失败/未验证/阻塞）
    └── evidence/                # 运行证据（截图等）
```

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
bash scripts/smoke_test.sh          # 73 项核心逻辑断言（真实执行）
bash scripts/build_app.sh && open build/ProxyBridge.app   # 构建并运行
```

## 使用（阶段 A）

1. 运行后菜单栏出现 ⇄ 图标。图标按状态切换 SF Symbol 形态（实心圆=已验证、感叹号=降级等）并带 VoiceOver 状态文本；macOS 菜单栏的模板渲染下颜色以系统单色为主，**五色状态语义以面板内的彩色状态标签为准**（颜色永远伴随文字）。
2. 点图标 → 首次为空状态，点「打开设置，添加服务器」。
3. 「服务器」页填写名称/主机/端口/用户名/认证方式（校验不通过无法保存；删除需二次确认）。
4. 「本地代理」页可看演示检测结果 / 手动指定回环端点（仅 127.0.0.1 / ::1 / localhost）。
5. 面板上「连接」驱动 Mock 状态机（checking → connecting → connected 或 degraded/authRequired/error 剧本）；「复制远端代理命令」生成 export 示例（未验证时自带提醒注释）。
6. 「连接日志」看 `[演示]` 标记的事件流；「复制脱敏日志」遮挡 IP/用户@主机/密钥路径/凭据。

## 排障

- **配置文件损坏**：启动日志会提示已把 `profiles.json` 改名为 `profiles.corrupt-<时间>.json` 并以空配置启动。
- **存储位置**：`~/Library/Application Support/ProxyBridge/`（删掉即重置）。
- **看日志**：面板 → 查看日志；或 `log stream --predicate 'subsystem == "dev.sunyun.ProxyBridge"'`。
- **构建细节与已知限制**：见 [BUILD.md](BUILD.md)、[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)。

## 安全设计要点（阶段 A 已落实）

- host/username 走字符白名单校验，端口必须 1–65535 数值——从模型层排除 shell 注入面。
- 远程绑定固定 `127.0.0.1`（`ServerProfile.remoteBindHost` 常量，无公开修改途径）。
- 不保存任何密钥内容/密码；identityFile 只是路径引用；日志入库前剥离 ANSI 并遮挡密钥路径/凭据。
- 三态语义：`nil=未验证 ≠ true=已验证`；SSH 存活但远端未验证只显示橙色「部分可用」，绝不显示绿色。
- 用户断开 = 终态，Mock 层保证之后零事件（无 ghost 重连），并有测试钉死。

后续阶段接入真实 SSH 时的红线（提前声明）：`StrictHostKeyChecking=yes` 强制、BatchMode、不经 `sh -c`、远端探测命令只由受控常量 + 数字端口组成。
