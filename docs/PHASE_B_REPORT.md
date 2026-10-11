# 阶段 B 交付报告 · 本地代理自动检测

> 日期：2026-10-11 ｜ 对应 05-IMPLEMENTATION-PLAN 的 M2
> 环境：macOS 15.1.1（arm64）· Swift 6.0.2（Command Line Tools，无完整 Xcode）

## 一、状态总览

| 项 | 状态 | 证据 |
|---|---|---|
| SCDynamicStoreCopyProxies 读取（HTTP/HTTPS/SOCKS/PAC） | ✅ 通过 | 冒烟 S29 与 `scutil --proxy` 手工输出逐字段一致（本机 127.0.0.1:7897） |
| 物理端点去重 + 双协议待测（U01/U02） | ✅ 通过 | S29 候选 = `http\|127.0.0.1:7897, socks5\|127.0.0.1:7897`（与本机三字段同端口场景一致）+ 专项单测 |
| 全关/PAC 限制（U03/U04） | ✅ 通过 | 单测：全关→无候选+说明；PAC→不捏造端口+限制文案 |
| curl 真实协议探测（退出码+状态码判定，U12） | ✅ 通过 | 真实 curl 三连证据：关闭端口→`connectionRefused`（S28a）；假 HTTP 服务器→`reachableNotProxy` 绝不变绿（S28b）；**本机 7897 端到端 HTTP 200**（S30） |
| 手动覆盖优先（U05） | ✅ 通过 | EndpointResolver 单测（阶段 A 已建）+ 连接链路复用 |
| 系统代理变化通知 + 800ms 防抖（U15） | ✅ 通过 | SCDynamicStoreKeyCreateProxies 订阅 + fake monitor 单测（5 次变化→1 次扫描）；真机通知链路编译验证，实机切换代理验证待人工（见未验证） |
| 端口监听但协议失败 → 不可用（U12） | ✅ 通过 | 解析单测 + S28b 真实 curl 证据 |
| `xcodebuild build` / XCTest 运行 | ⛔ 阻塞 | 本机无完整 Xcode（同阶段 A）；请用 `bash scripts/xcode_test.sh` 在有 Xcode 的 Mac 上复核 |
| 实机切换代理端口触发自动重扫（人工） | ⚠️ 未验证 | 代码与订阅已实现并有单测；需真机手动关闭/切换 Clash 端口观察面板自动更新 |
| E01–E10 端到端（含 SSH） | ⛔ 计划外 | 阶段 C/D |

## 二、新增交付

**源码（3 文件）**
- `Services/SystemProxyProvider.swift` — SystemProxySnapshot / SCDynamicStoreProxyProvider（纯解析可单测，容错 CFNumber/CFString/端口 0）/ ProxyCandidateBuilder（物理端点去重保双协议、HTTPS 字段语义纠正、PAC/TUN/非回环限制如实标注）
- `Services/ProxyProtocolProbe.swift` — ProbeOutcome 七态 / CurlProxyProbe：`/usr/bin/curl` 参数数组直传（首参 `-q` 防 `~/.curlrc` 劫持【已实测攻击面】、白名单验证 URL、干净环境、IPv6 方括号）、Task 取消→terminate 在途进程、退出码+`%{http_code}`+stderr 三源判定（407 经 `CONNECT … response 407` 识别、60/35/58→TLS）
- `Services/LocalProxyDetector.swift` — SCDynamicStoreChangeMonitor（正确卸载顺序防 use-after-free、失败如实上报）+ LocalProxyDetector（防抖、代次失效守卫、回环候选并发探测、isLive 标识）

**测试**：SystemProxyDetectionTests（解析/构建/参数数组/探测解析/回环判定，U01–U04+U12）、LocalProxyDetectorTests（U15 防抖、探测目标精确断言、代次失效、通知失效上报、混合快照）。

**冒烟 85 项**（新增 S28 真实 curl ×2、S29 真实系统读取对照、S30 端到端实测）。

## 三、对抗评审（45-agent 工作流）

3 维度（Process 安全 / SystemConfiguration 正确性 / 测试有效性）→ 每发现 2 名独立怀疑者：**21 项发现 → 16 确认 → 全部修复**。要点：

| 严重度 | 发现 | 修复 |
|---|---|---|
| high | Monitor stop/deinit 未按 SDK 顺序停用队列，回调 use-after-free 竞态 | 清键→SetDispatchQueue(nil)→queue.sync 排空→释放；deinit 走同一 teardown |
| medium | IPv6 `::1` 无方括号 → curl exit 5，回环 IPv6 代理永远验证失败 | host 含 `:` 时加 `[]`（含已带括号不重复）+ 实证单测 |
| medium | 407 判定在 HTTPS 流程不可达（走 exit 56），带认证代理被误诊 | stderr 参与解析：`response 407` → authRequired |
| medium | SetNotificationKeys/SetDispatchQueue/Create 失败静默，通知断链无信号 | start() 返回 Bool + OSLog + 面板限制说明三通道上报 |
| medium | live 模式 verified 徽章仍写「演示」 | isLive 区分「已验证」/「已验证 · 演示」 |
| medium | FakeProber 忽略探测目标（掩盖接线 bug） | 记录 (host,port,protocol) 并精确断言集合 |
| medium | S29b 在仅 HTTPS 代理的机器上假失败 | 断言改为 http‖https 字段蕴含 |
| medium | 代次失效机制零测试 | GatedProxyProber + 快照切换测试钉死 |
| low ×5 | stderr 死代码、exit 60 未映射、探测不可取消、127/8 与 IPv6 展开形式误判、S30 恒真分支、死断言、候选 id 随能力漂移 | 全部修复 |

外加开发过程中自查发现并实证的 **`~/.curlrc` 劫持面**：本机实测无 `-q` 时 curlrc 中 `-x` 能把探测重定向到假代理（exit 7），`-q` 首参后跳过配置文件（200）——已固定进参数数组与测试。

## 四、验证命令与真实输出

```console
$ bash scripts/typecheck.sh      # App 0 error · 测试代码 0 error · Swift 6 语言模式通过
$ bash scripts/smoke_test.sh
PASS  S28a  真实 curl：拒绝连接 → connectionRefused
PASS  S28b  真实 curl：非代理端口绝不变绿（实际：reachableNotProxy(statusCode: nil)）
—— 本机系统代理（scutil --proxy 对照）——
   HTTP  = 127.0.0.1:7897   HTTPS = 127.0.0.1:7897   SOCKS = 127.0.0.1:7897   PAC = 关闭
PASS  S29a  真实读取系统代理：启用的端口字段合法
   候选  = http|127.0.0.1:7897, socks5|127.0.0.1:7897
PASS  S29b  候选构建与系统设置一致（HTTP/HTTPS 字段 → HTTP 候选）
   实测  = 经系统代理 127.0.0.1:7897 访问 www.example.com 成功（HTTP 200）
PASS  S30  端到端实测：本机系统代理真实可用
----------------------------------------  通过 85 项，失败 0 项  RESULT: PASS
```

## 五、诚实性声明

- 检测语义严格分层：**未发现（无候选）/ 端口可达但非代理（reachable）/ 探测失败（failed）/ 已验证（verified，必须 curl 2xx/3xx 网络证据）**；UI 徽标与候选 note 逐条对应。
- SSH 隧道仍为 Mock（阶段 C），面板横幅明确「本地代理已真实读取系统设置并经 curl 实测；SSH 隧道仍为演示」。
- 非回环候选只显示不探测不转发；PAC/TUN/带认证代理均给出局限说明而非猜测。
- 实机「切换代理端口自动重扫」的 GUI 人工验证未做（无 GUI 自动化能力），已在未验证项列明。
