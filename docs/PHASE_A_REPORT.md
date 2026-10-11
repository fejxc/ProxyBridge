# 阶段 A 交付报告 · 工程与 UI

> 日期：2026-10-11 ｜ 对应 05-IMPLEMENTATION-PLAN 的 M0 + M1
> 环境：macOS 15.1.1（arm64）· Swift 6.0.2（Command Line Tools，**无完整 Xcode**）

## 一、状态总览（通过 / 失败 / 未验证 / 阻塞）

| 项 | 状态 | 说明 |
|---|---|---|
| `.xcodeproj` 创建（App + XCTest target，macOS 14+） | ✅ 通过 | `plutil -lint` OK；UUID 全 24 位、无悬空引用；共享 scheme |
| Swift 全模块编译（App，Swift 5 语言模式） | ✅ 通过 | `swiftc -emit-module` 0 error 0 warning（见 §三命令与输出） |
| 测试代码编译级检查（XCTest shim） | ✅ 通过 | 0 error |
| Swift 6 语言模式预检（App 模块） | ✅ 通过 | 为将来升级工具链预留信心 |
| 冒烟测试执行（生产代码直连断言） | ✅ 通过 | **80/80 PASS**（真实编译并执行） |
| 本地 `.app` 构建与启动 | ✅ 通过 | swiftc 链接 + ad-hoc 签名，进程启动确认（pid 可查） |
| `xcodebuild build` | ⛔ 阻塞 | 本机只有 CLT 无完整 Xcode；**未执行、不虚称通过**。请在有 Xcode 的 Mac 上跑 `bash scripts/xcode_test.sh` |
| XCTest 断言真实运行 | ⚠️ 未验证 | 同上原因。已用 80 项等价冒烟断言 + 编译级检查替代作为证据 |
| UI 截图 | ⚠️ 部分 | 全屏截图 2 张已存 `docs/evidence/`（进程运行佐证）；面板需人工点击展开，本会话无 GUI 自动化能力，未做像素级校验 |
| 深色模式 / VoiceOver / 键盘导航人工验收 | ⚠️ 未验证 | 代码层已落实（语义色、a11y label、等宽数字）；需真机人工过一遍 |
| E01–E10 端到端（真实 SSH/代理） | ⛔ 计划外 | 属阶段 B/C/D；未开始、未声称 |

## 二、交付内容

### 变更清单（本仓库首次提交 + 评审修复）

**工程**：`ProxyBridge.xcodeproj`（objectVersion 56，Xcode 14/15/16 可开）、共享 scheme、无第三方依赖、`CODE_SIGNING_ALLOWED=NO`（免开发者账户）。

**源码（App target，21 文件）**
- `App/ProxyBridgeApp.swift` — @main；MenuBarExtra（window 样式）+ Settings 双场景
- `Models/` — ServerProfile（含 `ServerProfileRule` 纯函数校验：主机/用户名白名单、端口边界、认证完整性）、LocalProxyEndpoint（回环白名单）、TunnelStatus（TunnelPhase/TunnelSnapshot/**三态可空布尔**/StatusPresentation 纯映射）
- `Persistence/` — ProfileRepository（JSON 原子写、损坏隔离改名、重复 id 去重、悬空 currentProfileId 回退）、AppSettingsStore（损坏检测上报）
- `Services/` — LogStore（500 条环形 + OSLog 镜像 + `[演示]` 前缀）、LogRedaction（ANSI CSI/OSC/C1/Cf 剥离、密钥路径/用户@主机/IP/凭据遮挡、超长截断）、TunnelService+ProxyDetectorService 协议（阶段 B/C 替换点）、MockTunnelService（状态机剧本）、MockProxyDetector（演示候选）、RemoteCommandTemplate（受控常量模板）
- `Presentation/` — AppViewModel（@MainActor @Observable，View 零业务逻辑）、MenuBarView（368pt 面板：演示横幅、服务器卡、三层健康、连接/断开/检查、复制命令）、SettingsView+ServerEditorView（校验、需重连提示、删除二次确认、未保存保护、端口冲突提示）、ProxySettingsView（自动/手动、演示标注）、LogsView（时间/级别/服务器筛选、动态脱敏文案）、GeneralSettingsView（真实持久化；登录启动明确标注阶段 D 未生效）、DesignSystem（深浅色语义色、无障碍标签）

**测试（XCTest，11 文件，74+ 用例）**：ProfileValidationTests（U06 全边界 + U07 空格路径保真）、ProfileRepositoryTests（U18 round-trip/损坏/去重/回退）、TunnelStatusTests（nil≠true、文案表逐条、健康三元组）、LogRedactionTests（U17 + C1/双向控制符）、RemoteCommandTemplateTests（含非法端口 nil 防御）、MockTunnelServiceTests（U13 断开零事件、U14 双连击、时序、健康检查不伪造绿色）、AppViewModelTests（持久化联动、校验拦截、需重连降级、手动端点优先）、LogStoreTests（容量/前缀/导出格式、设置损坏上报）。

**工具链**：`scripts/typecheck.sh`（4 步验证）、`scripts/smoke_test.sh`（80 项）、`scripts/build_app.sh`（免 Xcode 出 .app）、`scripts/xcode_test.sh`（有 Xcode 时一键 build+test）、`tools/xctest-shim`（仅本地编译检查，不入工程）。

**文档**：README、BUILD、KNOWN_LIMITATIONS、本报告。

### 评审与修复（对抗性工作流）

运行了 73-agent 的多维度对抗评审（安全红线/规范符合/代码质量/pbxproj/测试覆盖 → 每个发现 2 名独立怀疑者验证）：
**34 个发现 → 29 确认 → 已全部修复**。要点：

| 严重度 | 代表项 | 修复 |
|---|---|---|
| critical | pbxproj VariantGroup 子引用缺 `zh-Hans.lproj` 路径与 `name`，Xcode 构建必失败（swiftc 路径覆盖不到） | 子项改 `name=zh-Hans; path=zh-Hans.lproj/Localizable.strings` |
| high | `testLoneEscapeDropped` 断言与实现矛盾（验证 agent 用真实断言 runner 复现 70/71 过、此条必挂） | 测试改为与刻意语义一致（ESC+下一字符按转义序列消费），冒烟 S13e 同步全文相等 |
| high | `selectProfile` 不清新建草稿标记 → 编辑器卡死在「新服务器」 | selectProfile 重置 `editorIsNewDraft` |
| medium | Mock 健康检查可把 error 翻成全绿 connected | 只复核最近快照，错误终态保持原样 |
| medium | sanitize 漏 C1 控制字符与 Unicode 双向/格式符；密钥路径遮挡仅覆盖 `.ssh` 形态 | 扩展字符过滤 + 任意路径/`*.pem|key` 遮挡 |
| medium | 越界持久化 remotePort 触发 precondition 崩溃 | 模板返回 nil + VM 拒绝生成并记错误日志 |
| medium | 菜单栏面板无演示横幅（绿态无演示限定）；「未发现代理」文案缺失 | 面板加 DemoModeBanner；degraded+nil → 「未发现代理」 |
| medium | 切换 profile 静默丢弃编辑器未保存修改；手动代理 @State 跨 profile 串台 | 未保存保护横幅 + onChange 重载 |
| low×12 | DateFormatter 每行新建、settings 损坏静默、死代码、按钮文案与行为不一致、openSettings 已知不可靠、日志无时间筛选、健康行不可点、U06「拒绝保存」半边等 | 全部修复（SettingsLink、缓存 formatter、损坏上报、删除死代码、动态文案、时间筛选、点击进日志、VM 保存闸门） |

存疑项 4 个中 2 个已顺手补齐（U06 保存半边测试、U07 空格路径测试）；其余 2 个（跨 profile 端口冲突提示、徽标色调）一个已实现（冲突提示）、一个记录为低优先样式项。

## 三、验证命令与真实输出（本机）

```console
$ plutil -lint ProxyBridge.xcodeproj/project.pbxproj
ProxyBridge.xcodeproj/project.pbxproj: OK

$ bash scripts/typecheck.sh
== [2/4] App 模块编译检查 ==
App 模块检查通过（0 error）
== [3/4] 测试代码类型检查 ==
测试代码检查通过（0 error）
== [4/4] Swift 6 语言模式预检 ==
Swift 6 语言模式：通过
typecheck: OK

$ bash scripts/smoke_test.sh
……（80 行 PASS）
----------------------------------------
通过 80 项，失败 0 项
RESULT: PASS

$ bash scripts/build_app.sh && open build/ProxyBridge.app
构建完成：build/ProxyBridge.app    # 2.9MB，ad-hoc 签名
$ pgrep -lf ProxyBridge.app/Contents/MacOS/ProxyBridge
89267 …/build/ProxyBridge.app/Contents/MacOS/ProxyBridge   # 进程运行确认
```

## 四、诚实性声明

1. **演示模式**：SSH 隧道与本地代理检测均为 Mock（阶段 B/C 落地）。所有演示行为在 UI（横幅/徽标/文案）与日志（`[演示]` 前缀）中明确标注；「已连接/已验证」绿态仅在演示剧本内出现且伴随「演示」限定。
2. **未验证项**：`xcodebuild build/test` 与 XCTest 真实执行因本机无完整 Xcode 未运行（⛔/⚠️ 状态如实标注），不声称通过；E2E 未开始。
3. **不存在的功能不标注可用**：登录启动开关禁用并注明阶段 D；通知仅存设置。
4. 安全红线核对：无 shell 拼接面（校验白名单 + 无 Process 调用）、remote bind 固定 127.0.0.1、无密钥内容持久化、日志脱敏有测试钉死、断开不重连有测试钉死、nil≠true 有测试钉死。

## 五、下一步（阶段 B · 本地代理自动检测）

1. `SystemProxyProvider`：`SCDynamicStoreCopyProxies` 读取 + `SCDynamicStoreKeyCreateProxies` 变更订阅 + 800ms 防抖。
2. `ProxyProtocolProbe`：`/usr/bin/curl` 参数数组（`--noproxy ""`、受控验证 URL、connect/max-time、退出码+HTTP 状态判定），`Process` 不经 shell。
3. 真实 `LocalProxyDetector` 替换 Mock（装配点：`AppViewModel.phaseADefault()` → 更名 live 装配）。
4. 测试：U01–U05、U12、U15（mock provider + 本地起可控 HTTP/SOCKS 服务器）。
