import Foundation

/// 远端端到端验证结论（经隧道在远端实测代理，02-TECHNICAL-DESIGN §7）。
enum RemoteProbeOutcome: Equatable, Sendable {
    /// 远端 curl 经 127.0.0.1:<port> 收到 2xx/3xx。
    case verified(statusCode: Int)
    /// 收到 HTTP 响应但状态码异常（代理路径通，但目标异常）。
    case notProxy(statusCode: Int)
    /// 远端没有 curl → unknown（不伪称失败/成功）。
    case remoteCurlMissing
    /// SSH 层认证/主机密钥问题。
    case authRequired(detail: String)
    /// SSH 连接层失败（超时/拒绝/不可达等）。
    case connectionFailure(reason: String)
    /// 无法得出结论（超时/输出异常）。
    case unknown(reason: String)

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

/// 远端探测执行抽象（测试注入 / 生产 SSH 实现）。
protocol RemoteProbeExecuting: AnyObject, Sendable {
    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol) async -> RemoteProbeOutcome
}

/// 生产实现：一次性 `ssh` 执行受控远端脚本，收集 stdout/exit 后解析。
/// 与隧道进程完全独立（不写 -N 隧道的 stdin），并发由协调器加锁。
final class SSHRemoteProbe: RemoteProbeExecuting {
    private let factory: any SSHProcessFactory

    init(factory: any SSHProcessFactory) {
        self.factory = factory
    }

    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol) async -> RemoteProbeOutcome {
        let args = RemoteProbeCommand.arguments(
            profile: profile,
            remotePort: remotePort,
            protocol: `protocol`,
            urlString: CurlProxyProbe.verificationURL
        )
        let handle = factory.make(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
        do {
            try handle.start()
        } catch {
            return .unknown(reason: "无法启动远端探测 ssh：\(error.localizedDescription)")
        }
        // 取消 → 终止探测进程（不留孤儿 ssh）；等待循环对取消即时退出（不做忙等）
        return await withTaskCancellationHandler {
            // 脚本内部 --max-time 8 + ssh ConnectTimeout 10 → 上限 ~20s，轮询等待
            let deadline = Date().addingTimeInterval(20)
            while handle.isRunning && Date() < deadline {
                if Task.isCancelled {
                    handle.terminate()
                    return .unknown(reason: "远端探测已取消")
                }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    handle.terminate()
                    return .unknown(reason: "远端探测已取消")
                }
            }
            if handle.isRunning {
                handle.terminate()
                return .unknown(reason: "远端探测超时")
            }
            return Self.parse(
                exitCode: handle.exitCode ?? 255,
                stdout: handle.stdoutTail,
                stderr: handle.stderrTail
            )
        } onCancel: {
            handle.terminate()
        }
    }

    /// 解析（纯函数）：stdout 优先，exit 255 视为 SSH 层失败并按 stderr 细分。
    static func parse(exitCode: Int32, stdout: String, stderr: String) -> RemoteProbeOutcome {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(RemoteProbeCommand.noCurlMarker) {
            return .remoteCurlMissing
        }
        if exitCode == 255 {
            switch SSHErrorClassifier.classify(exitCode: exitCode, stderr: stderr) {
            case .authRequired(let detail):
                return .authRequired(detail: detail)
            case .error(let errorDetail):
                return .connectionFailure(reason: errorDetail.isEmpty ? "SSH 连接失败（exit 255）" : errorDetail)
            case .genericFailure(let code):
                return .connectionFailure(reason: "SSH 连接失败（exit \(code)）")
            }
        }
        guard let code = Int(trimmed), code > 0 else {
            return .unknown(reason: trimmed.isEmpty ? "远端无有效输出" : "远端输出无法解析：\(trimmed.prefix(80))")
        }
        if (200...399).contains(code) {
            return .verified(statusCode: code)
        }
        return .notProxy(statusCode: code)
    }
}
