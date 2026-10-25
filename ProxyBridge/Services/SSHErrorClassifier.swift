import Foundation

/// SSH 进程退出 / stderr 的分类（纯函数，02-TECHNICAL-DESIGN §5.3/§10）。
enum SSHErrorClassifier {

    /// 分类结论 → 状态机相 + 人可读文案。
    enum Classification: Equatable, Sendable {
        /// 首次连接、known_hosts 无记录（TOFU 可引导：应用内核对指纹后写入）
        case hostKeyUnknown(detail: String)
        /// 认证或主机密钥问题 → authRequired（停止无意义重试，等用户处理）
        case authRequired(detail: String)
        /// 转发绑定失败 / sshd 禁止转发 / 网络不可达等 → error
        case error(detail: String)
        /// 无 stderr 特征的一般失败
        case genericFailure(exitCode: Int32)
    }

    /// 主分类入口。`stderr` 取进程退出前的尾部输出（已由调用方截断）。
    static func classify(exitCode: Int32, stderr: String) -> Classification {
        let lower = stderr.lowercased()

        // 顺序敏感：host key 判定须在 permission denied 之前
        // （"Host key verification failed." 不含 permission denied，但同属 authRequired 域）
        if lower.contains("host key verification failed") {
            // 密钥变化（REMOTE HOST IDENTIFICATION HAS CHANGED / has changed）是潜在劫持信号：
            // 绝不提供一键覆盖，必须人工核对后自行移除旧记录
            if lower.contains("has changed") || lower.contains("host key verification failed") && lower.contains("offending") {
                return .authRequired(detail: "服务器主机密钥与 known_hosts 记录不一致：可能是服务器重装，也可能是连接被劫持。请通过可信渠道核对后，在终端运行 ssh-keygen -R 清除旧记录再重试")
            }
            return .hostKeyUnknown(detail: "首次连接该服务器：known_hosts 尚无记录。可在应用内核对指纹并信任，或自行在终端 ssh 一次")
        }
        if lower.contains("permission denied") {
            if lower.contains("publickey") || lower.contains("password") || lower.contains("keyboard-interactive") {
                return .authRequired(detail: "SSH 认证被拒绝：检查密码、密钥/ssh-agent 与远端 authorized_keys")
            }
            return .authRequired(detail: "SSH 认证被拒绝：检查密钥/ssh-agent 与远端 authorized_keys")
        }
        if lower.contains("remote port forwarding failed") {
            return .error(detail: "远程监听端口建立失败：端口可能被占用或 sshd 限制转发（AllowTcpForwarding/PermitListen），请修改远端端口或联系服务器管理员")
        }
        if lower.contains("administratively prohibited") {
            return .error(detail: "服务器禁止 TCP 转发（sshd AllowTcpForwarding=no）：请联系管理员，App 不会修改 sshd 配置")
        }
        if lower.contains("could not resolve hostname") {
            return .error(detail: "无法解析 SSH 主机名：检查主机名拼写与 DNS")
        }
        if lower.contains("connection timed out") || lower.contains("timed out") {
            return .error(detail: "连接 SSH 主机超时：检查网络、内网路由或 VPN")
        }
        if lower.contains("no route to host") || lower.contains("network is unreachable") {
            return .error(detail: "网络不可达：检查内网路由或 VPN")
        }
        if lower.contains("connection refused") {
            return .error(detail: "SSH 端口拒绝连接：确认主机与 SSH 端口正确且 sshd 在运行")
        }
        if lower.contains("too many authentication failures") {
            return .authRequired(detail: "认证尝试次数超限：减少 ssh-agent 中加载的密钥或改用指定密钥模式")
        }
        if lower.contains("no supported authentication methods") {
            return .authRequired(detail: "没有可用的认证方式：服务器拒绝了本地全部密钥，检查密钥类型是否被服务器允许")
        }
        return .genericFailure(exitCode: exitCode)
    }

    /// 从 stderr 中挑出最有信息量的原始行（分类解读之外的「sshd 原话」透传）。
    /// 规则：剔除噪声行（known_hosts 提示等）；优先含故障关键词的行（取最后一条——
    /// 越靠后越接近退出原因）；没有关键词时取最后一条非空行。空/无有效行返回 nil。
    static func mostInformativeLine(stderr: String) -> String? {
        let keywords = ["denied", "failed", "refused", "timeout", "timed out",
                        "reset", "closed by", "forwarding", "unreachable", "no route"]
        let lines = stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("Permanently added") } // known_hosts 提示是噪声；其余 Warning 行（如转发失败）是关键证据
        guard !lines.isEmpty else { return nil }
        let informative = lines.filter { line in
            keywords.contains { line.lowercased().contains($0) }
        }
        let chosen = (informative.last ?? lines.last) ?? ""
        return chosen.isEmpty ? nil : String(chosen.prefix(160))
    }

    /// 分类 → 状态机快照字段（相 + 文案）。
    static func phaseAndDetail(for classification: Classification) -> (phase: TunnelPhase, detail: String) {
        switch classification {
        case .hostKeyUnknown(let detail):
            return (.authRequired, detail)
        case .authRequired(let detail):
            return (.authRequired, detail)
        case .error(let detail):
            return (.error, detail)
        case .genericFailure(let code):
            return (.error, "SSH 进程异常退出（退出码 \(code)），请查看日志")
        }
    }
}
