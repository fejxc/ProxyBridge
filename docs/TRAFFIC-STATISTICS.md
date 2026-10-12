# 实时流量统计实现与验收（1.2.0）

验收日期：2026-10-12。本地验收完成，1.2.0 已准备通过版本标签触发 GitHub 发布工作流；云端结果以 Actions 和 Release 页面为准。现有 1.1.0 不包含此功能。

## 最小改动方案与最终文件

复用原 SSHTunnelCoordinator 和 ManagedTunnelService：本地代理校验后，先等待 Relay 就绪，再将现有 SSH -R 的本地目标指向 Relay。原代理协议和本地健康检查仍指向原代理。没有增加第二套 SSH 管理逻辑。

| 文件 | 作用 |
| --- | --- |
| Models/TrafficStatistics.swift | 会话快照、速率历史、单位转换及独立可观察数据 |
| Services/TCPRelay.swift | NWListener/NWConnection 双向透明转发、采样和清理 |
| Services/SSHTunnelCoordinator.swift | Relay 启动顺序、故障和断开生命周期、会话事件过滤 |
| Services/ManagedTunnelService.swift、TunnelService.swift | 复用原重连与睡眠流程，转发统计事件 |
| Models/ServerProfile.swift、Presentation/ServerEditorView.swift | 可选固定端口，兼容旧 JSON，端口范围校验 |
| Presentation/AppViewModel.swift | 独立统计存储，删除配置时清理，避免每秒全局刷新 |
| Presentation/TrafficStatsView.swift、MenuBarView.swift | 原连接区域下方的速率、累计量和可展开 60 秒曲线 |
| ProxyBridge.xcodeproj/project.pbxproj | 新文件加入原 App target，版本 1.2.0 / build 3 |
| tools/smoke/RelayLifecycleChecks.swift | 7 项 Relay 与 SSH 生命周期回归 |
| tools/relay/、scripts/relay_test.sh | 可控真实 TCP 服务、统计精度与清理验证、实测数据视觉预览 |
| scripts/smoke_test.sh、tools/smoke/SmokeMain.swift、原协调器测试 | 编译与调用新检查，兼容新事件 |
| .github/workflows/ci.yml、release.yml | 加入 TCP Relay 验证；旧标签无脚本时跳过该检查 |
| README.md、CHANGELOG.md、KNOWN_LIMITATIONS.md | 使用方法、发布状态与统计口径 |

## 链路与统计口径

Linux:远端端口 → 原系统 OpenSSH 反向隧道 → Mac:Relay → Mac:本地代理。

上传为 Linux → Mac 本地代理，下载为反方向。只有 NWConnection 的 send 完成回调没有错误时，才累计对应块的实际字节数。该口径是交给目标 TCP 连接的字节，不是远端应用确认处理量，也不包括 SSH 协议开销和物理网卡总流量。代理健康检查经过同一链路，会计入统计。Relay 不解析或修改 HTTP、SOCKS5、TLS 内容。

速率根据单调时钟实际采样间隔计算，每秒更新；单位按 1024 进位。最近 60 秒最多保留 60 个样本。SSH 断开后速率归零并保留本次累计量；任何新连接尝试及自动重连创建新会话。App 退出后不持久化统计。

未连接/连接建立期间速率显示占位；连接成功或隧道仍运行的降级状态显示实际数据。断开后累计量仍可查看。图表及浅深色预览来自实际 TCP 测量文件，不使用示意数值。

## 可靠性处理

- 默认端口 0 由系统选择空闲端口，可配置 1–65535（建议 17997）；NWListener 明确绑定 IPv4 127.0.0.1，关闭地址复用。监听失败时不启动 SSH。
- 独立 utility 队列处理网络与计数。每个方向只在上一块发送完成后读取下一块，单块上限 64 KiB，避免无界排队。每个 Relay 上限 256 个并发连接。
- 双向 EOF 分别半关闭；请求结束后仍可完整接收响应。已开始转发的连接通过接收回调排空缓冲，避免终态通知提前丢弃尾部数据。
- 目标连接建立超时 10 秒，Relay 启动超时 5 秒。取消、异常断开、SSH 退出、手动断开、睡眠和退出均关闭所属 Relay/连接；不操作其他 SSH 进程。
- 会话 ID 与递增序号过滤过期/乱序统计。睡眠或断开后允许最后一份累计快照送达，但不触发重连或恢复连接状态。
- 密码应答、StrictHostKeyChecking=yes 和单次密码尝试保持原实现。安装包与报告不包含用户凭据。
- 当前项目未启用 App Sandbox，也没有对应 entitlements。未声称 Sandbox 网络监听、出站连接或 SSH 子进程权限已经授权；将来启用时需单独验证。

## 已执行验收

| 验证 | 结果与证据 |
| --- | --- |
| 全模块与测试代码编译、Swift 6 预检 | 通过，build/typecheck-result.log，0 error |
| 冒烟回归 | 通过，150 项 PASS，build/smoke-result.log |
| 单连接精度/数据不变 | 通过，512 KiB 混合二进制内容逐字节相同，上下行计数精确 |
| 半关闭 | 通过，服务端收到请求 EOF 后才完整返回响应 |
| 多连接汇总 | 通过，8 个并发连接，合计与实际负载一致 |
| 空闲/历史长度 | 通过，空闲速率归零；额外运行 62 秒，历史上限 60 个样本 |
| 大文件/背压 | 通过，16 MiB 慢端传输数据与计数一致；一次本地测量直连 0.786 s，Relay 0.804 s，约 1.02 倍，仅作为本机回归参考 |
| 回环绑定与端口冲突 | 通过，lsof 确认为 IPv4 127.0.0.1；占用固定端口明确拒绝，无 SSH 误启动 |
| 清理与重启 | 通过，RST、运行中取消、启动取消、目标不可用均清理；端口可重用，重新开始计数 |
| Relay/SSH 集成 | 通过，先就绪再启动 SSH；手动断开、终止/睡眠清理、新会话、旧配置兼容均有断言 |
| 真实服务器端到端 | 通过，现有服务器 curl HTTP 200；终止本测试所属 SSH 后自动重连再次 HTTP 200；周期检查通过；手动断开后无再次状态事件/重连 |
| 浅色/深色界面 | 通过，SwiftUI ImageRenderer 生成并检查 build/traffic-light.png、build/traffic-dark.png；数据来源为本地真实 TCP 测量 |
| 本地安装与通用 DMG | 通过，/Applications/ProxyBridge.app；arm64/x86_64 编译、通用二进制、签名与磁盘镜像校验 |
| Intel 实机运行 | 未验证；云端验证和发布结果以对应 Actions 页面为准 |
| App Sandbox 下运行 | 未验证，当前未启用 Sandbox |

本地 TCP 验收日志：build/relay-test-result.log。原始字节统计采用可控测试服务，不能仅由 UI 数值判断是否通过。

## 复验和安装

```bash
bash scripts/typecheck.sh
bash scripts/smoke_test.sh
bash scripts/relay_test.sh
bash scripts/install_app.sh
bash scripts/build_dmg.sh 1.2.0
```

产物：build/dist/ProxyBridge-1.2.0-universal.dmg 及同目录 SHA-256 文件。当前为 ad-hoc 签名，未做 Apple 公证。
