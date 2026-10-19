# DMG 构建与发布

工作流：`.github/workflows/release.yml`，名称 **Build and release DMG**。

## 已发布版本

- [v1.0.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.0.0)：初始版本。
- [v1.1.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.1.0)：加入阶段 D 功能，提供 universal DMG 和 SHA-256 校验文件。
- [v1.2.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.2.0)：加入本地 TCP Relay 实时流量统计。
- [v1.3.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.3.0)：v2 连接模式（自动/静态/反向动态 SOCKS5、Privoxy HTTP 入口）与本地代理端点动态跟随。
- [v1.4.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.4.0)：首次连接指纹引导、更新检查、网络快速恢复、自动回升、防休眠、远端依赖指引、ssh config 导入与中英界面。
- [v1.4.1](https://github.com/fejxc/ProxyBridge/releases/tag/v1.4.1)：修复活跃连接时退出无响应；更新检查可见化（重试、横幅、通知、内联反馈）。

后续每个 Release 都从不可变的版本标签构建。

Apple Silicon 和 Intel runner 分别运行类型检查及原生冒烟测试，两者通过后合并两个架构的可执行文件，生成通用 DMG；验证签名、挂载后的 App 版本、架构和 Applications 链接。最后上传 DMG 和 SHA-256 文件到对应 GitHub Release。创建新 Release 时先保持 draft，附件上传完成后才公开。

当前稳定版为 `ProxyBridge-1.4.1-universal.dmg`，拖入 Applications 即可安装，不需要 Xcode、Swift 或命令行开发工具。首次使用仍需配置服务器（支持从 `~/.ssh/config` 导入）；主机指纹可在应用内核对。

## 后续版本

1. 更新 Xcode 工程中的 MARKETING_VERSION、CFBundleShortVersionString 和构建号，并更新 README 与 CHANGELOG。
2. 推送 master，确认 CI 和两架构检查通过。
3. 获准发布后创建对应版本标签，例如 `git tag -a v1.3.0 -m 'ProxyBridge 1.3.0'`，然后 `git push origin v1.3.0`。
4. 标签推送自动触发工作流。版本不一致、任一架构测试失败、DMG 验证失败时不会公开新的下载文件。

工作流仅发布 `vX.Y.Z` 格式的现有标签。也可以手动重新运行同一版本；重新生成的附件会覆盖该 Release 中的同名附件。

## 本地打包

```bash
bash scripts/build_dmg.sh 1.4.1
```

候选产物：`build/dist/ProxyBridge-1.4.1-universal.dmg` 及同名 `.sha256` 文件。版本从 Xcode 工程读取，构建工具支持交叉编译；最低系统版本为 macOS 14。

## 签名与权限

当前为 ad-hoc 签名，不具备 Developer ID 和 Apple 公证。macOS 首次运行可能提示开发者无法验证；确认来自官方仓库后，可按 [Apple 官方说明](https://support.apple.com/102445) 在「系统设置 → 隐私与安全性」中允许打开。工作流不关闭 Gatekeeper，也不清除下载隔离属性。

流程不需要用户配置任何仓库 secret，发布作业使用 GitHub 自动提供的 GITHUB_TOKEN，只有发布作业申请 contents:write。使用 GitHub 托管的 macos-15（arm64）和 macos-15-intel runner；详见 [GitHub 官方 runner 列表](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。没有将开发机的配置、钥匙串、密码、私钥或诊断目录打入安装包。

如需完全消除未公证提示，后续需配置 Apple Developer ID Application 证书及公证凭据；本次没有伪称已完成公证。
