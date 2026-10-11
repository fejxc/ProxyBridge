# 阶段 C 交付报告 · SSH 转发

> 日期：2026-10-11 ｜ 对应 05-IMPLEMENTATION-PLAN 的 M3
> 环境：macOS 15.1.1（arm64）· Swift 6.0.2（Command Line Tools，无完整 Xcode）

## 一、状态总览

| 项 | 状态 | 证据 |
|---|---|---|
| SSH 参数纯函数构建（U07/U08） | ✅ 通过 | 逐字断言：`-N -T`、BatchMode、`StrictHostKeyChecking=yes`、`ExitOnForwardFailure=yes`、`-R 127.0.0.1:<远端>:127.0.0.1:<本地>`；含空格密钥路径单参数逐字保真 |
| stderr/退出码分类（U09/U10） | ✅ 通过 | Permission denied/Host key → authRequired；remote port forwarding failed/超时/拒连/不可达 → error；全模式单测 |
| 单 profile 单进程（U14） | ✅ 通过 | 冒烟 S34 + XCTest：双连击只创建 1 个句柄 |
| 宽限期 + 转发失败分类（I01） | ✅ 通过 | Fake 进程 0.5s 退出 + stderr 注入 → authRequired/error（XCTest + 冒烟 S34c） |
| 用户断开零 ghost 事件（U13/I03） | ✅ 通过 | 双层钉死：XCTest（静默窗口 helper）+ 冒烟 S34b（真实协调器） |
| 启动失败无泄漏（I04） | ✅ 通过 | start() 抛错 → error + isActive=false |
| 前置检查（ssh 二进制/密钥文件） | ✅ 通过 | 密钥不存在 → error 且不启动进程（XCTest） |
| 远端端到端验证（§7） | ✅ 通过 | 受控脚本全等断言（无自由文本）；缺 curl → degraded+nil（S34d）；与隧道命令 `-i` 一致（评审修复后） |
| App 退出清理子进程（F05） | ✅ 通过 | `willTerminate` → terminateAllSessions（SIGTERM→2s SIGKILL 升级，只杀自己句柄） |
| 真实 ssh 进程链路 | ✅ 通过 | 冒烟 S33：生产 factory 启动真实 `/usr/bin/ssh` → `127.0.0.1:1` → exit 255 "Connection refused" → 分类 error |
| E01–E10（真实 Mac+Linux 服务器） | ⛔ 未验证 | **需要用户配置真实服务器**（host/密钥/known_hosts 信任）。App 已就绪：添加 profile → 连接即可观察完整链路。未做，不虚称 |
| `xcodebuild build` / XCTest 运行 | ⛔ 阻塞 | 本机无完整 Xcode；冒烟 93 项 + typecheck 作为替代证据 |
| 自动重连退避 / 睡眠唤醒 / 周期健康检查 | ⏳ 阶段 D | 按计划未实现；断线显示分类终态等待用户操作 |
| 登录启动（SMAppService） | ⏳ 阶段 D | 开关禁用态并注明 |

## 二、新增交付

**源码（5 文件）**
- `Services/SSHCommandBuilder.swift` — 隧道参数 + RemoteProbeCommand（受控脚本全等断言）
- `Services/SSHErrorClassifier.swift` — 8 类 stderr 模式 → authRequired/error 终态映射
- `Services/SSHProcessLauncher.swift` — 句柄协议 + Foundation 工厂（最小环境、stdin EOF、stdout/stderr 环形收集、**terminationHandler 同步排空管道末段**、SIGTERM/SIGKILL 升级）
- `Services/RemoteProbeRunner.swift` — SSHRemoteProbe（一次性 ssh 远端验证、取消→终止进程、NO_CURL 标记→unknown）
- `Services/SSHTunnelCoordinator.swift` — 状态机：checking(本地验证)→preflight→connecting(宽限期)→远端验证→connected/degraded/authRequired/error；每个 await 后收口守卫；健康检查带冷却/并发锁/终态保护

**测试**：SSHCommandBuilderTests、SSHErrorClassifierTests、SSHTunnelCoordinatorTests（16 用例：时序/I01–I04/U13/U14/重连/取消路径/环境白名单/健康检查竞态）。冒烟 93 项（新增 S31–S34）。

## 三、对抗评审（51-agent 工作流）

3 维度（Process/密钥安全、状态机并发、测试有效性）→ 每发现 2 名独立怀疑者（部分因 API 限流中断，已产出部分双票）。**24 项发现 → 14 确认 → 全部修复**。亮点（验证 agent 做了真实编译运行实验）：

| 严重度 | 发现 | 修复 |
|---|---|---|
| high | `runHealthRefresh` 所有守卫都在 await 之前：断开后 ghost 快照 + 断开后新起探测 ssh（违反 U13） | 每个 await 后收口（userStopped/cancelled/handle 存活/相位） |
| high | 健康检查与进程死亡竞争：error 终态可被翻回 connected（ssh 已死却假绿且永久卡住） | 相位重算前复查 handle 存活；新增竞态回归测试 |
| high | **两个 XCTest 首跑必挂**（agent 实际编译运行证实：args.count 断言 6 vs 实际 10） | 按实际行为重写为逐字全等断言 |
| medium | SSHRemoteProbe 吞 CancellationError：取消后 20s 忙等空转 + 孤儿 ssh 进程 | withTaskCancellationHandler + terminate + 循环取消检查 |
| medium | RemoteProbeCommand 缺 `-i`：identityFile 模式远端探测必然认证失败 → 误入 authRequired 终态 | 与隧道命令同条件复用 `-i` + 一致性测试 |
| medium | terminationHandler 先清 handler 再回调：末段 stderr（恰是分类特征）实验性丢失 ~59% | terminationHandler 同步排空管道剩余数据后再回调 |
| medium | 注入审计白名单过宽（引号/管道/分号全放行），形同虚设 | 改为脚本**全等断言**（任何成分变化必须显式更新） |
| medium | 协调器状态机零已执行证据（XCTest 未跑、冒烟未覆盖） | 冒烟 S34a–d：生产协调器跑真实序列（connected/断开零事件/authRequired/缺 curl） |
| medium×4 | 环境变量零断言、checking 阶段断开未测、断开后重连未测、健康检查只走冷却分支 | 全部补齐（Gated 替身、环境键白名单断言、cooldown=0 复核、error no-op 测试） |
| low×2 | 末段 stderr 丢失归并项、固定 sleep 证明否定命题 | 排空修复 + awaitQuiet 静默窗口 helper |

## 四、验证命令与真实输出

```console
$ bash scripts/typecheck.sh      # App 0 error · 测试代码 0 error · Swift 6 语言模式通过
$ bash scripts/smoke_test.sh
PASS  S31a  ssh 参数数组逐字匹配（StrictHostKeyChecking=yes）
PASS  S31b  含空格密钥路径逐字保真
PASS  S32  分类：认证→authRequired / 转发失败→error / 拒连→error
PASS  S33  真实 /usr/bin/ssh 启动并按 stderr 分类（拒连→error）
      [exit=255 stderr=ssh: connect to host 127.0.0.1 port 1: Connection refused]
PASS  S34a  协调器完整序列 checking→connecting→connected
PASS  S34b  协调器：用户断开 → idle 且零 ghost 事件
PASS  S34c  协调器：认证失败剧本 → authRequired（I01/U09）
PASS  S34d  协调器：远端缺 curl → degraded + 未验证（绝不 connected）
----------------------------------------  通过 93 项，失败 0 项  RESULT: PASS
```

## 五、诚实性声明

1. **未连真实服务器**：本机验证覆盖到「真实 /usr/bin/ssh 启动 → 连接拒绝 → 分类」为止；隧道建立、远端转发、端到端 curl 的**最后一公里需要你配置真实服务器**（E01–E09）。App 已就绪：设置中添加服务器（先在终端 ssh 一次信任主机指纹）→ 点连接即可完整体验。未做即标注未做。
2. `connected` 的语义保持严格：本地代理 curl 验证 + ssh 进程存活（宽限期+ExitOnForwardFailure）+ 远端 curl 端到端验证三者同时成立；任一缺失如实降级。
3. 自动重连/睡眠唤醒/周期检查/SMAppService 为阶段 D 范围，当前 UI 与文档均未声称可用。
4. 安全红线逐条：StrictHostKeyChecking=yes（写死+断言）、remote bind 127.0.0.1（常量+断言）、无 shell 拼接（参数数组+脚本全等断言）、无密钥/密码存储、日志脱敏沿用、断开不重连（双层钉死）、只杀自己句柄（无 pkill）。

## 六、如何做实机 E2E（当你有服务器时）

1. 终端执行 `ssh -p <port> <user>@<host>` 一次：核对指纹输入 yes、确认密钥认证可用（写入 known_hosts）。
2. App 设置 → 添加服务器（同 host/port/user；identityFile 模式填路径）→ 保存。
3. 菜单栏 → 连接：预期约 3–10 秒内变绿（远端 curl 验证成功）或按情况显示 degraded/authRequired/error + 具体原因。
4. 服务器上执行 `curl --noproxy '' --proxy http://127.0.0.1:7890 -I https://www.example.com` 验证转发（端口按你的配置）。
5. E04：关掉本地代理 → 面板应转橙「代理异常」而非保持绿色；E07：点断开 → 服务器上确认 sshd 连接消失、无自动重连。
