import Foundation
import Observation

/// 按 profile 持久化的流量历史累计（C1）。
///
/// 数据边界：只累计静态转发 Relay 的真实业务字节——`TunnelEvent.traffic` 的唯一
/// 产生者是 TCPRelay（HTTP 兼容入口不计字节，动态 SOCKS5 无诚实数据源不产生事件），
/// 因此本 store 无需再过滤来源。速率与最近 60 秒样本仍是会话内数据，不持久化。
///
/// 记账方式：按 sessionID 分段的差值累计。同一会话内取相邻快照的字节差
/// （计数器回绕按新值计入，宁多勿丢）；跨会话（sessionID 变化或重启后）从当前
/// 值重新起算。落盘采用脏标记 + 节流（默认 10 秒）+ 事件驱动（Relay 停止、
/// 删除 profile 立即 flush）。
@MainActor @Observable
final class TrafficTotalsStore {
    struct ProfileTotals: Codable, Equatable, Sendable {
        var uploadBytes: UInt64 = 0
        var downloadBytes: UInt64 = 0
        var lastActiveAt: Date?
    }

    private struct SessionMark: Equatable {
        let sessionID: UUID
        let upload: UInt64
        let download: UInt64
    }

    static let flushInterval: TimeInterval = 10
    static let fileName = "traffic-stats.json"

    private var totals: [UUID: ProfileTotals] = [:]
    private var lastSeen: [UUID: SessionMark] = [:]
    private var dirtySinceFlush = false
    private var lastFlushAt = Date.distantPast
    /// nil = 纯内存（测试/冒烟），不触碰用户目录。
    private let fileURL: URL?

    /// 内存模式（测试/冒烟默认）。
    init() {
        fileURL = nil
    }

    /// 生产：持久化到 `directoryURL/traffic-stats.json`（目录不存在则创建）。
    init(directoryURL: URL) {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent(Self.fileName)
        loadFromDiskIfPossible()
    }

    /// 生产装配：与 profiles.json / settings.json 同目录。
    static func live() -> TrafficTotalsStore {
        TrafficTotalsStore(directoryURL: ProfileRepository.defaultDirectory())
    }

    func totals(for id: UUID) -> ProfileTotals {
        totals[id] ?? ProfileTotals()
    }

    /// 该 profile 是否有历史累计（UI 决定是否渲染累计行）。
    func hasData(for id: UUID) -> Bool {
        totals[id] != nil
    }

    /// 记一笔流量快照（主线程调用；事件来源见类注释）。
    func record(_ snapshot: TrafficSnapshot) {
        guard let sessionID = snapshot.sessionID else { return }
        let id = snapshot.profileID
        let (up, down): (UInt64, UInt64)
        if let mark = lastSeen[id], mark.sessionID == sessionID {
            // 计数器只增不减；出现回绕（理论不应发生）时按新值整体计入，宁多勿丢
            up = snapshot.uploadBytes >= mark.upload ? snapshot.uploadBytes - mark.upload : snapshot.uploadBytes
            down = snapshot.downloadBytes >= mark.download ? snapshot.downloadBytes - mark.download : snapshot.downloadBytes
        } else {
            // 新会话（含 App 重启后的首个快照）：本快照的累计值全额计入
            up = snapshot.uploadBytes
            down = snapshot.downloadBytes
        }
        if up > 0 || down > 0 || snapshot.isRunning {
            var entry = totals[id] ?? ProfileTotals()
            entry.uploadBytes &+= up
            entry.downloadBytes &+= down
            if snapshot.isRunning { entry.lastActiveAt = Date() }
            totals[id] = entry
            if up > 0 || down > 0 { dirtySinceFlush = true }
        }
        lastSeen[id] = SessionMark(sessionID: sessionID, upload: snapshot.uploadBytes, download: snapshot.downloadBytes)
        if dirtySinceFlush, Date().timeIntervalSince(lastFlushAt) >= Self.flushInterval {
            flush()
        }
    }

    /// 清账（删除 profile 时调用）：内存与磁盘同时移除。
    func remove(_ id: UUID) {
        guard totals[id] != nil || lastSeen[id] != nil else { return }
        totals[id] = nil
        lastSeen[id] = nil
        dirtySinceFlush = true
        flush()
    }

    /// 立即落盘（脏数据存在时）。写盘失败保留脏标记，下个节流周期重试。
    func flush() {
        lastFlushAt = Date()
        guard dirtySinceFlush else { return }
        dirtySinceFlush = false
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(totals)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            dirtySinceFlush = true
        }
    }

    private func loadFromDiskIfPossible() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([UUID: ProfileTotals].self, from: data) else { return }
        totals = decoded
    }
}
