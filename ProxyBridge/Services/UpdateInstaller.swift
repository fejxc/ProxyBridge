import Foundation
import AppKit
import CryptoKit

// MARK: - 应用内更新安装（P0：自动更新闭环）
//
// 决策说明：不引入 Sparkle——本项目为 swiftc 脚本化构建（无 SPM/xcodebuild 管线），
// Sparkle 2 还要求 appcast 基建与 EdDSA 签名。此实现走官方 Release 资产：
// 下载通用 DMG → 对照官方 .sha256 校验 → hdiutil 挂载 → 替换 /Applications 内
// 旧版本 → 自动重启。安全性不低于手动下载安装（同一资产、同一校验文件、同一 Gatekeeper 行为）。

/// 更新安装抽象（测试注入）。
@MainActor
protocol UpdateInstalling: AnyObject {
    /// 下载 DMG 到临时文件（流式落盘，不整读内存），返回本地路径（失败 nil）。
    func download(url: URL, progress: @escaping (Double) -> Void) async -> URL?
    /// 拉取官方 .sha256 文本中的十六进制摘要（失败 nil）。
    func fetchExpectedSHA256(url: URL) async -> String?
    /// 本地文件流式摘要是否匹配。
    func verify(file: URL, expectedHex: String) -> Bool
    /// 校验挂载卷内 App 的身份与完整性（bundle id + 版本 + codesign）。
    func validateMountedApp(_ appURL: URL, expectedVersion: String) -> Bool
    /// 挂载 → 校验 → 同卷原子替换 /Applications 中的应用，成功返回 true。
    /// App 不在 /Applications 时仅挂载并打开卷（用户手动拖入），同样返回 true。
    func installAndRelaunch(dmg: URL, expectedVersion: String) -> Bool
}

@MainActor
final class DMGUpdateInstaller: UpdateInstalling {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    // MARK: - 下载（流式落盘 + delegate 进度）

    /// downloadTask delegate：把系统下载进度桥接为回调（下载到系统临时文件再移动）。
    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let handler: @Sendable (Double) -> Void
        init(handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            handler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }

    func download(url: URL, progress: @escaping (Double) -> Void) async -> URL? {
        let box = ProgressBox()
        box.progress = { value in progress(value) }
        let delegate = ProgressDelegate { value in box.progress?(value) }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (tempURL, response) = try await session.download(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ProxyBridge-update-\(Int(Date().timeIntervalSince1970)).dmg")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            progress(1)
            return destination
        } catch {
            return nil
        }
    }

    private final class ProgressBox: @unchecked Sendable {
        var progress: (@Sendable (Double) -> Void)?
    }

    // MARK: - 校验

    func fetchExpectedSHA256(url: URL) async -> String? {
        guard let (data, response) = try? await self.session.data(for: URLRequest(url: url)),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return Self.parseSHA256Hex(String(decoding: data, as: UTF8.self))
    }

    /// 解析官方 .sha256 文本（格式形如 "abcdef…  ProxyBridge-x.y.z-universal.dmg"，纯函数）。
    static func parseSHA256Hex(_ text: String) -> String? {
        let hex = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex.lowercased()
    }

    /// 文件流式摘要（分块读取，内存占用恒定，不整读大文件）。
    func verify(file: URL, expectedHex: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 4 * 1024 * 1024
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == expectedHex.lowercased()
    }

    // MARK: - 身份与完整性（独立于 Release 哈希的第二道验证）

    /// 挂载卷内 App 必须同时满足：bundle id 是本应用、版本等于声称版本、codesign 校验通过。
    /// 说明：ad-hoc 签名不含可独立验证的 Developer ID 身份（公证前的现实边界，见 KNOWN_LIMITATIONS），
    /// 但 codesign --verify 能证明 bundle 自发布以来未被篡改/损坏，版本与 id 核对能防张冠李戴。
    func validateMountedApp(_ appURL: URL, expectedVersion: String) -> Bool {
        guard let info = Bundle(url: appURL),
              let identifier = info.bundleIdentifier,
              identifier == "dev.sunyun.ProxyBridge" else { return false }
        guard let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              version == expectedVersion else { return false }
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--deep", "--strict", appURL.path]
        codesign.standardOutput = Pipe()
        codesign.standardError = Pipe()
        do { try codesign.run() } catch { return false }
        codesign.waitUntilExit()
        return codesign.terminationStatus == 0
    }

    // MARK: - 安装（先完整复制并验证，再原子切换）

    func installAndRelaunch(dmg: URL, expectedVersion: String) -> Bool {
        guard let volumePath = mount(dmg) else { return false }
        let mountedApp = URL(fileURLWithPath: volumePath).appendingPathComponent("ProxyBridge.app")
        guard FileManager.default.fileExists(atPath: mountedApp.path),
              validateMountedApp(mountedApp, expectedVersion: expectedVersion) else {
            detach(volumePath)
            return false
        }
        defer { detach(volumePath) }

        let installedURL = URL(fileURLWithPath: "/Applications/ProxyBridge.app")
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            // 开发/便携位置运行：打开挂载卷让用户手动拖入，不自动替换
            NSWorkspace.shared.open(URL(fileURLWithPath: volumePath))
            return true
        }

        // 第一步：完整复制到同卷暂存名（跨设备复制不可原子，但先复制可保证切换窗口最小化）
        let stagingURL = URL(fileURLWithPath: "/Applications/.ProxyBridge.app.new")
        try? FileManager.default.removeItem(at: stagingURL)
        do { try FileManager.default.copyItem(at: mountedApp, to: stagingURL) }
        catch { return false }
        // 第二步：暂存副本再次验证（复制过程中的损坏在此拦截，绝不半写上线）
        guard validateMountedApp(stagingURL, expectedVersion: expectedVersion) else {
            try? FileManager.default.removeItem(at: stagingURL)
            return false
        }
        // 第三步：同卷 rename 原子切换（旧版让位 → 新版上位，任一失败立即回滚）
        let backupURL = URL(fileURLWithPath: "/Applications/.ProxyBridge.app.old")
        try? FileManager.default.removeItem(at: backupURL)
        let hadOld = FileManager.default.fileExists(atPath: installedURL.path)
        if hadOld {
            do { try FileManager.default.moveItem(at: installedURL, to: backupURL) }
            catch {
                try? FileManager.default.removeItem(at: stagingURL)
                return false
            }
        }
        do { try FileManager.default.moveItem(at: stagingURL, to: installedURL) }
        catch {
            if hadOld { try? FileManager.default.moveItem(at: backupURL, to: installedURL) } // 回滚
            try? FileManager.default.removeItem(at: stagingURL)
            return false
        }
        try? FileManager.default.removeItem(at: backupURL)
        return true
    }

    private func mount(_ dmg: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-readonly", dmg.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("/Volumes/") ? trimmed : nil
        }.last
    }

    private func detach(_ volumePath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", volumePath, "-force"]
        try? process.run()
    }
}
