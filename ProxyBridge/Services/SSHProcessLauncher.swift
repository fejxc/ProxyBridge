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
/// `usesPTY = true` 时（密码模式）：stdin/stdout/stderr 挂到 openpty 的从端，
/// 输出经主端回调，`writePTY` 向主端写入（应答密码提示；密码不经 argv/环境变量）。
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
    private var ptySlaveFD: Int32 = -1
    private var ptyMasterHandle: FileHandle?

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
        return process.isRunning
    }

    var exitCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return process.isRunning ? nil : process.terminationStatus
    }

    var stderrTail: String {
        tail(of: stderrData, limit: stderrLimit)
    }

    var stdoutTail: String {
        tail(of: stdoutData, limit: stdoutLimit)
    }

    private func tail(of data: Data, limit: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let limited = data.count > limit ? data.suffix(limit) : data
        return String(decoding: limited, as: UTF8.self)
    }

    func start() throws {
        if usesPTY {
            var master: Int32 = -1
            var slave: Int32 = -1
            guard openpty(&master, &slave, nil, nil, nil) == 0 else {
                throw NSError(domain: "ProxyBridge.ssh", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "无法创建 PTY（openpty 失败）"])
            }
            lock.lock()
            ptyMasterFD = master
            ptySlaveFD = slave
            lock.unlock()
            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            process.standardInput = slaveHandle
            process.standardOutput = slaveHandle
            process.standardError = slaveHandle

            try process.run()
            // 父侧关闭从端副本（子进程持有自己的副本），主端用于读写
            close(slave)
            lock.lock()
            ptySlaveFD = -1
            let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: false)
            ptyMasterHandle = masterHandle
            lock.unlock()
            masterHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                guard let self else { return }
                self.append(data, to: \.stderrData) // PTY 合并输出进 stderr 缓冲（供分类与提示检测）
                let chunk = String(decoding: data, as: UTF8.self)
                self.onPTYOutput?(chunk)
            }
            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                self.closePTYMaster()
                let code = process.terminationStatus
                if self.markExited() {
                    self.onExit?(code)
                }
            }
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

    func writePTY(_ text: String) {
        lock.lock()
        let handle = ptyMasterHandle
        lock.unlock()
        guard let handle else { return }
        handle.write(Data(text.utf8))
    }

    private func closePTYMaster() {
        lock.lock()
        let fd = ptyMasterFD
        ptyMasterFD = -1
        let handle = ptyMasterHandle
        ptyMasterHandle = nil
        lock.unlock()
        handle?.readabilityHandler = nil
        if fd >= 0 { close(fd) }
    }

    private func append(_ data: Data, to keyPath: ReferenceWritableKeyPath<FoundationSSHProcessHandle, Data>) {
        lock.lock()
        var buffer = self[keyPath: keyPath]
        buffer.append(data)
        self[keyPath: keyPath] = buffer
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
        let running = process.isRunning
        lock.unlock()
        if running { process.terminate() } // SIGTERM
    }

    func forceTerminate() {
        lock.lock()
        let pid = process.processIdentifier
        let running = process.isRunning
        lock.unlock()
        if running && pid > 0 {
            kill(pid, SIGKILL) // 仅作用于本 App 拥有的这一个 PID
        }
    }
}
