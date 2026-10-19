import Foundation
import OSLog
import SystemConfiguration

// MARK: - 系统代理变化通知（02-TECHNICAL-DESIGN §4.3）

/// 系统代理配置变化通知抽象（测试注入）。
protocol SystemProxyChangeMonitoring: AnyObject {
    var onChange: (@MainActor () -> Void)? { get set }
    /// 启动通知订阅。返回 false 表示通知链路不可用（调用方应如实提示，依赖手动刷新）。
    func start() -> Bool
    func stop()
}

/// SCDynamicStore 代理键变化监视器：订阅 `SCDynamicStoreKeyCreateProxies` 键，
/// 回调在私有串行队列上触发，经 MainActor 交给防抖器。
/// `@unchecked Sendable`：C 回调（SCDynamicStoreCallBack）桥接需要跨隔离域传递 self；
/// 线程安全由使用方式保证——onChange 在 start() 前于 MainActor 设置，start 后只读，
/// store 仅在 start/stop（调用方持有期间）变更。
final class SCDynamicStoreChangeMonitor: SystemProxyChangeMonitoring, @unchecked Sendable {
    var onChange: (@MainActor () -> Void)?

    private var store: SCDynamicStore?
    private let queue = DispatchQueue(label: "dev.sunyun.ProxyBridge.proxymonitor", qos: .utility)

    func start() -> Bool {
        guard store == nil else { return true }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<SCDynamicStoreChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                monitor.onChange?()
            }
        }
        guard let store = SCDynamicStoreCreate(nil, "dev.sunyun.ProxyBridge" as CFString, callback, &context) else {
            return false
        }
        let proxyKey = SCDynamicStoreKeyCreateProxies(nil)
        // 任一注册步骤失败都视为通知链路不可用（不得静默半生效）
        guard SCDynamicStoreSetNotificationKeys(store, [proxyKey] as CFArray, nil),
              SCDynamicStoreSetDispatchQueue(store, queue) else {
            return false
        }
        self.store = store
        return true
    }

    /// 卸载顺序（SDK 文档）：先清通知键，再 SetDispatchQueue(nil) 停用并释放队列，
    /// 最后释放 store。queue.sync 排空已在私有队列上的回调，避免 takeUnretainedValue
    /// 命中已释放的 self（use-after-free）。
    func stop() {
        guard let store else { return }
        SCDynamicStoreSetNotificationKeys(store, [] as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(store, nil)
        queue.sync {} // 屏障：等待/排空在途回调
        self.store = nil
    }

    deinit {
        stop()
    }
}

// MARK: - 真实本地代理检测器

/// 真实检测：读系统设置 → 去重候选 → curl 逐协议实测 → 变化通知防抖重扫。
/// 语义承诺：
/// - 只有 curl 完整走通代理路径（TLS 校验 + 2xx/3xx）才标记 verified；
/// - PAC / TUN / 非 loopback 等限制如实进入 limitations，不猜测端口；
/// - 系统配置变化经 800ms 防抖后重新扫描（U15）。
@MainActor
final class LocalProxyDetector: ProxyDetectorService {
    var onStateChange: (@MainActor (ProxyDetectionState) -> Void)?

    private let provider: any SystemProxyProviding
    private let environmentProvider: any ProxyEnvironmentProviding
    private let prober: any ProxyProbeExecuting
    private let monitor: any SystemProxyChangeMonitoring
    /// 出口 IP 指纹探测（节点切换检测）；nil = 不探测（测试装配）。
    private let egressProber: (any EgressIPProbing)?

    /// 变化防抖间隔。默认 800ms；测试注入更短值。
    var debounceSeconds: TimeInterval = 0.8

    private var state = ProxyDetectionState()
    private var debounceTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    /// 扫描代次：新扫描使旧扫描结果作废，防止陈旧数据覆盖新状态。
    private var scanGeneration = 0
    /// 系统变化通知链路是否可用（不可用时如实提示用户依赖手动刷新）。
    private var monitorHealthy = true

    init(
        provider: any SystemProxyProviding,
        prober: any ProxyProbeExecuting,
        monitor: any SystemProxyChangeMonitoring,
        environmentProvider: any ProxyEnvironmentProviding = ProcessProxyEnvironmentProvider(),
        egressProber: (any EgressIPProbing)? = nil
    ) {
        self.provider = provider
        self.environmentProvider = environmentProvider
        self.prober = prober
        self.monitor = monitor
        self.egressProber = egressProber
        self.state.isLive = true
    }

    func detect() {
        beginScan(reason: "手动刷新")
    }

    @discardableResult
    func startObservingSystemChanges() -> Bool {
        monitor.onChange = { [weak self] in
            self?.scheduleDebouncedScan()
        }
        monitorHealthy = monitor.start()
        if !monitorHealthy {
            // 不得静默吞掉：经 OSLog 与状态两个通道如实上报
            Logger(subsystem: "dev.sunyun.ProxyBridge", category: "proxymonitor")
                .error("SCDynamicStore 通知订阅失败，系统代理变化将无法自动感知")
        }
        return monitorHealthy
    }

    /// 防抖：窗口内的连续变化只触发一次重扫（U15）。
    func scheduleDebouncedScan() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self, seconds = debounceSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.beginScan(reason: "系统代理配置变化")
        }
    }

    // MARK: 扫描

    private func beginScan(reason: String) {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        state.isScanning = true
        emit()

        scanTask = Task { @MainActor [weak self, provider, environmentProvider, prober] in
            guard let self else { return }
            let snapshot = provider.readProxies()
            let built = ProxyCandidateBuilder.build(
                from: snapshot,
                environment: environmentProvider.readEnvironment()
            )
            var candidates = built.candidates

            // 仅对回环候选逐协议实测；非 loopback 候选保持 untested + 提示
            let probeTargets = candidates.enumerated().filter {
                ProxyCandidateBuilder.isLoopback($0.element.endpoint.host)
            }
            await withTaskGroup(of: (Int, ProbeOutcome).self) { group in
                for (index, candidate) in probeTargets {
                    group.addTask { [prober] in
                        let outcome = await prober.probe(
                            host: candidate.endpoint.host,
                            port: candidate.endpoint.port,
                            protocol: candidate.endpoint.protocol
                        )
                        return (index, outcome)
                    }
                }
                for await (index, outcome) in group {
                    guard generation == self.scanGeneration, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    candidates[index] = Self.apply(outcome: outcome, to: candidates[index])
                }
            }

            // 代次失效：期间有新扫描启动，本次结果丢弃
            guard generation == self.scanGeneration, !Task.isCancelled else { return }

            self.state.candidates = candidates
            var limitations = built.limitations
            if !self.monitorHealthy {
                limitations.append("系统代理变化通知不可用：系统设置变更后无法自动重扫，请手动点「重新检测」。")
            }
            self.state.limitations = limitations
            self.state.systemProxyActiveButUnresolved = snapshot.pacEnabled && built.candidates.isEmpty

            // 出口 IP 指纹：对最佳已验证端点探测（节点切换检测用；失败如实 nil）
            if let egressProber,
               let best = self.state.bestVerifiedEndpoint() {
                self.state.egressIP = await egressProber.probe(
                    host: best.host, port: best.port, protocol: best.protocol
                )
                guard generation == self.scanGeneration, !Task.isCancelled else { return }
            } else {
                self.state.egressIP = nil
            }

            self.state.lastScanAt = Date()
            self.state.isScanning = false
            self.emit()
        }
    }

    /// 探测结论 → 候选能力标注（纯映射，便于测试与 UI 复用）。
    static func apply(outcome: ProbeOutcome, to candidate: ProxyCandidate) -> ProxyCandidate {
        var updated = candidate
        switch outcome {
        case .verified(let code):
            updated.capability = .verified
            updated.endpoint.verifiedAt = Date()
            updated.note = "curl 实测通过（HTTP \(code)）"
        case .reachableNotProxy(let code):
            updated.capability = .reachable
            updated.note = code.map { "端口有响应（HTTP \($0)），但无法作为该协议代理使用" }
                ?? "端口有响应，但拒绝了代理连接（CONNECT 被拒）"
        case .authRequired:
            updated.capability = .failed
            updated.note = "代理要求身份认证（407）：MVP 不支持带认证的代理，请调整代理客户端设置"
        case .connectionRefused:
            updated.capability = .failed
            updated.note = "端口未监听或拒绝连接（代理客户端未运行？）"
        case .timeout:
            updated.capability = .failed
            updated.note = "经代理连接验证站点超时"
        case .tlsError:
            updated.capability = .failed
            updated.note = "经代理建立 TLS 失败（证书错误或拦截）"
        case .failed(let reason):
            updated.capability = .failed
            updated.note = reason
        }
        return updated
    }

    private func emit() {
        onStateChange?(state)
    }
}
