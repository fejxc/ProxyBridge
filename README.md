# ProxyBridge

<p align="center">
  <img src="ProxyBridge/Resources/AppIcon.png" alt="ProxyBridge 应用图标" width="112">
</p>

**在 Mac 菜单栏一键把本地代理「带」到 Linux 服务器。**ProxyBridge 通过系统 SSH 建立反向隧道，让服务器上的开发工具（Codex、curl、pip 等）直接使用 Mac 上已验证的 HTTP、SOCKS5 或 Mixed 代理出海；也支持 OpenSSH 原生反向动态 SOCKS5，兼容 Clash Network Extension/TUN 没有本地代理端口的场景。需要 macOS 14+。

[下载 1.4.6 DMG](https://github.com/fejxc/ProxyBridge/releases/download/v1.4.6/ProxyBridge-1.4.6-universal.dmg) · [查看所有版本](https://github.com/fejxc/ProxyBridge/releases) · [查看构建与测试](https://github.com/fejxc/ProxyBridge/actions/workflows/ci.yml)

当前公开稳定版为 v1.4.6：三种连接模式、代理端点动态跟随、节点切换自动感知、应用内自动更新（流式下载 + 独立签名完整性校验 + 原子替换）、单实例与崩溃孤儿清扫、密码会话记忆、业务验证目标、日志落盘，界面支持中文/English。

## 安装

1. 下载 `ProxyBridge-1.4.6-universal.dmg`，适用于 Apple Silicon 和 Intel Mac。
2. 打开 DMG，将 `ProxyBridge.app` 拖到「应用程序」文件夹，再双击启动。
3. 如果 macOS 阻止打开，确认文件来自本仓库 Release 后，按 [Apple 官方说明](https://support.apple.com/102445)在「系统设置 → 隐私与安全性」中允许打开。

当前 App 为 ad-hoc 签名，未经 Apple 公证。每台 Mac 都需要自行配置本地代理和服务器；安装包不包含配置、密码或私钥。

## 功能

- 通过系统 `/usr/bin/ssh` 建立真实的 `ssh -R` 隧道；远端监听只绑定 `127.0.0.1`。
- 支持自动选择、传统静态转发、OpenSSH 原生反向动态 SOCKS5；自动模式先实测本地入口，无可用入口时回退动态 SOCKS5。
- 本地代理端点变化（端口漂移/代理客户端重启）动态感知：实测新端点后无缝切换转发目标，SSH 隧道不中断，并按新协议重验远端；本地验证失败会主动重扫。
- 首次连接在应用内核对主机指纹并信任（无需先开终端）；主机密钥变化不提供一键覆盖。支持从 ~/.ssh/config 导入服务器。
- 网络恢复（Wi-Fi 重连等）立即重建允许自动重连的隧道；自动模式回退动态 SOCKS5 后，本地代理恢复验证即自动切回静态转发。
- 启动检查更新（只读 GitHub 公开接口）；可选「连接期间防止空闲休眠」；界面支持中文/English。
- 动态模式使用 `ssh -R 127.0.0.1:<port>`，Mac 不需要本地 HTTP/SOCKS 监听；远端 SOCKS5 只支持 TCP。
- 默认在 Linux `127.0.0.1:7890` 提供 Codex HTTP 兼容入口，底层 SOCKS5 使用独立端口；需要已安装的 Privoxy。App 不自动安装软件、不使用 sudo、不修改系统配置或 sshd，用户可关闭该入口。
- 支持 HTTP、SOCKS5、Mixed 上游，密码、ssh-agent 和指定私钥。密码只经 PTY 应答；勾选「记住」时使用 macOS 钥匙串。
- 分别显示实际连接模式、SSH、Mac 出站、Linux SOCKS5、HTTP CONNECT 验证和错误原因。只有远端真实请求通过后才报告代理可用；Clash 出站节点单独标记为未确认。
- 非人为断开自动重连（默认开启）：网络故障按 1、2、4…秒退避重试，最多等待 60 秒；网络恢复、睡眠唤醒后立即重建；远端/本地端口冲突在 3 分钟窗口内自动重试。认证失败、主机指纹变化等需要人工处理的问题不盲目重试；用户手动断开是终态。
- 支持本地与远端周期检查、睡眠和唤醒恢复、系统登录项、启动时连接选定服务器及连接异常通知。
- 日志会脱敏，不记录密码、密钥内容或完整认证信息。

## 实时流量统计

静态转发模式内置本地 TCP Relay，链路为 `Linux → SSH → Mac Relay → 本地代理`。连接面板显示实际上传、下载速率及累计流量，展开可查看最近 60 秒曲线。上传指 Linux → Mac 本地代理，下载为反方向；只统计 Relay 成功转发的业务字节，包含代理健康检查，不包含 SSH 协议开销。断开保留本次累计量，重连开始新统计。动态 SOCKS5 模式不经过本地 Relay，面板会如实展示会话时长与无法统计业务字节的原因。

Relay 默认由系统分配空闲端口，仅监听 `127.0.0.1`。在服务器编辑窗口的「流量统计 Relay」中可指定固定端口（建议 17997）；端口占用时会停止连接并报告原因。实现与验收细节见[流量统计报告](docs/TRAFFIC-STATISTICS.md)。

## 连接模式与 Linux 端使用

| 模式 | 数据路径 | Linux 代理地址 |
|---|---|---|
| 自动（推荐） | 优先使用真实验证成功的本地 upstream；否则尝试 OpenSSH 反向动态 SOCKS5 | Codex HTTP `127.0.0.1:7890`（默认）；SOCKS5 `127.0.0.1:17890` |
| 传统端口转发 | Linux 回环 → SSH `-R remote:local` → Mac 的 HTTP/SOCKS/Mixed 上游 | 按上游协议使用 `remotePort` |
| 动态 SOCKS5 | Linux SOCKS5 → SSH `-R 127.0.0.1:port` → Mac 网络栈 | SOCKS5 `127.0.0.1:17890` |

动态 SOCKS5 的手工验证（先在 Mac 上启动隧道；替换 SSH 信息和端口）：

```bash
ssh -N -T -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -R 127.0.0.1:17890 <user>@<host>
```

然后在 Linux 服务器执行真实 SOCKS5 HTTPS 请求：

```bash
curl --socks5-hostname 127.0.0.1:17890 -I \
  --connect-timeout 8 --max-time 20 https://api.openai.com/v1/models
```

未认证 API 通常返回 HTTP 401；这表示请求到达 API，不代表账号已认证。HTTP 兼容入口默认启用，ProxyBridge 会单独验证 HTTP CONNECT。底层 SOCKS5 使用 `17890`，服务器 Codex 的 HTTP 配置继续使用 `7890`：

```bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890
export NO_PROXY=localhost,127.0.0.1,::1
curl -I --proxy http://127.0.0.1:7890 \
  --connect-timeout 8 --max-time 20 https://api.openai.com/v1/models
```

HTTP 入口默认开启，需要 Linux 已安装 `privoxy`。如果没有，ProxyBridge 会提示但不会安装；反向 SOCKS5 仍可独立使用。应用只创建当前 SSH 用户的 `~/.cache/proxybridge/` 会话配置，Privoxy 与远端 SSH 转发都只绑定 `127.0.0.1`。端口冲突时请在服务器配置页改端口，应用不会终止未知进程。HTTP 入口可在服务器配置中关闭。

Debian/Ubuntu 示例（需由有权限的用户自行执行；ProxyBridge 不会代为运行）：

```bash
sudo apt install privoxy
```

## 首次使用

1. 如果使用传统静态转发，在 Mac 上启动代理客户端并确认 HTTP、SOCKS5 或 Mixed 回环入口正常。Clash 使用 Network Extension/TUN 时，可直接选「动态 SOCKS5」。
2. 首次连接前，在终端 SSH 登录服务器并核对主机指纹，写入本机 `known_hosts`。例如：

   ```bash
   ssh -p <SSH端口> <用户名>@<服务器地址>
   ```

3. 启动 ProxyBridge，添加服务器并选择认证方式。密码会在面板中输入；勾选「记住密码」后才保存到本机钥匙串。
4. 点击「连接」。应用会显示最终实际模式，并从 Linux 服务器发起真实请求验证代理入口。动态 SOCKS5 会验证 Linux SOCKS 到 Mac 出站；这不能单独确认 Clash 具体命中的规则或节点，请在 Clash「活动」中核对。

「启动后连接」和登录启动是两个独立选项：前者选择哪些服务器在 App 启动后连接，后者控制 App 是否随 macOS 登录启动。登录项和通知均需按系统提示授权。

## 构建与开发

需要 Xcode 的 Mac：

```bash
open ProxyBridge.xcodeproj
bash scripts/xcode_test.sh
```

只有 Command Line Tools 时：

```bash
bash scripts/typecheck.sh       # App 与测试代码类型检查
bash scripts/smoke_test.sh      # 当前源码可执行回归检查
bash scripts/relay_test.sh      # 真实本地 TCP 转发、精度与清理验证
bash scripts/install_app.sh     # 构建并安装到 /Applications
bash scripts/build_dmg.sh 1.4.6 # 构建通用 DMG 和 SHA-256 文件
```

推送 `vX.Y.Z` 格式的版本标签会触发 GitHub Actions：分别在 Apple Silicon 和 Intel runner 上检查，再构建和验证通用 DMG，最后发布 GitHub Release。详见[发布流程](docs/RELEASE.md)。

## 安全与支持范围

SSH 强制 `StrictHostKeyChecking=yes`，远端只监听服务器本机回环地址。认证密码不会进入 SSH 参数、环境变量或应用日志。请勿通过更改 SSH 主机密钥检查或开放公网监听来排障。

应用支持 macOS 14 及以上版本。动态 SOCKS5 通过 SSH 客户端的 Mac 网络栈发起 TCP 出站，不承诺 UDP、透明系统代理或 Clash 节点路由。现有 `StrictHostKeyChecking=yes` 保留；远端代理不对 LAN 或公网开放。真实 Linux/Clash 端到端验收流程与结果见[升级验收报告](docs/PROXYBRIDGE_V2_ACCEPTANCE.md)、[已知限制](KNOWN_LIMITATIONS.md)和[阶段 D 报告](docs/PHASE_D_REPORT.md)。

## 许可证

本项目基于 [MIT License](LICENSE) 开源。使用、修改与分发请遵循许可证条款；软件按「现状」提供，不附带任何担保。
