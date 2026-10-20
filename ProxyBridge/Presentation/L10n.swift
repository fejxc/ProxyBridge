import Foundation

/// 界面语言（P2 i18n）：跟随系统 / 简体中文 / English。
/// 与 L10n 同文件定义：TunnelStatus 等部分编译链路（relay_test）只引入本文件。
enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case chinese
    case english

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// 轻量界面语言层（P2 i18n）。
///
/// 机制：中文文案本身作为 key —— 中文模式下返回原文（零行为差异）；
/// 英文模式查词典，缺项如实回退中文（不假装已翻译）。
/// 事件详情、日志等由服务层生成的长文案仍为中文（见 KNOWN_LIMITATIONS）。
///
/// 并发说明：`effective` 仅在 MainActor（AppViewModel bootstrap/updateSettings）写入，
/// 读取无锁安全（语言切换是罕见的单次赋值）；词典为不可变常量。
enum L10n {
    /// 当前生效语言（bootstrap 时从 AppSettings 解析并注入）。
    nonisolated(unsafe) static var effective: AppLanguage = .chinese

    /// 解析「跟随系统」：zh 前缀 → 中文，否则英文。
    static func resolve(_ setting: AppLanguage) -> AppLanguage {
        guard setting == .system else { return setting }
        let preferred = Locale.preferredLanguages.first ?? "zh"
        return preferred.hasPrefix("zh") ? .chinese : .english
    }

    /// 注入设置并返回实际生效语言。
    @discardableResult
    static func apply(_ setting: AppLanguage) -> AppLanguage {
        effective = resolve(setting)
        return effective
    }

    /// 翻译入口：英文模式查词典，缺项回退中文原文。
    static func t(_ key: String) -> String {
        guard effective == .english else { return key }
        return english[key] ?? key
    }

    /// 英文词典（key = 中文原文，须与代码字面量完全一致）。
    /// 覆盖：菜单栏面板、状态展示、密码/指纹/依赖卡、通用设置、流量卡。
    static let english: [String: String] = [
        // MARK: 菜单栏面板
        "SSH 反向代理管理": "SSH Reverse Proxy Manager",
        "退出 ProxyBridge": "Quit ProxyBridge",
        "打开设置": "Open Settings",
        "确定退出 ProxyBridge？": "Quit ProxyBridge?",
        "退出并断开所有隧道": "Quit and disconnect all tunnels",
        "取消": "Cancel",
        "当前有活跃的 SSH 连接，退出会断开这些隧道（不会遗留 ssh 进程）。": "Active SSH connections will be disconnected on quit (no ssh processes will be left behind).",
        "尚未配置服务器": "No server configured",
        "第一步：在设置中确认本地代理；第二步：添加服务器并填写 SSH 信息。": "Step 1: verify your local proxy in Settings. Step 2: add a server with its SSH details.",
        "打开设置，添加服务器": "Open Settings to add a server",
        "选择服务器": "Choose server",
        "选择当前服务器": "Choose current server",
        "Mac 网络出口": "Mac network egress",
        "本地上游 · Mac": "Local upstream · Mac",
        "Linux Codex HTTP": "Linux Codex HTTP",
        "Linux SOCKS5": "Linux SOCKS5",
        "Linux 远端代理": "Linux remote proxy",
        "使用 Mac 当前网络栈": "Mac's current network stack",
        "未发现入口；自动模式将尝试 SOCKS5": "No local entry found; automatic mode will try SOCKS5",
        "需要可验证的本地上游": "A verifiable local upstream is required",
        "模式 · ": "Mode · ",
        "仅 127.0.0.1 · TCP": "127.0.0.1 only · TCP",
        "不需要本地代理端口": "No local proxy port needed",
        "本地入口已通过实测": "Local entry verified by real request",
        "本地代理": "Local proxy",
        "SSH 隧道": "SSH tunnel",
        "远端 SOCKS5": "Remote SOCKS5",
        "远端代理": "Remote proxy",
        "HTTP 兼容入口": "HTTP compat entry",
        "HTTP CONNECT 已验证": "HTTP CONNECT verified",
        "HTTP 入口待验证": "HTTP entry pending verification",
        "本地代理已通过协议验证": "Local proxy passed protocol verification",
        "尚未验证本地代理可用性": "Local proxy not verified yet",
        "本地代理验证失败：请确认代理已启动或改用手动配置": "Local proxy failed verification: make sure it is running or switch to manual config",
        "经远端 SOCKS5 请求验证 Mac 当前网络出站；Clash 节点尚未确认": "Mac egress verified via remote SOCKS5 request; Clash node unconfirmed",
        "尚未通过远端请求验证 Mac 出站": "Mac egress not verified via remote request yet",
        "经 SSH 反向 SOCKS5 的公网请求失败": "Public request through SSH reverse SOCKS5 failed",
        "隧道运行中": "Tunnel running",
        "正在建立 SSH 连接…": "Establishing SSH connection…",
        "需要核对服务器指纹或 SSH 身份验证": "Server fingerprint or SSH identity needs attention",
        "SSH 未连接": "SSH not connected",
        "Linux SOCKS5 已通过远端 HTTPS 请求验证": "Linux SOCKS5 verified via remote HTTPS request",
        "远端代理端到端验证通过": "Remote proxy verified end to end",
        "Linux SOCKS5 尚未验证": "Linux SOCKS5 not verified yet",
        "远端代理未验证（未验证 ≠ 可用）": "Remote proxy unverified (unverified ≠ working)",
        "远端验证失败，请查看日志定位原因": "Remote verification failed; check logs for the cause",
        "等待 SOCKS5 验活后检查 HTTP CONNECT 入口": "HTTP CONNECT entry checked after SOCKS5 verification",
        "点击查看日志定位原因": "Click to open logs",
        "检查连接": "Check connection",
        "只重新验证，不修改任何配置": "Re-verify only; no settings are changed",
        "连接服务器": "Connect",
        "断开连接": "Disconnect",
        "处理中…": "Working…",
        "完整环境变量示例": "Full env-var example",
        "SOCKS5 验收 curl": "SOCKS5 acceptance curl",
        "HTTP_PROXY + CONNECT 验收": "HTTP_PROXY + CONNECT acceptance",
        "复制 Linux 命令": "Copy Linux commands",
        "复制 Linux SOCKS5 或 HTTP_PROXY 验收命令；不修改服务器配置": "Copy Linux SOCKS5/HTTP_PROXY acceptance commands; server config untouched",
        "查看日志": "View logs",
        "打开发布页下载新版本": "Open the release page to download",
        "产品重点：随时知道本地代理、SSH 隧道、远端代理各自是否正常，而不是只看到「SSH 已连接」。": "Key idea: always know whether the local proxy, the SSH tunnel and the remote proxy each work — not just “SSH connected”.",

        // MARK: 状态展示（TunnelStatusPresentation）
        "未连接": "Not connected",
        "点击连接以建立转发": "Click connect to set up forwarding",
        "检查中": "Checking",
        "动态 SOCKS5 模式不需要本地代理端口": "Dynamic SOCKS5 needs no local proxy port",
        "正在检查连接方式…": "Choosing connection mode…",
        "正在重连": "Reconnecting",
        "正在建立 SSH 隧道…": "Establishing SSH tunnel…",
        "重连中": "Reconnecting",
        "连接中": "Connecting",
        "已连接": "Connected",
        "远端代理已验证": "Remote proxy verified",
        "部分可用": "Partially available",
        "隧道已建立，远端代理未验证": "Tunnel up, remote proxy unverified",
        "代理异常": "Proxy issue",
        "本地代理未通过验证": "Local proxy failed verification",
        "未发现代理": "No proxy found",
        "确认代理客户端运行中，重新点「连接」或手动指定端口": "Make sure the proxy client is running, click Connect again or set a port manually",
        "需要处理": "Action needed",
        "检查服务器指纹或 SSH 密钥": "Check server fingerprint or SSH key",
        "连接失败": "Failed",
        "发生错误，请查看日志": "An error occurred; check logs",
        "断开中": "Disconnecting",
        "正在停止 SSH 进程…": "Stopping SSH process…",
        "未配置": "Not configured",
        "打开设置添加第一台服务器": "Open Settings to add your first server",

        // MARK: 密码卡
        "「": "“",
        "」需要 SSH 密码": "” needs the SSH password",
        "服务器": "server",
        "密码仅用于本次连接（经系统 PTY 交给 ssh）；勾选「记住」则存入本机钥匙串，之后自动登录。": "The password is used for this connection only (handed to ssh via PTY); tick “Remember” to store it in Keychain for automatic login.",
        "记住密码（本机钥匙串）": "Remember password (Keychain)",
        "SSH 密码": "SSH password",
        "提交": "Submit",
        "输入 SSH 密码": "Enter SSH password",

        // MARK: 指纹卡
        "」是首次连接": "” is connecting for the first time",
        "本机尚无该服务器的主机密钥记录。请在下方获取指纹，并通过可信渠道（服务器管理员、云控制台）核对一致后再信任；不匹配说明连接可能被劫持，请勿继续。": "No host key record exists for this server. Fetch the fingerprint below and verify it through a trusted channel (admin / cloud console) before trusting; a mismatch may mean hijacking — do not continue.",
        "获取主机指纹（ssh-keyscan）": "Fetch host fingerprint (ssh-keyscan)",
        "暂不处理": "Not now",
        "正在获取主机指纹…": "Fetching host fingerprint…",
        "指纹一致，信任并重连": "Fingerprints match — trust and reconnect",
        "不一致，放弃": "Mismatch — abort",
        "核对服务器主机指纹": "Verify server host fingerprint",

        // MARK: 远端依赖卡
        "复制安装指引": "Copy install guide",
        "已安装，重试验证": "Installed — re-verify",

        // MARK: 流量卡
        "流量统计暂不可用": "Traffic stats unavailable",
        "动态 SOCKS5 不经过本地 Relay；应用不会把 SSH 进程字节误报为代理业务流量。": "Dynamic SOCKS5 bypasses the local relay; SSH process bytes are never reported as proxy traffic.",
        "会话时长 ": "Session ",
        "上传": "Upload",
        "下载": "Download",
        "流量详情": "Traffic details",
        "建立连接后显示最近 60 秒速率": "Last 60s rates appear after connecting",
        "本次连接总流量": "Total this session",
        "最近 60 秒": "Last 60 s",
        " 个 TCP 连接": " TCP connections",
        "累计": "Total ",
        "：": ": ",
        "秒": "s",

        // MARK: 其他
        "远端缺少 ": "Missing on server: ",
        "新版本 ": "New release: ",
        "可用": " available",
        "正在检查…": "Checking…",
        "发现新版本 v": "Update available: v",
        "（当前 v": " (current v",
        "）": ")",
        "确认退出": "Confirm quit",
        "SSH 进程会被终止，不会遗留。": "SSH processes will be terminated; nothing is left behind.",

        // MARK: 远端端口冲突诊断卡
        "」远端端口被占用": "” remote ports are occupied",
        "正在经 SSH 诊断端口占用…": "Diagnosing port holders over SSH…",
        "正在清理远端残留…": "Cleaning remote leftovers…",
        "重试诊断": "Retry diagnosis",
        "重新诊断": "Re-diagnose",
        "忽略": "Ignore",
        "清理残留并重连": "Clean leftovers and reconnect",
        "定位日志文件": "Reveal log file",
        "出口 ": "Egress ",
        "经本地代理观测到的出口 IP；变化即代表节点切换，应用会自动重新验证": "Egress IP observed through the local proxy; a change means the node switched and the app re-verifies automatically",
        "自动更新（下载 · 校验 · 安装）": "Auto update (download · verify · install)",
        "正在下载更新…": "Downloading update… ",
        "正在校验 SHA-256…": "Verifying SHA-256…",
        "正在安装并重启…": "Installing and relaunching…",
        "重试下载": "Retry download",
        "（仅代表该目标可达）": " (only proves this target is reachable)",
        "仅清理同用户的僵尸 sshd 与本 App 的孤儿 Privoxy；其他进程不会被触碰。": "Only same-user stale sshd sessions and this app's orphaned Privoxy are cleaned; other processes are never touched.",
        "僵尸 sshd · 可清理": "stale sshd · cleanable",
        "孤儿 Privoxy · 可清理": "orphan Privoxy · cleanable",
        "有活连接 · 不清理": "live connection · keep",
        "其他进程 · 不清理": "other process · keep",

        // MARK: 服务器编辑器
        "10.x.x.x 或 example.com": "10.x.x.x or example.com",
        "SSH 用户名": "SSH username",
        "例如：实验室 GPU 服务器": "e.g. Lab GPU server",
        "基本信息": "Basics",
        "认证方式": "Authentication",
        "已记住密码（本机钥匙串）": "Password remembered (Keychain)",
        "记住密码（存入本机钥匙串）": "Remember password (Keychain)",
        "忘记密码": "Forget password",
        "反向代理配置": "Reverse proxy",
        "连接模式": "Connection mode",
        "首选协议": "Preferred protocol",
        "网络波动时自动恢复 SSH 连接": "Auto-recover SSH on network drops",
        "App 启动后，自动连接此服务器": "Connect automatically after launch",
        "固定本地 Relay 端口": "Fixed local relay port",
        "提供 HTTP 入口（Codex 继续使用 7890）": "Provide HTTP entry (Codex keeps 7890)",
        "主路径验证通过后立即实测 HTTP CONNECT；入口异常时主路径不受影响。": "HTTP CONNECT is verified right after the main path; entry issues never affect the main path.",
        "保存更改": "Save changes",
        "放弃": "Discard",
        "删除配置": "Delete server",
        "删除（不可撤销）": "Delete (irreversible)",
        "未选择服务器": "No server selected",
        "添加一台服务器开始使用：填写名称、SSH 主机、端口、用户名即可（首次连接时可在应用内核对并信任主机指纹，也可在终端先 ssh 一次）。": "Add a server to get started: name, SSH host, port and username suffice (verify the host fingerprint in-app on first connect, or ssh once in a terminal).",
        "从 ~/.ssh/config 导入": "Import from ~/.ssh/config",
        "仅读取 HostName / Port / User / IdentityFile；导入后可再编辑。与既有配置同主机、同端口、同用户名的条目自动跳过。": "Reads HostName / Port / User / IdentityFile only; editable after import. Entries duplicating an existing host/port/username are skipped.",
        "全选": "Select all",
        "导入选中（": "Import selected (",
        "浏览…": "Browse…",

        // MARK: 本地代理设置
        "代理来源": "Proxy source",
        "自动检测": "Auto-detect",
        "手动指定": "Manual",
        "手动指定的优先级高于自动检测结果；连接前仍会实测验证。": "Manual overrides detection; still probe-verified before connecting.",
        "应用手动代理": "Apply manual proxy",
        "协议": "Protocol",
        "重新检测": "Re-detect",
        "正在检测本地代理…": "Detecting local proxy…",
        "未发现可用的本地代理候选": "No usable local proxy candidate found",
        "未发现可验证的本地代理端口。可手动指定入口；若代理使用 TUN/Network Extension，也可以使用动态 SOCKS5。": "No verifiable local proxy port. Set one manually, or use dynamic SOCKS5 if your proxy runs TUN/Network Extension.",
        "检测到本地代理端点": "Detected local proxy endpoints",
        "来源：": "Source: ",
        " 代理": " proxy",
        "限制与说明": "Limitations & notes",

        // MARK: 日志
        "全部服务器": "All servers",
        "全部级别": "All levels",
        "时间": "Time",
        "级别": "Level",
        "清空": "Clear",

        // MARK: 通用设置
        "应用行为": "App behavior",
        "登录时启动 ProxyBridge": "Launch ProxyBridge at login",
        "登录时启动": "Launch at login",
        "显示连接异常通知": "Connection alert notifications",
        "通知": "Notifications",
        "远端健康检查间隔": "Remote health-check interval",
        "定期在服务器上通过 curl 验证代理，每次只运行一个探测。": "Verify the proxy with curl on the server periodically; one probe at a time.",
        "间隔": "Interval",
        "本地轻量检查间隔": "Local light-check interval",
        "定期验证当前隧道使用的本地代理，不登录远端。": "Periodically verify the local proxy used by the tunnel; no remote login.",
        "复制日志时脱敏": "Redact logs on copy",
        "遮挡内网 IP、用户@主机、密钥路径与凭据。": "Mask internal IPs, user@host, key paths and credentials.",
        "脱敏": "Redact",
        "启动时检查更新": "Check for updates at launch",
        "检查更新": "Check for updates",
        "只读 GitHub 公开接口比对版本号，不上传任何数据；发现新版本时在菜单栏提示。": "Reads the public GitHub API to compare versions; no data is uploaded; new releases appear in the menu bar.",
        "连接期间防止空闲休眠": "Prevent idle sleep while connected",
        "有活跃隧道时阻止系统空闲休眠（合盖睡眠不受影响）。断开或退出后立即恢复系统默认。": "Hold an idle-sleep assertion while tunnels are active (lid close still sleeps). System default resumes on disconnect or quit.",
        "防止休眠": "Prevent sleep",
        "授权通知": "Allow notifications",
        "刷新系统授权状态": "Refresh system permission status",
        "关于": "About",
        "ProxyBridge · SSH 反向代理管理工具": "ProxyBridge · SSH reverse proxy manager",
        "版本：": "Version: ",
        "有新版本 ": "Update available: v",
        " 可用": "",
        "通过 SSH 将 Mac 本地代理转发至服务器的回环端口。": "Forwards the Mac's local proxy to the server's loopback port over SSH.",
        "打开发布页": "Open release page",
        "界面语言": "UI language",
        "切换后立即生效；事件详情与日志文案保持中文。": "Takes effect immediately; event details and logs remain in Chinese.",

        // MARK: 设置窗口标签
        "设置": "Settings",
        "我的服务器": "My servers",
        "添加服务器": "Add server",
        "服务器配置": "Servers",
        "连接日志": "Logs",
        "通用设置": "General",
        "管理 SSH 主机、身份认证及远程监听端口。": "Manage SSH hosts, authentication and remote listen ports.",
        "读取本机系统代理设置，验证可用协议与监听端口。": "Read system proxy settings; verify protocols and ports.",
        "显示最近的事件、健康检查与错误原因。": "Recent events, health checks and error causes.",
        "管理启动、健康检查以及默认行为。": "Startup, health checks and defaults.",
    ]
}
