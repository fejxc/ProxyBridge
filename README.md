# ProxyBridge

<p align="center">
  <img src="ProxyBridge/Resources/AppIcon.png" alt="ProxyBridge 应用图标" width="112">
</p>

**macOS 14+ 菜单栏 SSH 反向代理工具。**将 Mac 上的 HTTP 或 SOCKS5 本地代理，通过 SSH 安全转发到 Linux 服务器的回环地址。

[下载 1.1.0 DMG](https://github.com/fejxc/ProxyBridge/releases/download/v1.1.0/ProxyBridge-1.1.0-universal.dmg) · [查看所有版本](https://github.com/fejxc/ProxyBridge/releases) · [查看构建与测试](https://github.com/fejxc/ProxyBridge/actions/workflows/ci.yml)

## 安装

1. 下载 `ProxyBridge-1.1.0-universal.dmg`，适用于 Apple Silicon 和 Intel Mac。
2. 打开 DMG，将 `ProxyBridge.app` 拖到「应用程序」文件夹，再双击启动。
3. 如果 macOS 阻止打开，确认文件来自本仓库 Release 后，按 [Apple 官方说明](https://support.apple.com/102445)在「系统设置 → 隐私与安全性」中允许打开。

当前 App 为 ad-hoc 签名，未经 Apple 公证。每台 Mac 都需要自行配置本地代理和服务器；安装包不包含配置、密码或私钥。

## 功能

- 通过系统 `/usr/bin/ssh` 建立真实的 `ssh -R` 隧道；远端监听只绑定 `127.0.0.1`。
- 支持 HTTP 和 SOCKS5 代理、密码、ssh-agent 和指定私钥。密码只经 PTY 应答；勾选「记住」时使用 macOS 钥匙串。
- 分别验证本地代理、SSH 隧道和远端代理。远端通过 curl 验证成功后才显示「已连接」。
- 按网络故障退避重连；认证失败和主机指纹错误会停止重试。用户手动断开是终态。
- 支持本地与远端周期检查、睡眠和唤醒恢复、系统登录项、启动时连接选定服务器及连接异常通知。
- 日志会脱敏，不记录密码、密钥内容或完整认证信息。

## 首次使用

1. 在这台 Mac 上启动本地代理客户端，确认 HTTP 或 SOCKS5 回环代理正常运行。
2. 首次连接前，在终端 SSH 登录服务器并核对主机指纹，写入本机 `known_hosts`。例如：

   ```bash
   ssh -p <SSH端口> <用户名>@<服务器地址>
   ```

3. 启动 ProxyBridge，添加服务器并选择认证方式。密码会在面板中输入；勾选「记住密码」后才保存到本机钥匙串。
4. 点击「连接」。三层验证通过后状态会显示「已连接」；随后可以在服务器本机通过远端端口使用代理。

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
bash scripts/smoke_test.sh      # 143 项可执行回归检查
bash scripts/install_app.sh     # 构建并安装到 /Applications
bash scripts/build_dmg.sh 1.1.0 # 构建通用 DMG 和 SHA-256 文件
```

推送 `vX.Y.Z` 格式的版本标签会触发 GitHub Actions：分别在 Apple Silicon 和 Intel runner 上检查，再构建和验证通用 DMG，最后发布 GitHub Release。详见[发布流程](docs/RELEASE.md)。

## 安全与支持范围

SSH 强制 `StrictHostKeyChecking=yes`，远端只监听服务器本机回环地址。认证密码不会进入 SSH 参数、环境变量或应用日志。请勿通过更改 SSH 主机密钥检查或开放公网监听来排障。

应用支持 macOS 14 及以上版本。已知限制、系统授权要求及未验证项目见[已知限制](KNOWN_LIMITATIONS.md)和[阶段 D 验收报告](docs/PHASE_D_REPORT.md)。

## 许可证

当前仓库尚未添加 `LICENSE` 文件。
