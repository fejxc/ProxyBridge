# 阶段 D 交付报告 · 1.1.0 开发版

日期：2026-10-12。已安装到 `/Applications/ProxyBridge.app`，版本 1.1.0、构建号 2。GitHub Release：v1.1.0。

## 实现

- `ManagedTunnelService` 包装 SSH 协调器，管理连接意图、重试、周期探测和睡眠恢复，不保存密码。
- 网络不可达、超时、拒绝连接、DNS 和意外进程退出按 1/2/4/8…秒退避，上限 60 秒；稳定连接 60 秒后重置。认证、主机密钥、转发配置错误停止重试。关闭自动重连、手动断开或退出取消待重试任务。
- 本地检查默认 30 秒，只验证实际代理端点；远端默认 60 秒，独立 SSH/curl 实测。复用协调器并发守卫，无重叠探测。远端本次未验证会清除旧绿色结论；周期认证失败终止当前隧道并停止继续探测。
- NSWorkspace 睡眠通知暂停计时并清理所属 SSH；唤醒后仅恢复此前活动、允许重连的会话。认证终态、关闭恢复或睡眠期间手动断开的会话不恢复。
- App 启动后，只连接用户明确勾选 connectAtLaunch 的服务器，等本地检测完成后解析端点；多个密码请求排队。
- SMAppService.mainApp 注册/注销登录项，读取实际 enabled/requiresApproval 状态；注册失败不显示已启用，不在启动时自动重注册用户撤销的登录项。
- UNUserNotificationCenter 读取实际授权状态，用户点击按钮才请求授权。错误提醒按服务器冷却 5 分钟，降级持续 60 秒才提醒；恢复、断开、关闭通知会取消待发提醒。通知正文为固定通用文案，不包含地址、用户名或凭据。
- 配置字段沿用已有 JSON 格式，无数据迁移；更新实际设置控件、版本与文档。主机密钥错误不再被密码模式误报为错密码，也不会清除已存密码。

## 验收四态

| 项目 | 状态 | 证据 |
|---|---|---|
| App + 测试代码编译 | 通过 | typecheck 0 error；Swift 6 预检通过。既有测试 warning 保留，未使用 xcodebuild/XCTest。 |
| 冒烟测试 | 通过 | 143 项 PASS、0 项失败；含原有 114 项与阶段 D 的 29 项回归。 |
| 退避 / 用户断开 / 重连开关 | 通过 | 定时任务真实执行，涵盖退避待发、同步重连回调中断开及开关取消。 |
| 睡眠恢复逻辑 | 通过 | 模拟睡眠/唤醒入口，覆盖允许恢复、关闭恢复、认证终态、睡眠期间手动断开。 |
| 周期探测 | 通过 | 独立本地/远端周期；生产本地检查不调用远端；远端 unknown 清除旧绿色状态；认证失败停止探测。 |
| 登录项与通知逻辑 | 通过 | 系统服务替身验证批准状态、注册失败、不擅自请求通知授权、去重、关闭与待发取消。 |
| 真实服务器初次连接 | 通过 | root@10.11.154.192:20064，临时反向端口 47891，本地 HTTP 7897，远端 HTTP 200。 |
| 真实进程失败恢复 | 通过 | 仅 SIGKILL 测试自己拥有的 SSH PID，意外退出后自动重建，并再次端到端 HTTP 200。 |
| 真实周期远端验证 | 通过 | 使用缩短测试周期再次经远端 SSH/curl 返回 HTTP 200；手动断开后 2.5 秒无额外事件。 |
| 本地通用 DMG | 通过 | build_dmg.sh 1.1.0 完成；挂载验证版本、双架构、签名及 Applications 链接。 |
| 显式启动与再次打开 | 通过 | 修复菜单栏应用没有可见窗口的启动反馈；安装后读到 ProxyBridgeSettings 窗口，并在 Finder 实际双击已运行应用，确认同一设置窗口获得焦点。 |
| 应用安装启动 | 通过 | install_app.sh 完成；确认进程存活及 Info.plist 1.1.0/build 2。 |
| 实体睡眠/唤醒、注销/登录 | 未验证 | 本轮未让用户电脑进入睡眠或注销；NSWorkspace 与登录项 API 编译接线完成，行为逻辑以替身验证。 |
| 系统通知实际弹出、登录项实际注册授权 | 未验证 | 需用户在应用中操作并决定系统授权，本轮未自动更改其系统登录项或申请通知授权。 |
| 1.1.0 GitHub 双架构与原生 XCTest | 通过 | CI 两架构检查、完整 XCTest 和 Xcode 构建通过；v1.1.0 Release 已上传通用 DMG 与 SHA-256 文件。 |
| 失败 / 阻塞 | 无 | 必要的编译、回归、真实服务器验证与安装完成；人工系统授权验收列在上方。 |

真实服务器验证时密码仅通过隐藏回显的 stdin 输入，在内存中使用，没有写入源码、argv、环境变量或日志，没有修改服务器配置、主机密钥或用户钥匙串。

## 使用

1. 服务器设置开启「网络波动时自动恢复 SSH 连接」；需要启动自动连接时另勾选「App 启动后，自动连接此服务器」。
2. 通用设置选择本地/远端检查周期。
3. 登录启动开关注册系统登录项；如等待批准，到「系统设置 → 通用 → 登录项」确认。
4. 开启异常通知并点击「授权通知」，在系统弹窗中自行选择。拒绝时界面显示状态，不伪称已授权。
5. 手动断开仍是终态，重新点击连接后才恢复连接意图。

API 依据：[Apple SMAppService 注册](https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29)、[等待批准状态](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum/requiresapproval)、[通知授权](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization%28options%3Acompletionhandler%3A%29/)。

检查输出保留在 `build/typecheck-result.log`、`build/smoke-result.log`、`build/install-result.log`。不含凭据的真实服务器诊断源码保留于 git 忽略目录 `build/pty-diagnostics/runtime-live.swift`。
