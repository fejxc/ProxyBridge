import Foundation

// MARK: - 远端端口残留检测与清理（RemoteJanitor）
//
// 场景：隧道非正常死亡（断网/休眠）后，远端 sshd 仍占着转发端口、孤儿 Privoxy 仍占着
// HTTP 入口，导致重连绑定失败。此前只能靠用户手动登录服务器 kill。
// 原则：只读诊断随时可做；清理仅限两类「自家资源」——同用户、无客户端连接的 sshd 僵尸
// 与带 ProxyBridge 配置目录（privoxy-<token>）的孤儿 Privoxy；别人的进程只报告，绝不触碰。

/// 一个远端端口的持有者。
struct RemotePortHolding: Equatable, Identifiable, Sendable {
    /// socket 状态（/proc/net/tcp 的 st 列，十六进制）：0A=LISTEN、0C=CLOSE_WAIT、
    /// 01=ESTABLISHED、06=TIME_WAIT…。v1.5.1 起全状态扫描——绑定被拒的阻塞者
    /// 往往不是 LISTEN socket 而是卡在 CLOSE_WAIT 的旧转发连接，只认 0A 会误报
    /// 「占用已消失」。
    var port: Int
    var pid: Int
    /// 进程名（/proc/<pid>/comm）；TIME_WAIT 为内核持有，pid=0、comm=kernel。
    var comm: String
    /// 该进程是否存在 ESTABLISHED socket（活连接 → 不得清理）。
    var established: Bool
    /// 命令行（截断）。
    var cmdline: String
    /// socket 状态（/proc/net/tcp 的 st 列，十六进制）：0A=LISTEN、0C=CLOSE_WAIT、
    /// 01=ESTABLISHED、06=TIME_WAIT…。v1.5.1 起全状态扫描——阻塞 sshd 重绑的往往
    /// 不是 LISTEN socket 而是卡在 CLOSE_WAIT 的旧转发连接，只认 0A 会误报
    /// 「占用已消失」。
    var state: String = "0A"

    var id: String { "\(port)-\(pid)-\(state)" }

    enum Kind: Equatable, Sendable {
        /// 同用户 sshd 会话、无任何活连接 → 上次隧道残留，可清理。
        case staleSSHD
        /// 带本 App 配置目录的 Privoxy → 本 App 创建的孤儿实例，可清理。
        case ownedPrivoxy
        /// 有活连接的持有者（含正在服务的会话）→ 不清理。
        case busy
        /// 内核持有的 TIME_WAIT 残留（无进程可清理，约 60s 自过期）。
        case residual
        /// 其他进程（用户手动服务、他人会话）→ 只报告，不清理。
        case thirdParty

        var isCleanable: Bool {
            switch self {
            case .staleSSHD, .ownedPrivoxy: return true
            case .residual, .busy, .thirdParty: return false
            }
        }
    }

    /// 分类（纯函数）：内核残留优先，其次活连接——宁可不清，不可误杀。
    var kind: Kind {
        if state == "06" || pid == 0 { return .residual }
        if established { return .busy }
        if comm.contains("sshd") { return .staleSSHD }
        if cmdline.contains("/.cache/proxybridge/privoxy-") { return .ownedPrivoxy }
        return .thirdParty
    }
}

/// 清理结论。
struct RemoteCleanOutcome: Equatable, Sendable {
    /// 已成功释放的端口。
    var freedPorts: [Int]
    /// 仍被占用的端口。
    var stillHeldPorts: [Int]
    var allFreed: Bool { stillHeldPorts.isEmpty }
}

/// 远端残留清理抽象（测试注入）。
@MainActor
protocol RemoteJanitorProviding: AnyObject {
    /// 只读诊断：返回各端口的持有者（网络/SSH 失败返回 nil，如实不猜测）。
    func inspect(profile: ServerProfile, ports: [Int], password: String?) async -> [RemotePortHolding]?
    /// 清理指定持有者（调用方须只传 kind.isCleanable 的对象），随后复查端口释放情况。
    func clean(profile: ServerProfile, targets: [RemotePortHolding], password: String?) async -> RemoteCleanOutcome?
}

/// 生产实现：一次性 ssh 执行受控 POSIX sh 脚本（与探测命令同装配、同认证语义）。
@MainActor
final class SSHRemoteJanitor: RemoteJanitorProviding {
    private let factory: any SSHProcessFactory

    init(factory: any SSHProcessFactory) {
        self.factory = factory
    }

    func inspect(profile: ServerProfile, ports: [Int], password: String?) async -> [RemotePortHolding]? {
        let validPorts = ports.filter { (1...65_535).contains($0) }
        guard !validPorts.isEmpty else { return [] }
        let output = await run(profile: profile, password: password,
                               script: RemoteJanitorScript.inspectScript(ports: validPorts),
                               timeout: 25)
        guard let output else { return nil }
        return RemoteJanitorScript.parseInspect(output.stdout)
    }

    func clean(profile: ServerProfile, targets: [RemotePortHolding], password: String?) async -> RemoteCleanOutcome? {
        // 防御：只允许数字 PID 的可清理对象（调用方已过滤，这里再兜底）
        let safe = targets.filter { $0.kind.isCleanable && $0.pid > 1 }
        guard !safe.isEmpty else { return RemoteCleanOutcome(freedPorts: [], stillHeldPorts: []) }
        let ports = Array(Set(safe.map(\.port))).filter { (1...65_535).contains($0) }
        let output = await run(profile: profile, password: password,
                               script: RemoteJanitorScript.cleanScript(pids: safe.map(\.pid), ports: ports),
                               timeout: 25)
        guard let output else { return nil }
        return RemoteJanitorScript.parseClean(output.stdout)
    }

    // MARK: - 一次性 ssh 执行（与 SSHRemoteProbe 相同的认证与超时模式）

    private struct RunResult {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    private func run(profile: ServerProfile, password: String?, script: String, timeout: TimeInterval) async -> RunResult? {
        let args = RemoteJanitorScript.arguments(profile: profile, script: script)
        let credential = password.flatMap { SSHAskpassCredential(password: $0) }
        let handle = factory.make(
            arguments: args,
            environment: SSHProcessLauncher.sshEnvironment(credential: credential)
        )
        do {
            try handle.start()
        } catch {
            credential?.destroy()
            return nil
        }
        return await withTaskCancellationHandler {
            defer { credential?.destroy() }
            let deadline = Date().addingTimeInterval(timeout)
            while handle.isRunning && Date() < deadline {
                if Task.isCancelled {
                    handle.terminate()
                    return nil
                }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    handle.terminate()
                    return nil
                }
            }
            if handle.isRunning {
                handle.terminate()
                return nil
            }
            return RunResult(stdout: handle.stdoutTail, stderr: handle.stderrTail, exitCode: handle.exitCode ?? 255)
        } onCancel: {
            handle.terminate()
        }
    }
}

// MARK: - 脚本构建与解析（纯函数，测试覆盖）

/// 远端脚本：零依赖（不依赖 ss/netstat/lsof——容器环境常缺），直接读 /proc。
enum RemoteJanitorScript {
    static let marker = "PBJANITOR"

    /// 诊断：对每个端口输出一行 `PBJANITOR|<port>|<pid>|<comm>|<est 0/1>|<cmdline>|<state>`。
    /// 扫描本地端口的所有 TCP 状态；TIME_WAIT 无进程，仅聚合报告一次。
    static func inspectScript(ports: [Int]) -> String {
        let portList = ports.map(String.init).joined(separator: " ")
        return """
        for port in \(portList); do
          hex=$(printf '%04X' "$port")
          timewait=0
          for entry in $(awk -v p=":$hex" '$2 ~ p"$" {print $10 ":" $4}' /proc/net/tcp /proc/net/tcp6 2>/dev/null); do
            ino=${entry%:*}
            state=${entry##*:}
            if [ "$state" = "06" ]; then timewait=$((timewait + 1)); continue; fi
            [ "$ino" != "0" ] || continue
            for d in /proc/[0-9]*; do
              ls -l "$d/fd" 2>/dev/null | grep -F "socket:[$ino]" >/dev/null || continue
              pid=${d#/proc/}
              comm=$(cat "$d/comm" 2>/dev/null)
              est=0
              for fdino in $(ls -l "$d/fd" 2>/dev/null | sed -n 's/.*socket:\\[\\([0-9]*\\)\\].*/\\1/p'); do
                if awk -v i="$fdino" '$10==i && $4=="01" {f=1} END{exit !f}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then est=1; break; fi
              done
              cmd=$(tr '\\0' ' ' < "$d/cmdline" 2>/dev/null | tr '|' '/' | cut -c1-160)
              printf '\(marker)|%s|%s|%s|%s|%s|%s\\n' "$port" "$pid" "$comm" "$est" "$cmd" "$state"
            done
          done
          if [ "$timewait" -gt 0 ]; then
            printf '\(marker)|%s|0|kernel|0|TIME_WAIT×%s|06\\n' "$port" "$timewait"
          fi
        done
        """
    }

    /// 清理：kill 指定 PID（仅 TERM，通常足够释放端口），sleep 后复查端口并输出
    /// `PBJANITOR|FREED|<port>` / `PBJANITOR|STILL|<port>`。
    static func cleanScript(pids: [Int], ports: [Int]) -> String {
        let pidList = pids.map(String.init).joined(separator: " ")
        let portList = ports.map(String.init).joined(separator: " ")
        return """
        for pid in \(pidList); do
          kill "$pid" 2>/dev/null || true
        done
        sleep 1
        for port in \(portList); do
          hex=$(printf '%04X' "$port")
          if awk -v p=":$hex" '$2 ~ p"$" {f=1} END{exit !f}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
            printf '\(marker)|STILL|%s\\n' "$port"
          else
            printf '\(marker)|FREED|%s\\n' "$port"
          fi
        done
        """
    }

    /// ssh 参数：与远端探测同装配（StrictHostKeyChecking=yes、同一身份来源、密码模式单次提示）。
    static func arguments(profile: ServerProfile, script: String) -> [String] {
        precondition((1...65_535).contains(profile.sshPort), "sshPort 必须在 1–65535")
        var args = [
            "-p", String(profile.sshPort),
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10",
        ]
        if profile.authMode == .password {
            args += [
                "-o", "PubkeyAuthentication=no",
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "NumberOfPasswordPrompts=1",
            ]
        } else {
            args += ["-o", "BatchMode=yes"]
        }
        if profile.authMode == .identityFile,
           let path = profile.identityFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            args += ["-i", path]
        }
        args.append(SSHCommandBuilder.destination(profile: profile))
        args.append(script)
        return args
    }

    /// 解析诊断输出：非标记行忽略（cmdline 中 '|' 已在脚本侧替换为 '/'，剩余按段重组）。
    /// 兼容 6 列（无状态列，默认 LISTEN）；同端口同进程多行时 LISTEN 行优先。
    static func parseInspect(_ stdout: String) -> [RemotePortHolding] {
        var holdings: [RemotePortHolding] = []
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6, parts[0] == marker,
                  let port = Int(parts[1]), let pid = Int(parts[2]) else { continue }
            // 7 列新格式：…|cmdline|state；6 列旧格式：cmdline 即末列（默认 LISTEN）
            let (cmdline, state) = parts.count >= 7
                ? (parts[5..<parts.count - 1].joined(separator: "|"), parts[parts.count - 1])
                : (parts[5], "0A")
            let holding = RemotePortHolding(
                port: port,
                pid: pid,
                comm: parts[3],
                established: parts[4] == "1",
                cmdline: cmdline,
                state: state
            )
            if let idx = holdings.firstIndex(where: { $0.port == port && $0.pid == pid }) {
                if holdings[idx].state != "0A" && state == "0A" { holdings[idx] = holding } // LISTEN 行优先
                continue
            }
            holdings.append(holding)
        }
        return holdings
    }

    /// 解析清理输出。
    static func parseClean(_ stdout: String) -> RemoteCleanOutcome {
        var freed: [Int] = []
        var still: [Int] = []
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count == 3, parts[0] == marker, let port = Int(parts[2]) else { continue }
            if parts[1] == "FREED" { freed.append(port) } else if parts[1] == "STILL" { still.append(port) }
        }
        return RemoteCleanOutcome(freedPorts: freed, stillHeldPorts: still)
    }
}
