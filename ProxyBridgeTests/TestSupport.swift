import Foundation
import XCTest
@testable import ProxyBridge

/// 固定测试语言为中文：CI runner 为 en-US，进程内任何 AppViewModel 初始化都会经
/// resolve(.system) 把 L10n 切到英文。文案断言类测试须在方法开头调用本函数
/// （项目惯例：setUp 重写与 @MainActor 隔离不兼容，改为测试内显式调用）。
func pinChineseForTesting() {
    L10n.apply(.chinese)
}

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
