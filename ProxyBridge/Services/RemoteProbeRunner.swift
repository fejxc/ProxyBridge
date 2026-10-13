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
    /// `password` 非空时经 PTY 应答远端 ssh 的密码提示（内存中临时使用，不落盘）。
    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol, password: String?) async -> RemoteProbeOutcome
}

/// 生产实现：一次性 `ssh` 执行受控远端脚本，收集 stdout/exit 后解析。
/// 与隧道进程完全独立（不写 -N 隧道的 stdin），并发由协调器加锁。
final class SSHRemoteProbe: RemoteProbeExecuting {
    private let factory: any SSHProcessFactory

    init(factory: any SSHProcessFactory) {
        self.factory = factory
    }

    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol, password: String? = nil) async -> RemoteProbeOutcome {
        let args = RemoteProbeCommand.arguments(
            profile: profile,
            remotePort: remotePort,
            protocol: `protocol`,
            urlString: CurlProxyProbe.verificationURL
        )
        let usePTY = password != nil
        let handle = usePTY
            ? factory.makePTY(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
            : factory.make(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
        do {
            try handle.start()
        } catch {
            return .unknown(reason: "无法启动远端探测 ssh：\(error.localizedDescription)")
        }
        return await withTaskCancellationHandler {
            // 密码模式：等待密码提示并应答（NumberOfPasswordPrompts=1，错密码立即失败）
            if usePTY {
                let promptDeadline = Date().addingTimeInterval(15)
                var sawPrompt = false
                while handle.isRunning && Date() < promptDeadline {
                    if SSHProcessLauncher.hasPasswordPrompt(handle.stderrTail) {
                        sawPrompt = true
                        break
                    }
                    do { try await Task.sleep(nanoseconds: 50_000_000) }
                    catch { handle.terminate(); return .unknown(reason: "远端探测已取消") }
                }
                guard sawPrompt else {
                    handle.terminate()
                    return .unknown(reason: handle.isRunning ? "远端探测超时（未见密码提示）" : "远端 ssh 未进入密码提示（主机密钥/网络问题？）")
                }
                guard let password, !password.isEmpty else {
                    handle.terminate()
                    return .unknown(reason: "密码模式缺少会话密码")
                }
                handle.writePTY(password + "\n")
            }
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
            case .authRequired(let detail):
                return .authRequired(detail: detail)
            case .error(let errorDetail):
                return .connectionFailure(reason: errorDetail.isEmpty ? "SSH 连接失败（exit 255）" : errorDetail)
            case .genericFailure(let code):
                return .connectionFailure(reason: "SSH 连接失败（exit \(code)）")
            }
        }
        guard exitCode == 0 else {
            return .connectionFailure(reason: "远端代理请求失败（curl exit \(exitCode)）")
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

// MARK: - Optional Linux HTTP-to-SOCKS5 adapter

enum RemoteHTTPAdapterStartResult {
    case started(RemoteHTTPAdapterSession)
    case notInstalled
    case portConflict
    case unavailable(String)
    case authRequired(String)
}

struct RemoteHTTPAdapterSession: Sendable {
    let token: String
    let handle: any SSHProcessHandle
}

enum RemoteHTTPAdapterCleanupResult: Equatable, Sendable {
    case stopped
    case unableToConfirm(String)
}

protocol RemoteHTTPAdapterManaging: AnyObject, Sendable {
    /// Creates a private per-session config under the SSH user's home directory,
    /// then starts Privoxy attached to an App-owned SSH process.
    func start(profile: ServerProfile, httpPort: Int, socksPort: Int, password: String?) async -> RemoteHTTPAdapterStartResult
    /// Stops only the recorded PID whose command line still references this
    /// session's exact config path, then removes only that session's files.
    func cleanup(profile: ServerProfile, session: RemoteHTTPAdapterSession, password: String?) async -> RemoteHTTPAdapterCleanupResult
}

enum RemoteHTTPAdapterCommands {
    static let missingMarker = "__PB_PRIV_NOT_INSTALLED__"
    static let portConflictMarker = "__PB_HTTP_PORT_IN_USE__"
    static let portCheckMarker = "__PB_PORT_CHECK_UNAVAILABLE__"
    static let configMarker = "__PB_PRIV_CONFIG_UNAVAILABLE__"
    static let preparedMarker = "__PB_PRIV_PREPARED__"
    static let startedMarker = "__PB_PRIV_STARTED__"
    static let cleanupMarker = "__PB_PRIV_CLEANED__"
    static let cleanupUnconfirmedMarker = "__PB_PRIV_CLEANUP_UNCONFIRMED__"

    static func prepare(httpPort: Int, socksPort: Int, token: String) -> String {
        precondition(validPort(httpPort) && validPort(socksPort) && validToken(token))
        return """
        set -eu
        if ! command -v privoxy >/dev/null 2>&1; then printf '%s\\n' '\(missingMarker)'; exit 41; fi
        if command -v ss >/dev/null 2>&1; then
          listeners=$(ss -ltn 2>/dev/null) || { printf '%s\\n' '\(portCheckMarker)'; exit 43; }
          if printf '%s\\n' "$listeners" | awk -v p=':\(httpPort)' 'substr($4,length($4)-length(p)+1)==p {f=1} END{exit f?0:1}'; then printf '%s\\n' '\(portConflictMarker)'; exit 42; fi
        elif command -v netstat >/dev/null 2>&1; then
          listeners=$(netstat -lnt 2>/dev/null) || { printf '%s\\n' '\(portCheckMarker)'; exit 43; }
          if printf '%s\\n' "$listeners" | awk -v p=':\(httpPort)' 'substr($4,length($4)-length(p)+1)==p {f=1} END{exit f?0:1}'; then printf '%s\\n' '\(portConflictMarker)'; exit 42; fi
        else
          printf '%s\\n' '\(portCheckMarker)'; exit 43
        fi
        confdir=''
        for candidate in /etc/privoxy /usr/local/etc/privoxy; do
          if [ -d "$candidate" ]; then confdir="$candidate"; break; fi
        done
        if [ -z "$confdir" ]; then printf '%s\\n' '\(configMarker)'; exit 44; fi
        umask 077
        root="$HOME/.cache/proxybridge"
        dir="$root/privoxy-\(token)"
        mkdir -p "$root" || exit 45
        if [ -e "$dir" ]; then printf '%s\\n' '\(configMarker)'; exit 46; fi
        mkdir "$dir" || exit 47
        cleanup_partial() {
          rm -f "$dir/config"
          rmdir "$dir" 2>/dev/null || true
        }
        trap cleanup_partial EXIT
        chmod 700 "$dir"
        printf 'confdir %s\\nlogdir /tmp\\nlisten-address 127.0.0.1:\(httpPort)\\nforward-socks5 / 127.0.0.1:\(socksPort) .\\ntoggle 1\\nenable-remote-toggle 0\\nenable-edit-actions 0\\n' "$confdir" > "$dir/config"
        chmod 600 "$dir/config"
        printf '%s\\n' '\(preparedMarker)'
        trap - EXIT
        """
    }

    static func launch(token: String) -> String {
        precondition(validToken(token))
        return """
        set -eu
        dir="$HOME/.cache/proxybridge/privoxy-\(token)"
        [ -f "$dir/config" ] || exit 51
        privoxy --no-daemon "$dir/config" > "$dir/privoxy.stdout" 2>&1 &
        pid=$!
        printf '%s\\n' "$pid" > "$dir/bridge.pid"
        printf '%s\\n' '\(startedMarker)'
        wait "$pid"
        """
    }

    static func cleanup(token: String) -> String {
        precondition(validToken(token))
        return """
        set -u
        dir="$HOME/.cache/proxybridge/privoxy-\(token)"
        unconfirmed=0
        process_args() {
          process_id="$1"
          if [ -d "/proc/$process_id" ]; then
            [ -r "/proc/$process_id/cmdline" ] || return 1
            tr '\\000' ' ' < "/proc/$process_id/cmdline"
          elif command -v ps >/dev/null 2>&1; then
            ps -ww -p "$process_id" -o args= 2>/dev/null || true
          else
            return 1
          fi
        }
        if [ -f "$dir/bridge.pid" ]; then
          pid=$(cat "$dir/bridge.pid" 2>/dev/null || true)
          case "$pid" in
            ''|*[!0-9]*) unconfirmed=1 ;;
            *)
              if ! args=$(process_args "$pid"); then printf '%s\\n' '\(cleanupUnconfirmedMarker)'; exit 52; fi
              case "$args" in
                *"$dir/config"*)
                  kill "$pid" 2>/dev/null || true
                  attempt=0
                  while [ "$attempt" -lt 20 ]; do
                    args=$(process_args "$pid" 2>/dev/null || true)
                    case "$args" in *"$dir/config"*) sleep 0.1 ;; *) break ;; esac
                    attempt=$((attempt+1))
                  done
                  args=$(process_args "$pid" 2>/dev/null || true)
                  case "$args" in *"$dir/config"*) unconfirmed=1 ;; esac
                  ;;
                *) [ -z "$args" ] || unconfirmed=1 ;;
              esac
              ;;
          esac
        elif [ -f "$dir/config" ]; then
          unconfirmed=1
        fi
        if [ "$unconfirmed" -eq 1 ]; then printf '%s\\n' '\(cleanupUnconfirmedMarker)'; exit 52; fi
        rm -f "$dir/config" "$dir/bridge.pid" "$dir/privoxy.stdout"
        rmdir "$dir" 2>/dev/null || true
        printf '%s\\n' '\(cleanupMarker)'
        """
    }

    static func validToken(_ token: String) -> Bool {
        token.count == 36 && token.allSatisfy { $0.isNumber || ("abcdef-".contains($0)) }
    }

    private static func validPort(_ port: Int) -> Bool { (1...65_535).contains(port) }
}

/// SSH-backed user-level Privoxy lifecycle. No sudo, package installation,
/// system config writes, process-name kills, or unverified HTTP claims.
final class SSHRemoteHTTPAdapterManager: RemoteHTTPAdapterManaging {
    private let factory: any SSHProcessFactory
    private let preparationTimeout: TimeInterval
    private let launchTimeout: TimeInterval

    init(factory: any SSHProcessFactory, preparationTimeout: TimeInterval = 20, launchTimeout: TimeInterval = 20) {
        self.factory = factory
        self.preparationTimeout = preparationTimeout
        self.launchTimeout = launchTimeout
    }

    func start(profile: ServerProfile, httpPort: Int, socksPort: Int, password: String?) async -> RemoteHTTPAdapterStartResult {
        guard (1...65_535).contains(httpPort), (1...65_535).contains(socksPort), httpPort != socksPort else {
            return .unavailable("HTTP/SOCKS5 端口配置无效或重复")
        }
        let token = UUID().uuidString.lowercased()
        let prepareCommand = RemoteHTTPAdapterCommands.prepare(httpPort: httpPort, socksPort: socksPort, token: token)
        guard let prepared = await runOneShot(profile: profile, command: prepareCommand, password: password, timeout: preparationTimeout) else {
            return .unavailable("无法完成 Linux Privoxy 检查（SSH 连接或远端命令超时）")
        }
        if prepared.stdout.contains(RemoteHTTPAdapterCommands.missingMarker) { return .notInstalled }
        if prepared.stdout.contains(RemoteHTTPAdapterCommands.portConflictMarker) { return .portConflict }
        if prepared.stdout.contains(RemoteHTTPAdapterCommands.portCheckMarker) {
            return .unavailable("远端缺少 ss/netstat，无法安全检查 HTTP 端口占用")
        }
        if prepared.stdout.contains(RemoteHTTPAdapterCommands.configMarker) {
            return .unavailable("未找到 Privoxy 配置目录，或本次会话目录已存在；未覆盖任何现有配置")
        }
        guard prepared.exitCode == 0, prepared.stdout.contains(RemoteHTTPAdapterCommands.preparedMarker) else {
            return classifyFailure(exitCode: prepared.exitCode, stderr: prepared.stderr)
        }

        let command = RemoteHTTPAdapterCommands.launch(token: token)
        let args = SSHCommandBuilder.remoteCommandArguments(profile: profile, command: command)
        let usePTY = profile.authMode == .password
        let handle = usePTY
            ? factory.makePTY(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
            : factory.make(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
        do {
            try handle.start()
        } catch {
            _ = await runOneShot(profile: profile, command: RemoteHTTPAdapterCommands.cleanup(token: token), password: password, timeout: preparationTimeout)
            return .unavailable("无法启动 Privoxy 管理 SSH：\(LogRedaction.sanitize(error.localizedDescription))")
        }
        guard await answerPasswordIfNeeded(
            handle,
            password: password,
            required: profile.authMode == .password,
            timeout: launchTimeout
        ) else {
            handle.terminate()
            _ = await runOneShot(profile: profile, command: RemoteHTTPAdapterCommands.cleanup(token: token), password: password, timeout: preparationTimeout)
            return classifyFailure(exitCode: handle.exitCode ?? 255, stderr: handle.stderrTail)
        }

        let deadline = Date().addingTimeInterval(launchTimeout)
        while Date() < deadline {
            if handle.stdoutTail.contains(RemoteHTTPAdapterCommands.startedMarker) {
                // Give Privoxy a brief startup window; the coordinator still
                // performs a real HTTP CONNECT request before reporting ready.
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard handle.isRunning else {
                    let detail = "Privoxy 启动后立即退出：\(LogRedaction.sanitize(handle.stderrTail))"
                    _ = await runOneShot(profile: profile, command: RemoteHTTPAdapterCommands.cleanup(token: token), password: password, timeout: preparationTimeout)
                    return .unavailable(detail)
                }
                return .started(RemoteHTTPAdapterSession(token: token, handle: handle))
            }
            guard handle.isRunning else {
                let failure = classifyFailure(exitCode: handle.exitCode ?? 255, stderr: handle.stderrTail)
                _ = await runOneShot(profile: profile, command: RemoteHTTPAdapterCommands.cleanup(token: token), password: password, timeout: preparationTimeout)
                return failure
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        handle.terminate()
        _ = await runOneShot(profile: profile, command: RemoteHTTPAdapterCommands.cleanup(token: token), password: password, timeout: preparationTimeout)
        return .unavailable("未收到 Privoxy 启动确认，已停止本次管理连接")
    }

    func cleanup(profile: ServerProfile, session: RemoteHTTPAdapterSession, password: String?) async -> RemoteHTTPAdapterCleanupResult {
        session.handle.terminate()
        guard let result = await runOneShot(
            profile: profile,
            command: RemoteHTTPAdapterCommands.cleanup(token: session.token),
            password: password,
            timeout: preparationTimeout
        ) else {
            return .unableToConfirm("SSH 不可达，无法确认 Privoxy 已停止；其进程由本次 SSH 管理会话运行")
        }
        guard result.exitCode == 0, result.stdout.contains(RemoteHTTPAdapterCommands.cleanupMarker) else {
            return .unableToConfirm("远端未能确认清理状态；请检查本次 ProxyBridge Privoxy 会话目录")
        }
        return .stopped
    }

    private struct CommandResult {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    private func runOneShot(profile: ServerProfile, command: String, password: String?, timeout: TimeInterval) async -> CommandResult? {
        let args = SSHCommandBuilder.remoteCommandArguments(profile: profile, command: command)
        let usePTY = profile.authMode == .password
        let handle = usePTY
            ? factory.makePTY(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
            : factory.make(arguments: args, environment: SSHProcessLauncher.sshEnvironment())
        do { try handle.start() } catch { return nil }
        return await withTaskCancellationHandler {
            guard await answerPasswordIfNeeded(
                handle,
                password: password,
                required: profile.authMode == .password,
                timeout: min(timeout, 20)
            ) else {
                handle.terminate()
                return CommandResult(exitCode: handle.exitCode ?? 255, stdout: handle.stdoutTail, stderr: handle.stderrTail)
            }
            let deadline = Date().addingTimeInterval(timeout)
            while handle.isRunning && Date() < deadline {
                if Task.isCancelled { handle.terminate(); return nil }
                do { try await Task.sleep(nanoseconds: 50_000_000) }
                catch { handle.terminate(); return nil }
            }
            if handle.isRunning { handle.terminate(); return nil }
            return CommandResult(exitCode: handle.exitCode ?? 255, stdout: handle.stdoutTail, stderr: handle.stderrTail)
        } onCancel: {
            handle.terminate()
        }
    }

    private func answerPasswordIfNeeded(
        _ handle: any SSHProcessHandle,
        password: String?,
        required: Bool,
        timeout: TimeInterval
    ) async -> Bool {
        guard required else { return true }
        guard let password, !password.isEmpty else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if SSHProcessLauncher.hasPasswordPrompt(handle.stderrTail) {
                handle.writePTY(password + "\n")
                return true
            }
            if !handle.isRunning { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func classifyFailure(exitCode: Int32, stderr: String) -> RemoteHTTPAdapterStartResult {
        switch SSHErrorClassifier.classify(exitCode: exitCode, stderr: stderr) {
        case .authRequired(let detail): return .authRequired(detail)
        case .error(let detail): return .unavailable(detail)
        case .genericFailure(let code): return .unavailable("SSH 命令失败（exit \(code)）：\(LogRedaction.sanitize(stderr))")
        }
    }
}
