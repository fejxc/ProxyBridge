# DMG 构建与发布

工作流：`.github/workflows/release.yml`，名称 **Build and release DMG**。

## 已发布版本

- [v1.0.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.0.0)：初始版本。
- [v1.1.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.1.0)：加入阶段 D 功能，提供 universal DMG 和 SHA-256 校验文件。
- [v1.2.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.2.0)：加入本地 TCP Relay 实时流量统计。
- [v1.3.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.3.0)：v2 连接模式（自动/静态/反向动态 SOCKS5、Privoxy HTTP 入口）与本地代理端点动态跟随。
- [v1.4.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.4.0)：首次连接指纹引导、更新检查、网络快速恢复、自动回升、防休眠、远端依赖指引、ssh config 导入与中英界面。
- [v1.4.1](https://github.com/fejxc/ProxyBridge/releases/tag/v1.4.1)：修复活跃连接时退出无响应；更新检查可见化（重试、横幅、通知、内联反馈）。
- [v1.4.2](https://github.com/fejxc/ProxyBridge/releases/tag/v1.4.2)：远端转发端口冲突 3 分钟窗口内自动重试（等旧 sshd 释放），错误文案给出 sshd 排查项。
- [v1.4.3](https://github.com/fejxc/ProxyBridge/releases/tag/v1.4.3)：端口冲突经 SSH 只读诊断占用者（零依赖 /proc 解析），确认后一键清理自家残留（僵尸 sshd / 孤儿 Privoxy）并自动重连。
- [v1.4.4](https://github.com/fejxc/ProxyBridge/releases/tag/v1.4.4)：节点切换自动感知（出口 IP 指纹 + 立即重验）、本地 Relay 冲突限时重试、日志落盘、README 定稿与 MIT 协议。
- [v1.4.5](https://github.com/fejxc/ProxyBridge/releases/tag/v1.4.5)：单实例保护、崩溃孤儿 ssh 清扫、密码会话内记忆（自动重连免重复询问）、应用内自动更新（下载 · SHA-256 校验 · 原子替换 · 重启）。
- [v1.4.6](https://github.com/fejxc/ProxyBridge/releases/tag/v1.4.6)：更新链路加固（流式下载、codesign 完整性与身份核对、同卷原子替换）；发布流程钉死与被测代码一致（CI 绿门槛、标签内构建、资产不可覆盖）；真实验收清单成为发布门槛；「已连接」明确标注探测目标并支持每服务器业务验证目标。
- [v1.5.2](https://github.com/fejxc/ProxyBridge/releases/tag/v1.5.2)：应用内更新 DMG 挂载点修复与步骤日志；增加 sshd 原始转发错误透传。
- v1.5.3：修复 HTTP 入口与静态转发使用相同端口导致的 SSH 监听失败；新建配置使用独立静态端口；补齐全 TCP 状态的远端残留诊断与清理复查，修正 1.5.2 发布说明与实际诊断扫描不一致的问题。
- [v1.6.1](https://github.com/fejxc/ProxyBridge/releases/tag/v1.6.1)：全库三轮审查批改——远端探测 URL 引号（带查询串业务目标修复）、密码模式三处（超时泄漏 Relay、凭据销毁时机、「记住」后置落盘）、自愈状态机（孤儿任务/冲突窗口/休眠重置）、HTTP 入口数据面（CONNECT 余量字节/半关闭/双泵）、应用内更新主线程卸载与中断恢复、TOFU 信任对齐 ssh 生效文件、视图层修复与三处状态对象重构。
- [v1.6.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.6.0)：Clash TUN 无端口稳定性专项——修复 HTTP 入口拒绝路径连接泄漏，增加 SSH 存活时连续业务失败的受控自愈、在线路径指纹与无端口出口观测、自愈轨迹 UI。
- [v1.5.1](https://github.com/fejxc/ProxyBridge/releases/tag/v1.5.1)：修复应用内更新必然失败的问题（hdiutil 挂载点解析自 1.4.5 起即错），安装器增加步骤级日志。
- [v1.5.0](https://github.com/fejxc/ProxyBridge/releases/tag/v1.5.0)：架构改造版——AppViewModel 拆分、密码认证迁 SSH_ASKPASS（密码输入前移，不再有挂起等待）、去除 Privoxy 远端依赖（HTTP 兼容入口 App 内实现）、新增集成测试层（真实 ssh 真隧道，并借此修复业务验证目标自 1.4.6 起未生效的问题）、构建清单一致性守护。
- [v1.4.7](https://github.com/fejxc/ProxyBridge/releases/tag/v1.4.7)：修复动态 SOCKS5 首验「监听就绪」竞态（Network Extension 客户端下首次连接不再误报部分可用）；混合端口协议翻转不再触发切换；稳定期成功检查日志节流。

后续每个 Release 都从不可变的版本标签构建。

Apple Silicon 和 Intel runner 分别运行类型检查及原生冒烟测试，两者通过后合并两个架构的可执行文件，生成通用 DMG；验证签名、挂载后的 App 版本、架构和 Applications 链接。最后上传 DMG 和 SHA-256 文件到对应 GitHub Release。创建新 Release 时先保持 draft，附件上传完成后才公开。

当前稳定版为 `ProxyBridge-1.6.1-universal.dmg`，拖入 Applications 即可安装，不需要 Xcode、Swift 或命令行开发工具。首次使用仍需配置服务器（支持从 `~/.ssh/config` 导入）；主机指纹可在应用内核对。自 1.4.5 起后续版本可在应用内一键更新（下载官方资产并经 SHA-256 与签名完整性双校验后自动替换重启）。

## 后续版本

1. 更新 Xcode 工程中的 MARKETING_VERSION、CFBundleShortVersionString 和构建号，并更新 README 与 CHANGELOG。
2. 推送 master，确认 CI 和两架构检查通过。
3. **完成[真实验收清单](ACCEPTANCE-CHECKLIST.md)并在其结果表中记录**——未验收的版本不发布（发布工作流同时要求标签指向的提交 CI 全绿，否则拒绝构建）。
4. 获准发布后创建对应版本标签，例如 `git tag -a v1.4.6 -m 'ProxyBridge 1.4.6'`，然后 `git push origin v1.4.6`。
5. 标签推送自动触发工作流。以下任一情况不会公开新的下载文件：版本不一致、标签提交的 CI 非全绿、任一架构测试失败、DMG 验证失败。

工作流仅发布 `vX.Y.Z` 格式的现有标签；构建与验证全部使用**标签内的脚本与源码**（不从当前分支复制）。已公开版本的附件不可被后续运行覆盖（上传不带 `--clobber`）。

Release 页的**版本更新说明自动取自标签内 CHANGELOG.md 的对应版本段落**（提取失败时仅发通用安装说明并标注 warning）；因此每个版本的 CHANGELOG 条目应在打 tag 前写好——它就是用户在 Release 页看到的功能变更列表。

## 本地打包

```bash
bash scripts/build_dmg.sh 1.6.1
```

候选产物：`build/dist/ProxyBridge-1.6.1-universal.dmg` 及同名 `.sha256` 文件。版本从 Xcode 工程读取，构建工具支持交叉编译；最低系统版本为 macOS 14。

## 签名与权限

当前为 ad-hoc 签名，不具备 Developer ID 和 Apple 公证。macOS 首次运行可能提示开发者无法验证；确认来自官方仓库后，可按 [Apple 官方说明](https://support.apple.com/102445) 在「系统设置 → 隐私与安全性」中允许打开。工作流不关闭 Gatekeeper，也不清除下载隔离属性。

流程不需要用户配置任何仓库 secret，发布作业使用 GitHub 自动提供的 GITHUB_TOKEN，只有发布作业申请 contents:write。使用 GitHub 托管的 macos-15（arm64）和 macos-15-intel runner；详见 [GitHub 官方 runner 列表](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。没有将开发机的配置、钥匙串、密码、私钥或诊断目录打入安装包。

如需完全消除未公证提示，后续需配置 Apple Developer ID Application 证书及公证凭据；本次没有伪称已完成公证。
