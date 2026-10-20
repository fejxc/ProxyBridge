import Foundation

/// 远端端到端验证结论（经隧道在远端实测代理，02-TECHNICAL-DESIGN §7）。
enum RemoteProbeOutcome: Equatable, Sendable {
    /// 远端 curl 经 127.0.0.1:<port> 收到 2xx/3xx，或未认证 API 的预期 401。
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
    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol, password: String?) async -> RemoteProbeOutcome
    /// 带业务验证目标：必须是协议要求——曾经只是扩展重载，经 existential
    /// （`any RemoteProbeExecuting`）调用时静态派发到扩展默认实现，
    /// 导致业务探测目标在真实链路上被静默丢弃（集成测试抓到的生产 bug）。
    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol, password: String?, urlString: String?) async -> RemoteProbeOutcome
}

extension RemoteProbeExecuting {
    /// 默认实现：nil / 非法目标回落固定验证目标（替身无需单独实现）。
    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol, password: String?, urlString: String?) async -> RemoteProbeOutcome {
        await probe(profile: profile, remotePort: remotePort, protocol: `protocol`, password: password)
    }
}

/// 生产实现：一次性 `ssh` 执行受控远端脚本，收集 stdout/exit 后解析。
/// 与隧道进程完全独立（不写 -N 隧道的 stdin），并发由协调器加锁。
final class SSHRemoteProbe: RemoteProbeExecuting {
    private let factory: any SSHProcessFactory

    init(factory: any SSHProcessFactory) {
        self.factory = factory
    }

    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol, password: String? = nil) async -> RemoteProbeOutcome {
        await probe(profile: profile, remotePort: remotePort, protocol: `protocol`, password: password, urlString: nil)
    }

    /// 生产实现：业务目标经 ServerProfile.sanitizedProbeTarget 清洗，非法回落固定目标。
    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol, password: String?, urlString: String?) async -> RemoteProbeOutcome {
        let target = ServerProfile.sanitizedProbeTarget(urlString) ?? CurlProxyProbe.verificationURL
        let args = RemoteProbeCommand.arguments(
            profile: profile,
            remotePort: remotePort,
            protocol: `protocol`,
            urlString: target
        )
        let credential = password.flatMap { SSHAskpassCredential(password: $0) }
        let handle = factory.make(
            arguments: args,
            environment: SSHProcessLauncher.sshEnvironment(credential: credential)
        )
        do {
            try handle.start()
        } catch {
            credential?.destroy()
            return .unknown(reason: "无法启动远端探测 ssh：\(error.localizedDescription)")
        }
        return await withTaskCancellationHandler {
            defer { credential?.destroy() }
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
        if exitCode == 0 && trimmed == RemoteProbeCommand.noCurlMarker {
            return .remoteCurlMissing
        }
        if exitCode == 255 {
            switch SSHErrorClassifier.classify(exitCode: exitCode, stderr: stderr) {
            case .hostKeyUnknown(let detail), .authRequired(let detail):
                return .authRequired(detail: detail)
            case .error(let errorDetail):
                return .connectionFailure(reason: errorDetail.isEmpty ? "SSH 连接失败（exit 255）" : errorDetail)
            case .genericFailure(let code):
                return .connectionFailure(reason: "SSH 连接失败（exit \(code)）")
            }
        }
        guard exitCode == 0 else {
            // curl 自身的失败（超时/重置/TLS 等）：带上 stderr 首行让报障可定位
            let curlLine = stderr
                .components(separatedBy: .newlines)
                .first { $0.contains("curl:") }?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let suffix = curlLine.isEmpty ? "" : "：\(curlLine.prefix(120))"
            return .connectionFailure(reason: "远端代理请求失败（curl exit \(exitCode)）\(suffix)")
        }
        guard let code = Int(trimmed), (100...599).contains(code) else {
            return .unknown(reason: trimmed.isEmpty ? "远端无有效输出" : "远端输出无法解析：\(trimmed.prefix(80))")
        }
        // HTTP 401 is the expected response from the unauthenticated OpenAI
        // models endpoint and proves the HTTPS request traversed the proxy.
        if (200...399).contains(code) || code == 401 {
            return .verified(statusCode: code)
        }
        return .notProxy(statusCode: code)
    }
}

