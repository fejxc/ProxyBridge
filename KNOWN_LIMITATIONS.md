# 已知限制（截至 ProxyBridge v2 开发分支）

已实现 SSH 密码/钥匙串/密钥认证、网络退避重连、周期健康检查、睡眠唤醒恢复、启动连接、登录项注册和系统异常通知。手动断开停止重试；认证与主机指纹错误需要人工处理。

- **系统权限由用户决定**：登录项可能等待系统批准，通知可能被拒绝。界面显示实际状态，启动不自动请求通知授权、不重新注册被撤销的登录项。
- **未公证**：当前为 ad-hoc 签名；其他电脑首次打开可能被 Gatekeeper 拦截。Developer ID 签名与 Apple 公证尚未接入。
- **系统交互验收**：真实通知展示、实际注销/登录后的启动、实体 Mac 睡眠/唤醒尚待人工验证；状态机、注册失败、批准状态、退避取消和通知逻辑使用替身验证。
- **测试环境**：当前执行环境只有 Command Line Tools，不能运行 xcodebuild/XCTest；本机使用 `scripts/typecheck.sh` 检查 App 与 XCTest 源码，使用 `scripts/smoke_test.sh` 执行生产代码断言。真实 Xcode XCTest 与 Intel 实机运行仍待验收。
- **需要重新输入密码的情况**：未记住的密码不会跨连接保存，重连需输入；认证被拒绝会清除对应记住密码。主机密钥错误不会被误当成密码错误清除密码。
- **协议与网络范围**：静态上游只使用经实测的本地回环代理；动态反向 SOCKS5 不依赖 Mac 代理端口，可兼容 TUN/Network Extension 出站。远端只绑定 127.0.0.1；不支持 IPv6 字面量 SSH 主机、PAC 结果解析、代理认证、UDP 或透明系统代理。
- **自动检测端点变更**：已有 SSH 隧道保持原端点，周期检查验证该端点；网络重连会重新解析最新候选。修改连接参数后仍建议断开重连。
- **探测依赖**：本地和远端需 curl；探测 `https://api.openai.com/v1/models`，HTTP 401 视为 HTTPS 路径可达。远端缺 curl、网络超时或目标服务不可达时会如实降级。
- **界面限制**：菜单栏固定宽度；超大字体及小屏自适应、逐页视觉验收未完成；当前只提供简体中文。

1.1.0 已在 GitHub Releases 发布；早期阶段报告保留当时状态，当前限制以本文件和 1.1.0 阶段报告为准。

## 1.2.0 补充

- 流量仅为 Relay 成功写入目标连接的业务字节，包含健康检查，不等同于物理网卡流量或对端应用确认接收量。会话累计仅保留在内存中，App 退出后不保留。
- 每个 Relay 最多接受 256 个同时连接，超过上限会关闭新连接；每个方向最多有一块 64 KiB 数据待发送。
- 当前工程未启用 App Sandbox；尚未验证 Sandbox 下的网络权限和 SSH 子进程限制。
- 本机完成 arm64 验证与 arm64/x86_64 通用包编译，未在 Intel 实机运行 1.2.0，1.2.0 已通过 GitHub CI（含 Xcode/XCTest）、arm64/x86_64 原生编译与 TCP 测试，并发布通用 DMG。详见[流量统计报告](docs/TRAFFIC-STATISTICS.md)。

## v2 开发分支补充

- **真实远端待验收**：本次没有执行真实 Linux SSH/Clash Network Extension 连接。`ssh -R 127.0.0.1:<port>`、远端 curl、Linux Codex smoke test、Privoxy 实际启动/清理均未声称实测通过；手工流程见[升级验收报告](docs/PROXYBRIDGE_V2_ACCEPTANCE.md)。
- **动态 SOCKS5 范围**：OpenSSH 反向动态代理只保证 TCP。Linux 应用需支持 SOCKS5；Codex HTTP 兼容性依赖用户已安装的 Privoxy 且 HTTP CONNECT 实测通过。
- **Clash 出站确认**：远端 SOCKS/HTTP 请求成功可以证明 Mac 当前网络出口能到达验证目标，但不能确认 Clash 实际命中的规则或代理节点；界面会提示用户在 Clash「活动」中核对。
- **动态流量统计**：动态 SOCKS5 不经过本地 TCP Relay，因此准确业务字节统计显示「暂不可用」，不会把 SSH 进程字节当代理流量。
- **Privoxy 管理**：需要 Linux 已安装 Privoxy、配置目录可读以及 `ss` 或 `netstat` 可检查 HTTP 端口。应用不安装软件、不用 sudo、不写系统配置；管理或清理状态无法确认时会报告不确定，不会声称已停止。
