import XCTest
@testable import ProxyBridge

/// C1 流量按 profile 持久化：差值记账、会话分段、落盘回读与清账。
@MainActor
final class TrafficTotalsStoreTests: XCTestCase {

    /// 每个测试自建临时目录（XCTestCase 的 setUp/tearDown 是 nonisolated，
    /// 不能碰 @MainActor 类的存储属性）。
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("traffic-totals-\(UUID().uuidString)", isDirectory: true)
    }

    private func snapshot(_ id: UUID, _ session: UUID, up: UInt64, down: UInt64, running: Bool = true) -> TrafficSnapshot {
        var snap = TrafficSnapshot(profileID: id, sessionID: session)
        snap.uploadBytes = up
        snap.downloadBytes = down
        snap.isRunning = running
        return snap
    }

    func testSameSessionAccumulatesDelta() {
        let store = TrafficTotalsStore()
        let id = UUID(), session = UUID()
        store.record(snapshot(id, session, up: 100, down: 0))
        store.record(snapshot(id, session, up: 350, down: 20))
        let totals = store.totals(for: id)
        XCTAssertEqual(totals.uploadBytes, 350)
        XCTAssertEqual(totals.downloadBytes, 20)
    }

    func testNewSessionStartsFreshWithoutNegativeDoubleCount() {
        let store = TrafficTotalsStore()
        let id = UUID()
        let first = UUID(), second = UUID()
        store.record(snapshot(id, first, up: 1_000, down: 500))
        // 新会话从接近 0 的计数器重新起算：首个快照的字节全额计入
        store.record(snapshot(id, second, up: 30, down: 0))
        let totals = store.totals(for: id)
        XCTAssertEqual(totals.uploadBytes, 1_030)
        XCTAssertEqual(totals.downloadBytes, 500)
    }

    func testCounterRewindCountsAsNewValue() {
        let store = TrafficTotalsStore()
        let id = UUID(), session = UUID()
        store.record(snapshot(id, session, up: 1_000, down: 0))
        store.record(snapshot(id, session, up: 10, down: 0))
        XCTAssertEqual(store.totals(for: id).uploadBytes, 1_010, "回绕按新值整体计入，宁多勿丢")
    }

    func testNilSessionIDIgnored() {
        let store = TrafficTotalsStore()
        let id = UUID()
        store.record(snapshot(id, UUID(), up: 100, down: 100))
        // 无会话的快照（Relay 未启动等场景）不计入、不改变活跃时间
        var idle = TrafficSnapshot(profileID: id)
        idle.isRunning = false
        idle.uploadBytes = 500
        store.record(idle)
        let totals = store.totals(for: id)
        XCTAssertEqual(totals.uploadBytes, 100, "无会话的快照不计入")
        XCTAssertEqual(totals.downloadBytes, 100)
        XCTAssertNotNil(totals.lastActiveAt, "活跃时间来自带会话的快照")
    }

    func testRemoveClearsMemoryAndDisk() {
        let id = UUID(), session = UUID()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficTotalsStore(directoryURL: directory)
        store.record(snapshot(id, session, up: 100, down: 0))
        store.flush()
        XCTAssertTrue(store.hasData(for: id))
        store.remove(id)
        XCTAssertFalse(store.hasData(for: id))

        let reloaded = TrafficTotalsStore(directoryURL: directory)
        XCTAssertFalse(reloaded.hasData(for: id), "删除后磁盘不再有该 profile 的记录")
    }

    func testFlushAndReloadRoundtrip() {
        let id = UUID(), session = UUID()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficTotalsStore(directoryURL: directory)
        store.record(snapshot(id, session, up: 1_234, down: 5_678))
        store.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(TrafficTotalsStore.fileName).path))
        let reloaded = TrafficTotalsStore(directoryURL: directory)
        let totals = reloaded.totals(for: id)
        XCTAssertEqual(totals.uploadBytes, 1_234)
        XCTAssertEqual(totals.downloadBytes, 5_678)
        XCTAssertNotNil(totals.lastActiveAt, "最近活跃时间随累计持久化")
    }

    func testThrottleDelaysWriteUntilFlush() {
        let id = UUID(), session = UUID()
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficTotalsStore(directoryURL: directory)
        // 首次记录距上次 flush 超过节流间隔（distantPast）→ 记录内即落盘
        store.record(snapshot(id, session, up: 10, down: 0))
        XCTAssertEqual(TrafficTotalsStore(directoryURL: directory).totals(for: id).uploadBytes, 10)
        // 节流窗口内的后续记录只进内存，不主动落盘
        store.record(snapshot(id, session, up: 30, down: 0))
        XCTAssertEqual(TrafficTotalsStore(directoryURL: directory).totals(for: id).uploadBytes, 10,
                       "节流间隔内的新增量未落盘")
        store.flush()
        XCTAssertEqual(TrafficTotalsStore(directoryURL: directory).totals(for: id).uploadBytes, 30,
                       "显式 flush 后增量落盘")
    }
}
