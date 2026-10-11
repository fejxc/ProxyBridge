import Foundation
import XCTest
@testable import ProxyBridge

/// 线程安全的事件记录器（测试观察 Mock 服务输出用）。
final class Recorder<T> {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    var snapshot: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
}

/// 轮询等待条件成立（避免依赖 XCTest 异步 API 的版本差异）。
func waitUntil(
    timeout: TimeInterval = 3,
    intervalMilliseconds: Int = 20,
    _ condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(intervalMilliseconds) * 1_000_000)
    }
    return condition()
}

/// 同上，条件闭包在主执行器上求值（可读取 @MainActor 状态）。
func waitUntilMain(
    timeout: TimeInterval = 3,
    intervalMilliseconds: Int = 20,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(intervalMilliseconds) * 1_000_000)
    }
    return await condition()
}

/// 临时目录（测试仓库读写用），自动清理。
struct TempDirectory {
    let url: URL

    static func make(uniqueName: String = UUID().uuidString) -> TempDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridgeTests-\(uniqueName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return TempDirectory(url: url)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: url)
    }
}
