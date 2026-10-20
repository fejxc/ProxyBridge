// 冒烟测试专用替身（不入 .xcodeproj）：最小可用的进程句柄/工厂/远端探测替身，
// 供 SmokeMain 以生产 SSHTunnelCoordinator 跑真实状态机序列（S34）。

import Foundation

final class SmokeSSHHandle: SSHProcessHandle, @unchecked Sendable {
    var onExit: (@Sendable (Int32) -> Void)?
    var startError: Error?
    var autoExitNanoseconds: UInt64 = 0
    var autoExitCode: Int32 = 0
    var stderrText = ""

    private let lock = NSLock()
    private var running = false
    private var code: Int32?
    private var fired = false
    private(set) var started = false
    private(set) var terminated = false

    func start() throws {
        if let startError { throw startError }
        lock.lock()
        started = true
        running = true
        lock.unlock()
        if autoExitNanoseconds > 0 {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.autoExitNanoseconds ?? 0)
                self?.finish(self?.autoExitCode ?? 0)
            }
        }
    }

    func finish(_ exitCode: Int32) {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        running = false
        code = exitCode
        let cb = onExit
        lock.unlock()
        cb?(exitCode)
    }

    func terminate() {
        lock.lock()
        terminated = true
        let wasRunning = running
        lock.unlock()
        if wasRunning { finish(15) }
    }

    func forceTerminate() { terminate() }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var exitCode: Int32? { lock.lock(); defer { lock.unlock() }; return code }
    var stderrTail: String { lock.lock(); defer { lock.unlock() }; return stderrText }
    var stdoutTail: String { "" }
}

final class SmokeSSHFactory: SSHProcessFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [SmokeSSHHandle] = []
    private(set) var handles: [SmokeSSHHandle] = []
    private(set) var lastArguments: [String] = []
    private(set) var lastEnvironment: [String: String] = [:]

    func enqueue(_ h: SmokeSSHHandle) {
        lock.lock(); pending.append(h); lock.unlock()
    }

    func make(arguments: [String], environment: [String: String]) -> SSHProcessHandle {
        lock.lock()
        lastArguments = arguments
        lastEnvironment = environment
        let h = pending.isEmpty ? SmokeSSHHandle() : pending.removeFirst()
        handles.append(h)
        lock.unlock()
        return h
    }
}

final class SmokeLocalProber: ProxyProbeExecuting, @unchecked Sendable {
    var outcome: ProbeOutcome
    private(set) var callCount = 0
    init(outcome: ProbeOutcome) { self.outcome = outcome }
    func probe(host: String, port: Int, protocol: ProxyProtocol) async -> ProbeOutcome { callCount += 1; return outcome }
}

final class SmokeRemoteProber: RemoteProbeExecuting, @unchecked Sendable {
    var outcome: RemoteProbeOutcome
    private(set) var lastProtocol: ProxyProtocol?
    private(set) var lastRemotePort: Int?
    private(set) var callCount = 0
    private(set) var history: [(Int, ProxyProtocol)] = []
    init(outcome: RemoteProbeOutcome) { self.outcome = outcome }
    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol, password: String?) async -> RemoteProbeOutcome {
        callCount += 1
        lastProtocol = `protocol`
        lastRemotePort = remotePort
        history.append((remotePort, `protocol`))
        return outcome
    }
}

/// HTTP 入口替身：记录启动模式与端口（不监听真实端口）。
final class SmokeHTTPEntry: HTTPEntryRelaying, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var starts = 0
    private(set) var stopped = false
    func start(port: UInt16, mode: HTTPEntryMode) async throws -> UInt16 {
        lock.lock(); starts += 1; lock.unlock()
        return 45_001
    }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }
}

/// 始终失败的 HTTP 入口替身。
final class SmokeFailingHTTPEntry: HTTPEntryRelaying, @unchecked Sendable {
    func start(port: UInt16, mode: HTTPEntryMode) async throws -> UInt16 {
        throw NSError(domain: "Smoke.HTTPEntry", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "端口被占用（冒烟注入）"])
    }
    func stop() {}
}
