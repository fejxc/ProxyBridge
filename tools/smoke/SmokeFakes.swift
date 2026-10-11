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

    func enqueue(_ h: SmokeSSHHandle) {
        lock.lock(); pending.append(h); lock.unlock()
    }

    func make(arguments: [String], environment: [String: String]) -> SSHProcessHandle {
        lock.lock()
        let h = pending.isEmpty ? SmokeSSHHandle() : pending.removeFirst()
        handles.append(h)
        lock.unlock()
        return h
    }
}

final class SmokeLocalProber: ProxyProbeExecuting, @unchecked Sendable {
    var outcome: ProbeOutcome
    init(outcome: ProbeOutcome) { self.outcome = outcome }
    func probe(host: String, port: Int, protocol: ProxyProtocol) async -> ProbeOutcome { outcome }
}

final class SmokeRemoteProber: RemoteProbeExecuting, @unchecked Sendable {
    var outcome: RemoteProbeOutcome
    init(outcome: RemoteProbeOutcome) { self.outcome = outcome }
    func probe(profile: ServerProfile, remotePort: Int, protocol: ProxyProtocol) async -> RemoteProbeOutcome { outcome }
}
