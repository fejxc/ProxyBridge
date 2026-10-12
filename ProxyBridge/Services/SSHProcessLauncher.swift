import Foundation
import Darwin

/// 一个可等待退出的 SSH 进程句柄抽象（测试注入 fake / 生产 Foundation.Process）。
/// Sendable：句柄需跨隔离域（ detached Task 中 SIGKILL 升级）使用；实现均为锁保护/不可变。
protocol SSHProcessHandle: AnyObject, Sendable {
    /// 进程退出回调（任意线程触发；实现方保证只回调一次）。
    var onExit: (@Sendable (Int32) -> Void)? { get set }
    /// PTY 输出回调（仅密码模式的 PTY 句柄会产生；普通管道句柄不回调）。
    var onPTYOutput: (@Sendable (String) -> Void)? { get set }
    func start() throws
    /// 优雅终止（SIGTERM）。
    func terminate()
    /// 强制终止（SIGKILL）。
    func forceTerminate()
    var isRunning: Bool { get }
    /// nil = 仍在运行。
    var exitCode: Int32? { get }
    /// 最近 stderr（尾部截断，线程安全快照；PTY 模式含合并的 stdout+stderr）。
    var stderrTail: String { get }
    /// 最近 stdout（远端探测用；-N 隧道通常为空）。
    var stdoutTail: String { get }
    /// 向 PTY 写入（密码模式应答提示用）。普通管道句柄为 no-op。
    func writePTY(_ text: String)
}

/// 进程工厂抽象。
protocol SSHProcessFactory: AnyObject, Sendable {
    func make(arguments: [String], environment: [String: String]) -> SSHProcessHandle
    /// 创建挂在 PTY 上的句柄（密码模式：ssh 的密码提示需要 TTY 才会出现）。
    /// 默认实现退化为普通句柄（测试替身无需真 PTY）。
    func makePTY(arguments: [String], environment: [String: String]) -> SSHProcessHandle
}

extension SSHProcessFactory {
    func makePTY(arguments: [String], environment: [String: String]) -> SSHProcessHandle {
        make(arguments: arguments, environment: environment)
    }
}

/// 生产实现：直启 `/usr/bin/ssh`（参数数组，不经 shell）。
final class FoundationSSHProcessFactory: SSHProcessFactory {
    init() {}

    func make(arguments: [String], environment: [String: String]) -> SSHProcessHandle {
        FoundationSSHProcessHandle(arguments: arguments, environment: environment)
    }

    func makePTY(arguments: [String], environment: [String: String]) -> SSHProcessHandle {
        FoundationSSHProcessHandle(arguments: arguments, environment: environment, usesPTY: true)
    }
}

/// ssh 子进程环境：只透传认证与解析所需变量，杜绝其他继承。
/// - HOME：known_hosts / ~/.ssh/config 定位
/// - SSH_AUTH_SOCK：ssh-agent 认证（缺失时 agent 模式认证失败并分类提示）
/// - PATH：ssh 自身解析辅助程序
enum SSHProcessLauncher {
    static let ptyChildArgument = "--proxybridge-ssh-pty-child"

    /// Invoked before starting SwiftUI in the freshly spawned session. execv
    /// retains the PID, so terminate/kill always target the owned SSH process.
    static func runPTYChildIfRequested() {
        guard CommandLine.arguments.dropFirst().first == ptyChildArgument else { return }
        guard ioctl(STDIN_FILENO, TIOCSCTTY, 0) == 0 else { _exit(126) }
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard let executable = arguments.first else { _exit(127) }
        let argv = arguments.map { strdup($0)! } + [nil]
        argv.withUnsafeBufferPointer {
            _ = execv(executable, UnsafeMutablePointer(mutating: $0.baseAddress!))
        }
        _exit(127)
    }

    /// Match only a complete final prompt, not auth-method/debug/error text.
    static func hasPasswordPrompt(_ output: String) -> Bool {
        let line = output.components(separatedBy: .newlines).last?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return line.hasSuffix("password:") && !line.contains("permission denied")
            && !line.hasPrefix("debug")
    }

    static func sshEnvironment() -> [String: String] {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            env["SSH_AUTH_SOCK"] = sock
        }
        return env
    }
}

/// Foundation.Process 句柄。线程安全：状态经 NSLock 保护，退出回调只发一次。
/// `usesPTY = true` 时：新 session + 控制 PTY 提供 stdin/stderr 和密码提示；
/// stdout 独立收集；`writePTY` 应答密码，密码不经 argv/环境变量。
final class FoundationSSHProcessHandle: SSHProcessHandle, @unchecked Sendable {
    var onExit: (@Sendable (Int32) -> Void)?
    var onPTYOutput: (@Sendable (String) -> Void)?

    private let process = Process()
    private let lock = NSLock()
    private var stderrData = Data()
    private var stdoutData = Data()
    private var fired = false
    private let stderrLimit = 16 * 1024
    private let stdoutLimit = 8 * 1024
    private let stderrPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let usesPTY: Bool
    private var ptyMasterFD: Int32 = -1
    private var ptyPID: pid_t = -1
    private var ptyExitCode: Int32?
    private var ptyReaped = false

    init(
        arguments: [String],
        environment: [String: String],
        executableURL: URL = SSHCommandBuilder.executableURL,
        usesPTY: Bool = false
    ) {
        self.usesPTY = usesPTY
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        if usesPTY {
            // PTY 模式在 start() 中装配（需要 openpty 的 fd）
            return
        }
        // stdin 立即 EOF：-N 隧道不需要 stdin，杜绝任何交互挂起
        let stdin = Pipe()
        stdin.fileHandleForWriting.closeFile()
        process.standardInput = stdin
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usesPTY ? ptyPID > 0 && ptyExitCode == nil : process.isRunning
    }

    var exitCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        if usesPTY { return ptyExitCode }
        return process.isRunning ? nil : process.terminationStatus
    }

    var stderrTail: String {
        tail(of: \.stderrData, limit: stderrLimit)
    }

    var stdoutTail: String {
        tail(of: \.stdoutData, limit: stdoutLimit)
    }

    private func tail(of keyPath: ReferenceWritableKeyPath<FoundationSSHProcessHandle, Data>, limit: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let data = self[keyPath: keyPath]
        let limited = data.count > limit ? data.suffix(limit) : data
        return String(decoding: limited, as: UTF8.self)
    }

    func start() throws {
        if usesPTY {
            try startPTY()
            return
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data, to: \.stderrData)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data, to: \.stdoutData)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            // 先停掉异步读取，再【同步排空】管道中尚在缓冲的末段数据。
            // 若直接触发 onExit，进程退出前最后写入的 stderr（恰是分类关键特征）
            // 会被永久丢弃，导致分类间歇性退化为 genericFailure。
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            let restErr = self.stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let restOut = self.stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !restErr.isEmpty { self.append(restErr, to: \.stderrData) }
            if !restOut.isEmpty { self.append(restOut, to: \.stdoutData) }
            let code = process.terminationStatus
            if self.markExited() {
                self.onExit?(code)
            }
        }
        try process.run()
    }

    /// Spawn a fresh session, then acquire the PTY with TIOCSCTTY in the child.
    /// Merely attaching PTY descriptors does not provide a controlling /dev/tty.
    private func startPTY() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var spawned = false
        defer {
            close(slave)
            if !spawned { close(master) }
        }
        // Never allow an input echo to put a password into captured output.
        var settings = termios()
        guard tcgetattr(slave, &settings) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        settings.c_lflag &= ~tcflag_t(ECHO | ECHONL)
        guard tcsetattr(slave, TCSANOW, &settings) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)

        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        try checkSpawn(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checkSpawn(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checkSpawn(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)))
        // The child entry point explicitly acquires the opened slave as ctty.
        try checkSpawn(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, name, O_RDWR, 0))
        try checkSpawn(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO))
        // Keep remote command stdout separate from prompts and diagnostics.
        try checkSpawn(posix_spawn_file_actions_adddup2(&actions, stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try checkSpawn(posix_spawn_file_actions_addclose(&actions, master))
        try checkSpawn(posix_spawn_file_actions_addclose(&actions, slave))
        let launcher = Bundle.main.executableURL!.path
        let argv = ([launcher, SSHProcessLauncher.ptyChildArgument, process.executableURL!.path] + (process.arguments ?? [])).map { strdup($0)! }
        let envp = (process.environment ?? [:]).map { strdup("\($0.key)=\($0.value)")! }
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = -1
        let result = (argv.map(Optional.some) + [nil]).withUnsafeBufferPointer { args in
            (envp.map(Optional.some) + [nil]).withUnsafeBufferPointer { env in
                posix_spawn(&pid, launcher, &actions, &attributes,
                            UnsafeMutablePointer(mutating: args.baseAddress!),
                            UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        spawned = true
        stdoutPipe.fileHandleForWriting.closeFile()
        lock.lock()
        ptyMasterFD = master
        ptyPID = pid
        lock.unlock()

        let stdoutDone = DispatchGroup()
        stdoutDone.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            var bytes = [UInt8](repeating: 0, count: 4096)
            let fd = stdoutPipe.fileHandleForReading.fileDescriptor
            while true {
                let count = Darwin.read(fd, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                append(Data(bytes.prefix(count)), to: \.stdoutData)
            }
            stdoutDone.leave()
        }
        DispatchQueue.global(qos: .utility).async { [self, master, pid] in
            // Read through EOF/EIO BEFORE publishing exit; otherwise the final
            // permission-denied diagnostic can be lost by closing the master.
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(master, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                let data = Data(bytes.prefix(count))
                append(data, to: \.stderrData)
                onPTYOutput?(String(decoding: data, as: UTF8.self))
            }
            var status: Int32 = 0
            // Reap and mark under the same lock used by kill: never signal a
            // PID that has already been returned to the system for reuse.
            while true {
                lock.lock()
                let result = waitpid(pid, &status, WNOHANG)
                let finished = result == pid || (result < 0 && errno != EINTR)
                if finished { ptyReaped = true }
                lock.unlock()
                if finished { break }
                usleep(10_000)
            }
            stdoutDone.wait()
            let signal = status & 0x7f
            let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            lock.lock()
            ptyExitCode = code
            lock.unlock()
            closePTYMaster()
            if markExited() { onExit?(code) }
        }
    }

    private func checkSpawn(_ result: Int32) throws {
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }

    func writePTY(_ text: String) {
        // Serialize write/close so a reused descriptor can never receive input.
        lock.lock()
        defer { lock.unlock() }
        guard ptyMasterFD >= 0 else { return }
        var settings = termios()
        guard tcgetattr(ptyMasterFD, &settings) == 0,
              settings.c_lflag & tcflag_t(ECHO | ECHONL) == 0 else { return }
        let data = Data(text.utf8)
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(ptyMasterFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    private func closePTYMaster() {
        lock.lock()
        defer { lock.unlock() }
        if ptyMasterFD >= 0 { close(ptyMasterFD) }
        ptyMasterFD = -1
    }

    private func append(_ data: Data, to keyPath: ReferenceWritableKeyPath<FoundationSSHProcessHandle, Data>) {
        lock.lock()
        var buffer = self[keyPath: keyPath]
        buffer.append(data)
        let limit = keyPath == \.stderrData ? stderrLimit : stdoutLimit
        self[keyPath: keyPath] = Data(buffer.suffix(limit))
        lock.unlock()
    }

    private func markExited() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }

    deinit {
        if usesPTY {
            closePTYMaster()
        }
    }

    func terminate() {
        lock.lock()
        if usesPTY {
            if ptyPID > 0 && !ptyReaped { kill(ptyPID, SIGTERM) }
            lock.unlock()
            return
        }
        let running = process.isRunning
        lock.unlock()
        if running { process.terminate() } // SIGTERM
    }

    func forceTerminate() {
        lock.lock()
        if usesPTY {
            if ptyPID > 0 && !ptyReaped { kill(ptyPID, SIGKILL) }
            lock.unlock()
            return
        }
        let pid = process.processIdentifier
        let running = process.isRunning
        lock.unlock()
        if running && pid > 0 {
            kill(pid, SIGKILL) // 仅作用于本 App 拥有的这一个 PID
        }
    }
}
