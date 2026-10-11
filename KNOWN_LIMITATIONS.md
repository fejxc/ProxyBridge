# KNOWN_LIMITATIONS · 已知限制（阶段 B）

> 原则：没实现的功能不标注「可用」；演示数据永远带「演示」标记。

## 功能边界（按计划属于后续阶段）

1. **SSH 隧道是 Mock**（阶段 C 实现）：`MockTunnelService` 只驱动状态机剧本（connected/degraded/authRequired/remoteBindConflict），不启动进程、不连任何服务器。面板横幅明示「SSH 隧道仍为演示（阶段 C 接入）」。
2. **登录启动未生效**（阶段 D 实现）：通用设置里的开关只保存意图（`launchAtLoginRequested`），未调用 `SMAppService`，开关为禁用态并附说明。
3. **通知未实现**：`showNotifications` 仅持久化设置项。
4. **远端健康检查无真实探测**：面板「远端代理」一层来自状态机快照，不是实测（阶段 C 的远端 curl 探测）。
5. **本地代理检测已真实**（阶段 B）：读取 `SCDynamicStore` 并经 `curl` 实测。边界：
   - 验证目标固定 `https://www.example.com/`（代码白名单；仅判定代理可用性，不上传数据）；
   - 非 loopback 候选只显示、不探测、不转发（需手动指定评估）；
   - PAC / 仅 TUN / 需认证（407）代理如实标注限制，不猜测端口；
   - 系统代理变化经 800ms 防抖自动重扫；SCDynamicStore 订阅失败时面板会明确提示「通知不可用，请手动重新检测」。

## 明确的不支持（MVP 范围外）

- 远程绑定只允许 `127.0.0.1`——不提供、也不接受 `0.0.0.0`/公网监听配置（模型层常量 + 校验）。
- IPv6 字面量 SSH 主机（`::1` 等）：校验层拒绝并提示改用主机名；`::1` 作为**本地代理地址**是允许的。
- 非 loopback 的本地代理主机（如局域网代理）：UI 明确提示 MVP 不转发。
- SSH 密码认证：`AuthenticationMode` 只有 agent / identityFile；不存密码、不做 sshpass。
- 跨用户 `~otheruser` 形式的密钥路径不展开（仅 `~` 与 `~/...`）。
- 多语言：当前简体中文硬编码于视图常量（文案已集中，`Localizable.strings` 基础设施就位，键值化在后续阶段做）。

## 技术性已知限制

- **测试执行的双轨制**：XCTest 断言需要完整 Xcode 才能运行；本仓库在无 Xcode 环境用 `scripts/smoke_test.sh`（80 项等价断言，已全部通过）+ `scripts/typecheck.sh`（XCTest shim 编译级检查）作为证据。XCTest 在你机器上的实际通过状态以 `scripts/xcode_test.sh` 输出为准。
- **菜单栏图标颜色**：图标按状态切换符号形态并带 VoiceOver 文本；macOS 菜单栏模板渲染下单色为主，五色语义完整呈现在面板内的彩色状态标签（颜色+文字成对）。
- **时序测试的裕量**：`MockTunnelServiceTests` 使用 20ms 轮询 + 3s 超时，在极端负载的 CI 机器上理论上有 flaky 可能（失败重跑即可判断）。
- **MenuBarExtra 窗口宽度**：面板固定 368pt（原型 360–380pt 区间内），超小屏/超大字号下未做自适应验证（无障碍人工验收待做，见报告「未验证」节）。
- **截图证据的局限**：`docs/evidence/launch_screenshot_full.png` 为全屏截图（应用已启动、菜单栏图标存在性由进程与截图文件佐证），未做像素级 UI 校验；面板需人工点击展开。
- **未做 App Sandbox/公证**：按技术设计 §0，分发前需补签名与公证验证；当前 `CODE_SIGNING_ALLOWED = NO` 便于本地开发。
- **@Observable + LogStore**：日志视图观察依赖 Observation 宏传播；若未来把 LogStore 移出主线程需重新设计通知。

## 阶段性安全说明

- 用户断开不会自动重连（Mock 层测试钉死：断开后零事件）。
- 连接前的配置校验失败会阻止发起连接（error 状态 + 日志），不会带病连接。
- 「复制远端代理命令」在远端未验证时自动附加提醒注释——未验证 ≠ 可用。
- 日志入库前剥离 ANSI 控制字符并遮挡密钥路径与凭据；复制时可再遮挡 IP/用户@主机（默认开启）。
