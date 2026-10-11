# KNOWN_LIMITATIONS · 已知限制（阶段 C）

> 原则：没实现的功能不标注「可用」；演示数据永远带「演示」标记。

## 功能边界（按计划属于后续阶段）

1. **SSH 隧道已真实实现**（阶段 C）：`/usr/bin/ssh` 参数数组直启（StrictHostKeyChecking=yes 强制、BatchMode、远端绑定固定 127.0.0.1）。边界：
   - 密码认证已支持（安全实现）：连接时在面板中输入，密码仅本次会话在内存中经系统 PTY 交给 ssh（不经命令行参数/环境变量/磁盘/日志）；错密码因 `NumberOfPasswordPrompts=1` 立即失败；远端验证复用同一次会话密码。App 不提供「记住密码」（如需可考虑 Keychain，属后续阶段）；
   - 首次连接未知主机：StrictHostKeyChecking=yes 会拒绝并给出「先在终端手动 ssh 核对指纹」的指引（App 不代收指纹）；
   - 自动重连退避（PRD F05）属阶段 D：当前意外断线显示分类后的 error 终态，等待用户手动重连；
   - GUI 启动时若无 SSH_AUTH_SOCK（取决于系统配置），agent 认证会失败并给出改用 identityFile 的提示；
   - 远端探测复用 profile 的 host/port/identity，一次性 ssh 执行受控脚本（`command -v curl` + curl 经 127.0.0.1:远端端口 实测），缺 curl → 未验证（绝不假绿）。
2. **登录启动未生效**（阶段 D 实现）：通用设置里的开关只保存意图（`launchAtLoginRequested`），未调用 `SMAppService`，开关为禁用态并附说明。
3. **通知未实现**：`showNotifications` 仅持久化设置项。
4. **周期性远端健康检查未实现**：远端 curl 端到端验证在「连接建立 / 手动检查连接」时执行（真实探测）；按固定间隔的周期远端探测与本地轻量检查属阶段 D（设置里的间隔项已持久化但尚未接线）。
5. **本地代理检测已真实**（阶段 B）：读取 `SCDynamicStore` 并经 `curl` 实测。边界：
   - 验证目标固定 `https://www.example.com/`（代码白名单；仅判定代理可用性，不上传数据）；
   - 非 loopback 候选只显示、不探测、不转发（需手动指定评估）；
   - PAC / 仅 TUN / 需认证（407）代理如实标注限制，不猜测端口；
   - 系统代理变化经 800ms 防抖自动重扫；SCDynamicStore 订阅失败时面板会明确提示「通知不可用，请手动重新检测」。

## 明确的不支持（MVP 范围外）

- 远程绑定只允许 `127.0.0.1`——不提供、也不接受 `0.0.0.0`/公网监听配置（模型层常量 + 校验）。
- IPv6 字面量 SSH 主机（`::1` 等）：校验层拒绝并提示改用主机名；`::1` 作为**本地代理地址**是允许的。
- 非 loopback 的本地代理主机（如局域网代理）：UI 明确提示 MVP 不转发。
- 不「记住」SSH 密码：密码模式每次连接都需在面板输入（安全取舍——不落盘是红线；如需免输可改用密钥并加载进 ssh-agent）。
- 跨用户 `~otheruser` 形式的密钥路径不展开（仅 `~` 与 `~/...`）。
- 多语言：当前简体中文硬编码于视图常量（文案已集中，`Localizable.strings` 基础设施就位，键值化在后续阶段做）。

## 技术性已知限制

- **测试执行的双轨制**：XCTest 断言需要完整 Xcode 才能运行；本仓库在无 Xcode 环境用 `scripts/smoke_test.sh`（93 项断言，已全部通过，含生产 SSHTunnelCoordinator 状态机序列与真实 /usr/bin/ssh 进程证据）+ `scripts/typecheck.sh`（XCTest shim 编译级检查）作为证据。XCTest 在你机器上的实际通过状态以 `scripts/xcode_test.sh` 输出为准。
- **菜单栏图标颜色**：图标按状态切换符号形态并带 VoiceOver 文本；macOS 菜单栏模板渲染下单色为主，五色语义完整呈现在面板内的彩色状态标签（颜色+文字成对）。
- **时序测试的裕量**：`MockTunnelServiceTests` 使用 20ms 轮询 + 3s 超时，在极端负载的 CI 机器上理论上有 flaky 可能（失败重跑即可判断）。
- **MenuBarExtra 窗口宽度**：面板固定 368pt（原型 360–380pt 区间内），超小屏/超大字号下未做自适应验证（无障碍人工验收待做，见报告「未验证」节）。
- **截图证据的局限**：`docs/evidence/launch_screenshot_full.png` 为全屏截图（应用已启动、菜单栏图标存在性由进程与截图文件佐证），未做像素级 UI 校验；面板需人工点击展开。
- **未做 App Sandbox/公证**：按技术设计 §0，分发前需补签名与公证验证；当前 `CODE_SIGNING_ALLOWED = NO` 便于本地开发。
- **@Observable + LogStore**：日志视图观察依赖 Observation 宏传播；若未来把 LogStore 移出主线程需重新设计通知。

## 阶段性安全说明

- 用户断开不会自动重连（Mock 与生产 SSHTunnelCoordinator 双层测试/冒烟钉死：断开后零事件、进程只杀自己的句柄）。
- 连接前的配置校验失败会阻止发起连接（error 状态 + 日志），不会带病连接。
- 「复制远端代理命令」在远端未验证时自动附加提醒注释——未验证 ≠ 可用。
- 日志入库前剥离 ANSI 控制字符并遮挡密钥路径与凭据；复制时可再遮挡 IP/用户@主机（默认开启）。
