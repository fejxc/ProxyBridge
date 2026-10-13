# ProxyBridge v2 升级验收报告

日期：2026-10-13
范围：Clash Network Extension/TUN、OpenSSH 反向动态 SOCKS5、静态转发兼容及默认启用的 Linux HTTP 入口。

## 审计与实施

项目位于 `/Users/sunyun/ProxyBridge-handoff/ProxyBridge`，开始时 Git 工作区干净。现有 SwiftUI/Xcode 工程已有配置 Codable 解码、代理协议探测、SSH 参数构建、进程生命周期、`SSHTunnelCoordinator`、远端 curl 验证和测试替身。本次沿用现有模型、协调器、进程工厂、ViewModel 与视图；未做大规模重构。

新增连接模式与端口字段有旧配置默认值：既有 `remotePort`、认证和代理选择仍保留；profile 缺少 v2 字段时解码为自动模式、SOCKS5 `17890`、HTTP `7890`，HTTP 适配器默认启用，使既有 Codex `HTTP_PROXY`/`HTTPS_PROXY` 继续使用 `7890`。用户可以明确关闭适配器。

## 分阶段结果

| 阶段 | 实现 | 本机结果 | 真实远端结果 |
|---|---|---|---|
| 1 · 反向动态 SOCKS5 | `ssh -R 127.0.0.1:<port>`；跳过 Mac 本地代理探测；远端 SOCKS 请求验活 | 通过：参数、状态机和无本地端点场景由生产代码冒烟断言覆盖 | 待验收：未连接 Linux 服务器 |
| 2 · 静态兼容与自动选择 | 保留旧静态 `-R remote:local`；增加 HTTP/SOCKS5/Mixed；读取系统代理和 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY；仅在候选经 curl 实测通过后使用，自动模式否则回退 B | 通过：旧配置默认解码、来源优先级、凭据变量拒绝、Mixed 两协议探测、自动失败回退均有断言 | 待验收：本机当前没有系统代理入口，未做真实静态隧道请求 |
| 3 · HTTP 兼容入口 | 默认启用时检查 Privoxy、HTTP 端口占用和配置目录；只在 SOCKS 验活后启动；HTTP CONNECT 单独验活；管理配置位于用户目录 | 通过：启动顺序、B+ 成功/缺 Privoxy 回退和命令安全策略由模拟与命令断言覆盖；prepare/launch/cleanup 脚本通过本机 `/bin/sh -n` | 待验收：未在 Linux 安装环境运行真实 Privoxy |
| 4 · UI、状态与文档 | 展示实际模式、代理地址、SSH、Mac 出站、SOCKS5/HTTP 验活、清理状态和错误；动态模式标明不需要本地端口与流量统计暂不可用 | App/XCTest 源码类型检查与完整链接通过；没有完整 Xcode，未运行 UI 截图或 XCTest | 待验收：真实端口冲突、断网恢复、睡眠/唤醒及 Codex/MCP 请求 |

## 本机验证记录

| 检查 | 命令或操作 | 预期 | 实测 |
|---|---|---|---|
| App 与测试源码 | `bash scripts/typecheck.sh` | App、测试代码无编译错误，Swift 6 预检通过 | 通过：0 errors；Swift 6 语言模式通过；保留既有并发/XCTest warning |
| 生产代码回归 | `bash scripts/smoke_test.sh` | 旧回归及 v2 动态、自动、Mixed、B+ 断言通过 | 通过：160 项，失败 0 项；包含 Codex HTTP 默认端口与 SOCKS5 独立端口断言 |
| App 二进制链接 | `swiftc -o build/ProxyBridge-v2-linkcheck ...` | 完整 App 源码可链接 | 通过：生成 arm64 Mach-O。保留原有被忽略的 `build/ProxyBridge.app`，未覆盖它 |
| 本机安装与候选 DMG | `bash scripts/install_app.sh`; `bash scripts/build_dmg.sh 1.3.0` | 签名、安装启动、universal DMG 架构与挂载内容校验 | 通过：1.3.0/build 5 已安装运行；本机生成的 universal DMG、签名、挂载 App 版本和 SHA-256 均通过 |
| Xcode/XCTest | `xcodebuild -version` | 可运行 Xcode build/test | 当前仅选择 `/Library/Developer/CommandLineTools`；xcodebuild 报需要完整 Xcode，故 XCTest 未运行 |
| Mac 当前代理源 | `scutil --proxy` 与代理环境变量名检查 | 确认系统代理/环境代理状态 | HTTP、HTTPS、SOCKS、PAC 均未配置；HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 未设置 |
| Mac 直接出站 | `/usr/bin/curl -q --noproxy '*' --connect-timeout 8 --max-time 20 --silent --show-error --output /dev/null --write-out '%{http_code}\n' https://api.openai.com/v1/models` | 验证当前网络可到达 API | HTTP 401。证明本次直接 HTTPS 请求到达 API；不能证明请求命中了 Clash 节点 |

## Linux 手工验收流程

下面所有命令都需要用户在相应机器上手动执行。应用本身不会修改 Linux 系统软件或 sshd 配置。

### A · 静态 HTTP/Mixed 转发

Mac 上指定已经真实验证通过的本地 HTTP/Mixed upstream 端口：

```bash
ssh -N -T -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -R 127.0.0.1:7890:127.0.0.1:<verified_local_http_port> <user>@<host>
```

Linux 上发起真实 HTTP CONNECT 请求：

```bash
curl -I --proxy http://127.0.0.1:7890 \
  --connect-timeout 8 --max-time 20 https://api.openai.com/v1/models
```

若静态 upstream 是 SOCKS5，Linux 入口仍是 SOCKS5，测试必须使用 `--socks5-hostname 127.0.0.1:7890`，不得将其设为 `HTTP_PROXY`。

### B · 反向动态 SOCKS5

Mac 上建立 OpenSSH 原生反向动态端口（`-R` 不带目标 host/port）：

```bash
ssh -N -T -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -R 127.0.0.1:17890 <user>@<host>
```

Linux 上验证 SOCKS5 和远端 DNS：

```bash
curl --socks5-hostname 127.0.0.1:17890 -I \
  --connect-timeout 8 --max-time 20 https://api.openai.com/v1/models
```

OpenSSH 将无目标地址的远端 `-R [bind_address:]port` 作为 SOCKS4/5 入口，默认远端绑定回环地址；本模式只承诺 TCP。[OpenBSD `ssh(1)` 手册](https://man.openbsd.org/ssh)

### B+ · Linux Codex HTTP 兼容

HTTP 入口默认启用。确认 SSH SOCKS5 请求已通过、Privoxy 可用后，App 会管理当前用户的 Privoxy 会话。HTTP 入口成功后 Linux 的 Codex 配置保持为：

```bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890
export NO_PROXY=localhost,127.0.0.1,::1
curl -I --proxy http://127.0.0.1:7890 \
  --connect-timeout 8 --max-time 20 https://api.openai.com/v1/models
```

SOCKS5 仍用 B 中的 SOCKS 命令单独验收。Privoxy 配置使用 `listen-address 127.0.0.1:<HTTP端口>` 和 `forward-socks5 / 127.0.0.1:<SOCKS端口> .`；官方手册说明 `forward-socks5` 会在 SOCKS 服务器端解析目标域名，并建议显式绑定 loopback。[Privoxy 配置手册](https://www.privoxy.org/user-manual/config.html)

如果 Linux 未安装 Privoxy，请按发行版政策由用户或管理员手动安装。Debian/Ubuntu 示例：`sudo apt install privoxy`。应用不会运行该命令。

## 待验收与限制

- 当前未用真实 Linux 主机验证 SSH 登录、远端 `-R` 监听、curl 端到端请求、HTTP CONNECT 或 Codex 模型/MCP 行为；这些项目不标记为通过。
- 真实端口冲突、sshd 禁止转发、Host Key 首次信任、网络中断/恢复和休眠唤醒需要实机验收。Host Key 检查保持开启。
- Mac API 返回 401 只验证当前网络路径到达目标；Clash 的活动连接、命中规则和出站节点仍需用户在 Clash UI 中确认。
- 动态 SOCKS5 只支持 TCP；动态模式没有准确 Relay 业务字节数据，因此 UI 显示流量统计暂不可用。
- B+ 需要远端已安装 Privoxy、可读的 Privoxy 配置目录以及可用的 `ss` 或 `netstat`。端口被占用时 App 让用户换端口，不会杀未知进程。
