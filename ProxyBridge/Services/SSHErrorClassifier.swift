import Foundation

/// SSH 进程退出 / stderr 的分类（纯函数，02-TECHNICAL-DESIGN §5.3/§10）。
enum SSHErrorClassifier {

    /// 分类结论 → 状态机相 + 人可读文案。
    enum Classification: Equatable, Sendable {
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
            return .authRequired(detail: "服务器主机密钥未通过校验：请先在终端手动 ssh 一次，核对指纹并写入 known_hosts 后重试")
        }
        if lower.contains("permission denied") {
            if lower.contains("publickey") || lower.contains("password") || lower.contains("keyboard-interactive") {
                return .authRequired(detail: "SSH 认证被拒绝：检查密钥/ssh-agent 与远端 authorized_keys（App 不使用密码登录）")
            }
            return .authRequired(detail: "SSH 认证被拒绝：检查密钥/ssh-agent 与远端 authorized_keys")
        }
        if lower.contains("remote port forwarding failed") || lower.contains("warning: remote port forwarding") {
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

    /// 分类 → 状态机快照字段（相 + 文案）。
    static func phaseAndDetail(for classification: Classification) -> (phase: TunnelPhase, detail: String) {
        switch classification {
        case .authRequired(let detail):
            return (.authRequired, detail)
        case .error(let detail):
            return (.error, detail)
        case .genericFailure(let code):
            return (.error, "SSH 进程异常退出（退出码 \(code)），请查看日志")
        }
    }
}
