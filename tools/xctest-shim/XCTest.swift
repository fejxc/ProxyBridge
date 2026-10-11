// XCTest 兼容 shim —— 仅用于「无完整 Xcode 的环境」下对测试代码做编译级类型检查。
// 产物不进入 .xcodeproj、不打进 App；真实断言语义以 Apple XCTest 为准。
// 使用：scripts/typecheck.sh 会把本文件编成 XCTest.swiftmodule 后检查 ProxyBridgeTests。
// 注意：此 shim 不实现任何运行时断言（类型检查场景足够；运行测试需完整 Xcode）。

import Foundation
// 真实 XCTest 会公开传递 Foundation；shim 保持一致，测试文件只需 import XCTest。
@_exported import Foundation

open class XCTestCase: @unchecked Sendable {
    public init() {}
    open func setUp() {}
    open func setUp() async throws {}
    open func tearDown() {}
    open func tearDown() async throws {}
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssert(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNotNil(_ expression: @autoclosure () throws -> Any?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertEqual<T: Equatable>(_ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertNotEqual<T: Equatable>(_ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertLessThan<T: Comparable>(_ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertGreaterThan<T: Comparable>(_ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertLessThanOrEqual<T: Comparable>(_ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ expression1: @autoclosure () throws -> T, _ expression2: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
public func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ errorHandler: (any Error) -> Void = { _ in }) {}
public func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {}
