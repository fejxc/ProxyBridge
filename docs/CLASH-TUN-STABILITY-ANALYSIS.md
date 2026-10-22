# Clash TUN 无本地代理端口：稳定性定位与方案

日期：2026-10-22。范围：当前工作区源码、本机已有 app.log、隔离的本机 socket 复现和真实 socket 回归。已在工作区修复 P0 连接生命周期、业务连续失败自愈和无端口模式的路径/出口变化线索；没有切换用户 Clash 配置或操作远端服务器，也没有完成全天运行验收。

## 结论

保留 Clash TUN 无端口支持是可行的。当前工作区已修复 HTTP 入口拒绝路径泄漏，为 SSH 存活但业务通路连续失败增加受控重建，并为在线网络路径变化和无本地端口时的出口变化增加复测线索。入口活动连接数/拒绝原因统计、仅 HTTP 入口单独回收和完整分层故障展示仍是待办。应继续补齐这些应用自身能力，再依据分层证据处理特定 Clash 客户端的路由与 DNS 配置。

不能据现有证据认定用户这次全天故障全部由连接泄漏造成；目前可读取的日志只有 10 月 21 日片段，没有故障当天完整记录或入口活动连接数。

## 现有链路

无端口模式实际上有两个不同出口实现：

- SOCKS：Linux SOCKS 客户端 → 远端反向动态转发监听 → SSH 隧道 → Mac ssh 进程解析目标并出站 → 当前系统网络/TUN。
- HTTP：Linux HTTP 客户端 → 远端 HTTP 反向转发监听 → SSH 隧道 → App 内 HTTPEntryRelay → Network.framework 解析目标并出站 → 当前系统网络/TUN。

HTTP 入口并不是把流量再送入上述 SOCKS 入口。两个出口进程和网络 API 不同，故 SOCKS 成功不等于 HTTP 成功；按进程配置的 Clash 规则也可能使它们走不同路径，需在实际客户端活动中核对。

## 已确认问题

### P0：HTTP 拒绝路径不释放连接名额（已修复，待长时验收）

位置：`HTTPEntryRelay.EntryConnection.reject/close`。

原 `reject()` 先把 phase 设置为 closed，发送 400/502 响应后调用 close()。但 close() 第一行见到 closed 就返回，导致两端连接、定时任务和 finished 回调的清理被跳过。父级 connections 字典仍保留该项，达到 256 项后 accept() 会拒绝所有新连接。

上游 failed/waiting、非法请求、SOCKS 握手错误均能进入 reject 路径。它不局限于 Clash；无端口模式依赖 App 自身 HTTP 出口，TUN 波动引发的连接错误可能放大它。不能把 256 次请求等同于 256 次泄漏：正常完成的请求会清理，复现门槛是累计未清理的拒绝连接加当前活动连接达到上限。

本机隔离实验直接编译当前生产 HTTPEntryRelay，在回环地址启动源站和入口：

```text
healthy_before: HTTP/1.1 200 OK
256_rejected_requests: {'HTTP/1.1 400 Bad Request': 256}
healthy_after: ConnectionResetError
healthy_after_again: ConnectionResetError
```

工作区修复将生命周期拆成 `rejecting` 和 `closed` 两步：拒绝响应发送期间保留入口名额，发送完成或超时后执行一次幂等清理。新的集成回归直接对生产 `HTTPEntryRelay` 连续发送 300 次可确定性返回 `400 Bad Request` 的 CONNECT 请求，随后健康请求成功：

```text
healthy_before: HTTP/1.1 200 OK
300_rejected_requests: HTTP/1.1 400 Bad Request
healthy_after: HTTP/1.1 200 OK
```

该测试覆盖累计拒绝数量超过监听器 256 上限后的恢复能力，但没有模拟 Clash，也没有实测 300 次真实上游 502；上游失败路径与 400 走同一个 reject 生命周期，但长时业务负载仍需验收。

### P1：SSH 活着时，持续业务失败不触发自愈（已补受控自愈）

位置：`ManagedTunnelService.swift:293`；`SSHTunnelCoordinator.swift:633`。

原实现只把业务请求失败降级。现有重试处理 SSH 退出、SSH 尚未启动的本地不可用以及端口绑定冲突，不处理 sshProcessRunning=true 的持续 degraded。因此即使勾选自动重连，HTTP 入口耗尽或转发失效仍可能长期停在部分可用。

工作区现在只把远端 `connectionFailure` 视为连续业务硬失败；目标返回 403/429/5xx 等业务状态、探测超时、缺 curl 和认证终态不触发重建。连续三次明确失败且 SSH 仍存活时，在自动重连开启的前提下按 profile 受控重建：默认 60 秒冷却，5 分钟滚动窗口最多两次，带代际校验；用户断开、休眠或新连接意图会取消/重置待执行任务。预算用尽后继续探测并说明原因。

第一版结构化决策已接入快照和面板：`TunnelRecoveryDecision` 记录作用域（当前为远端业务通路）、动作（受控重建/只探测）、状态（已排程/已执行/已恢复/预算用尽）、原因、执行时间、连续失败数和剩余预算。协调器继续只提供证据，运行时策略层负责决策；后续分层探测可复用这套结构扩展作用域。该策略仍不能把一次业务失败当作隧道故障，也不能保证原有长连接不断。

UI 已迁移 magpie Routing 面板的三个交互原则：最近状态迁移保留为最多 6 条的“自愈轨迹”；默认折叠避免噪声，展开后按时间线显示状态、动作、原因和下次执行时间；提供“立即复测”和“查看日志”两个主动入口。原因文本可选中，但完整业务 URL、凭据和请求正文不会进入该卡片。

SSH 参数已经设置 ServerAliveInterval=30、ServerAliveCountMax=3。它们检测 SSH 通道存活，不能代替业务通路检测；ExitOnForwardFailure 也只覆盖转发建立失败。[OpenSSH 官方说明](https://man.openbsd.org/ssh_config#ExitOnForwardFailure)。

### P1：无端口模式缺少有效的变化指纹（部分补齐）

位置：`AppSystemServices.swift:75`、`LocalProxyDetector.swift:196`。

原 NWPathMonitor 回调只保留 satisfied 布尔值，且只响应断开后恢复。路径保持在线时的网络、路由或 TUN 变化不能触发恢复。

当前工作区保留了 NWPath 的接口、约束、费用和 IPv4/IPv6 能力摘要；路径保持在线但特征变化时，会经 1.5 秒去抖并按 ViewModel 侧 10 秒冷却触发本地代理扫描和活跃连接健康检查。无本地端口时另用 `--noproxy '*'` 探测当前网络出口 IP 作为弱信号。

这只是补齐变化线索：IP 未变化不代表路径未变，出口 IP 也不能证明 Clash 命中的节点或规则；网络变化仍必须由健康检查确认后才代表恢复。

### P1：故障分类在健康检查展示时丢失（源码及日志确认）

原周期健康检查把 connectionFailure 收敛为“远端验证未通过”，丢失具体错误详情。工作区已保留解析后的失败原因，并把连续硬失败次数带到快照供自愈策略使用。入口活动连接数、拒绝原因统计和仅 HTTP 入口的单独回收仍待补。

本机日志 10 月 21 日 13:53、13:58 两次显示 SOCKS 主路径通过、HTTP 入口未通过，随后恢复。这证明两条路径有独立波动，不能反推出具体原因。14:41 的远端端口冲突属于另一个已记录故障，不能和入口泄漏混为一谈。

## 建议实施顺序

### 第一步：修复连接生命周期并补可观测性

1. 已分开“正在返回拒绝响应”和“清理完成”状态；清理覆盖 incoming/outgoing cancel、定时任务撤销和 finished 回调。
2. 已为拒绝响应发送增加超时兜底；监听器停止仍会清理所有连接。
3. 记录入口当前连接数、连接峰值、已清理数、容量拒绝数、上游失败阶段及错误码，日志按原因节流且不记录业务请求正文或完整敏感 URL。
4. 已覆盖超过 256 次 400 后健康请求恢复；SOCKS 握手失败、客户端提前关闭、真实上游 502、正常 SSE 长连接和高并发仍需补测。

不建议通过提高 256 上限处理泄漏，也不建议给所有已建立连接统一增加短空闲超时，后者会伤害 SSE 等业务。

### 第二步：加入分层、有限度的自动修复

区分 Mac 当前出站、SSH 控制通道、Linux SOCKS 请求、Linux HTTP 请求和目标 HTTP 状态，探测结论携带时间和具体原因。

- 单次失败：短退避复测，只标记抖动。
- 连续三次远端连接失败且 SSH 存活：进入受控重建；业务 HTTP 状态不作为隧道故障。
- 仅 HTTP 失败：先尝试回收/重建 HTTP 入口；若要保留 SSH，入口需支持在原本地端口重启或可替换内部出站组件。当前 start/stop 为一次性生命周期，不能直接 stop 后再次 start 同一对象。
- Mac 出站正常、远端通路持续失败：在开启自动重连前提下受控重建对应隧道，并沿用现有端口冲突诊断。
- Mac 本身也出站失败：等待 TUN/网络恢复，采用退避探测，避免反复重建 SSH。
- 403/429/5xx 等业务响应与网络连接错误分开处理，不能只因目标返回业务错误就重连。

修复按 profile 串行，带代际校验、冷却和预算；用户断开立即取消。当前重建冷却 60 秒、5 分钟内最多 2 次，超过预算保持探测并解释原因。准确阈值需结合真实延迟调节。无法保证原有长连接在路径切换后不断，应用层重试由调用方负责。

### 第三步：补齐 TUN 无端口的路径感知

保留 NWPath 的接口等信息，并关注相关系统网络/DNS 配置变化；这些信号用于触发去抖后的重新探测，不能直接等同于 TUN 故障。仅在健康检查确认必要后修复，避免每个路径更新都断开重连。

无端口模式增加 Mac 当前网络出站和经远端通路的出口观测，取消对本地代理端口的依赖。IP 指纹只是辅助信息，既不证明特定 Clash 节点，也不代替业务检查。

按实际客户端与版本核查 TUN 路由、DNS/fake-IP、SSH 目的地址及进程规则。Mihomo 文档明确提示 macOS 无法自动劫持发往局域网的 DNS 请求，因此不能只凭 TUN 开关开启就认定 DNS 已正确接管。[官方 TUN 配置文档](https://wiki.metacubex.one/config/inbound/tun/)。该文档适用于 Mihomo，不能直接假设用户使用的所有 Clash/Network Extension 客户端实现一致。

### 后续架构优化：统一 App 内出口组件

当前 HTTP 与 SOCKS 分别由 App 和 ssh 进程出站，诊断及按进程规则行为不一致。可评估 App 内统一 SOCKS/HTTP 出站组件，SSH 仅承担固定反向字节转发，继续不依赖 Clash 本地端口。此项改动需要 SOCKS 域名语义、IPv6、并发、背压和长连接验证，建议在 P0/P1 修复和验收之后独立推进，不作为第一版热修复前提。

## magpie 设计借鉴

参考对象是 [magpie @ 86254d4](https://github.com/yetone/magpie/tree/86254d4)。它是本地 AI 网关，不是 TUN 客户端；不能把“一个业务请求中途换供应商”的模型直接搬进反向 TCP 隧道。可迁移的是它的失败语义、候选规划、可解释追踪和工程验证方式。

- **失败先分类，再决定对象和动作。** magpie 把配额、限速、鉴权、模型不支持、请求本身问题和供应商故障拆开；恢复动作只作用于故障对应的 key、账号、模型或请求。ProxyBridge 应继续沿这个方向区分 Mac 出站、SSH 通道、Linux SOCKS 通路、Linux HTTP 通路、HTTP 入口和目标响应。当前已把目标 HTTP 业务状态排除出隧道重建触发条件。
- **故障态有作用域、原因和到期时间。** magpie 的 `Rest` 记录 why/status/until/by/failures/key/model，而不是只存一个布尔值。ProxyBridge 已先用 `TunnelRecoveryDecision` 记录自愈作用域、动作、原因、执行时间、失败数和预算；完整故障证据仍需继续扩展到各探测层。
- **候选计划与执行追踪分离。** magpie 先生成 ordered candidates，再逐个尝试，并把剩余候选、被排除原因和每次尝试写入 trace。ProxyBridge 的连接自愈也可先生成候选动作（重测 HTTP 入口、重测远端、重建隧道、等待路径恢复），面板展示为什么执行或跳过，而不是只显示最终降级。
- **小面板保留最近轨迹和主动干预。** magpie 的 tray Routing tab 显示最近请求、每跳状态、resting 原因，并提供 Try now。ProxyBridge 已迁移为自愈时间线加“立即复测”；完整候选池规划仍待后续分层探测落地。
- **保持会话亲和，避免无故障切换。** magpie 在供应商可用时尽量让会话留在原账号。ProxyBridge 的对应原则是：路径未证实故障时不做 automatic 静态/动态模式横跳；已有长连接只如实报告可能中断，不用重连去“刷新”状态。
- **插件和钩子有明确失败策略。** magpie 的普通中间件 fail-open，遮敏类能力 fail-closed，且钩子有超时与回滚。ProxyBridge 将来若加入诊断钩子或扩展，遥测应允许失败，而凭据脱敏、主机密钥和回环绑定必须 fail-closed。
- **把工程教训写成可检查规则。** magpie 的 `code-standards` 强调修同类而非单例、失败读取视为 unknown、检查兄弟路径、测试不访问网络、并发路径跑 race。这些与本次 TUN 稳定性问题直接相关：同一泄漏模式要在所有 reject/close 分支修掉；探测失败必须保持 unknown；路径变化不能直接当作 TUN 故障。

## 验收要求

- 确保 Clash 没有本地 HTTP/SOCKS 端口，分别实测远端 SOCKS 与 HTTP。
- 至少连续运行 24 小时，持续产生新连接并保留长连接，观测连接数、FD、内存、失败率和恢复时间。
- 注入节点切换、TUN 开关/重启、Wi-Fi 变更、睡眠唤醒、DNS 变化及 SSH 短断，验证原因分类和修复预算。
- 超过 256 次可恢复拒绝/失败之后，新健康请求仍成功，已结束连接数回归基线。
- 自愈轨迹在系统重建经过 idle 时保持 scheduled → executed → succeeded/budget exhausted 的顺序；用户断开后新连接会重开轨迹。
- Mac 出站正常且仅应用链路异常时，以 60–120 秒内恢复新请求为初始目标；TUN 自身不可达时如实等待，不承诺该恢复时限。
- 每次自动恢复记录原因、对象、动作和结果，不产生模式横跳、端口冲突放大或重连风暴。

## 当前验证与边界

本工作区已通过：

- `bash scripts/typecheck.sh`
- `bash scripts/integration_test.sh`（6/6，含 300 次拒绝后健康请求恢复）
- `bash scripts/relay_test.sh`

`bash scripts/smoke_test.sh` 203/203 通过。新增 XCTest 已纳入类型检查；本机当前只启用 Command Line Tools，`xcodebuild test` 无法执行，需在装完整 Xcode 的 CI 上跑全量 XCTest。未完成全天运行、真实 Clash TUN、睡眠唤醒、节点切换和业务失败自愈验收。复现材料位于 `build/tun-diagnosis/`（构建目录被忽略，不属于正式测试套件）。
