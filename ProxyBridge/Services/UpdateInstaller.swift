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
    /// 下载 DMG 到临时目录，返回本地路径（失败 nil）。
    func download(url: URL, progress: @escaping (Double) -> Void) async -> URL?
    /// 拉取官方 .sha256 文本中的大写/小写十六进制摘要（失败 nil）。
    func fetchExpectedSHA256(url: URL) async -> String?
    /// 本地文件摘要是否匹配（nil expected 视为不通过——绝不跳过校验）。
    func verify(file: URL, expectedHex: String) -> Bool
    /// 挂载并替换 /Applications 中的应用，成功返回 true。
    /// App 不在 /Applications 时仅挂载并打开卷（用户手动拖入），同样返回 true。
    func installAndRelaunch(dmg: URL) -> Bool
}

@MainActor
final class DMGUpdateInstaller: UpdateInstalling {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    func download(url: URL, progress: @escaping (Double) -> Void) async -> URL? {
        guard let (bytes, response) = try? await session.bytes(for: URLRequest(url: url)),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let expected = http.expectedContentLength
        var data = Data()
        data.reserveCapacity(expected > 0 ? Int(expected) : 0)
        do {
            for try await byte in bytes {
                data.append(byte)
                if expected > 0, data.count % (512 * 1024) == 0 { // 节流回报进度
                    progress(Double(data.count) / Double(expected))
                }
            }
        } catch {
            return nil
        }
        guard expected <= 0 || data.count == expected else { return nil } // 不完整下载拒绝安装
        progress(1)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyBridge-update-\(Int(Date().timeIntervalSince1970)).dmg")
        do {
            try data.write(to: destination, options: [.atomic])
            return destination
        } catch {
            return nil
        }
    }

    func fetchExpectedSHA256(url: URL) async -> String? {
        guard let (data, response) = try? await session.data(for: URLRequest(url: url)),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return Self.parseSHA256Hex(String(decoding: data, as: UTF8.self))
    }

    /// 解析官方 .sha256 文本（格式形如 "abcdef…  ProxyBridge-x.y.z-universal.dmg"，纯函数）。
    static func parseSHA256Hex(_ text: String) -> String? {
        let hex = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex.lowercased()
    }

    func verify(file: URL, expectedHex: String) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == expectedHex.lowercased()
    }

    func installAndRelaunch(dmg: URL) -> Bool {
        // 挂载（-nobrowse 不在 Finder 侧栏显示）
        let mount = Process()
        mount.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mount.arguments = ["attach", "-nobrowse", "-readonly", dmg.path]
        let pipe = Pipe()
        mount.standardOutput = pipe
        mount.standardError = Pipe()
        do { try mount.run() } catch { return false }
        mount.waitUntilExit()
        guard mount.terminationStatus == 0 else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let volumePath = output.split(separator: "\n").compactMap({ line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("/Volumes/") ? trimmed : nil
        }).last else { return false }
        let mountedApp = URL(fileURLWithPath: volumePath).appendingPathComponent("ProxyBridge.app")
        guard FileManager.default.fileExists(atPath: mountedApp.path) else { return false }

        let installedURL = URL(fileURLWithPath: "/Applications/ProxyBridge.app")
        let runningFromApplications = Bundle.main.bundleURL.path.hasPrefix("/Applications/")
        defer {
            // 无论替换与否都弹出挂载（延迟执行让 cp 完成）
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", volumePath, "-force"]
            try? detach.run()
        }

        if runningFromApplications {
            // 原子替换：旧版本先改名，失败可回滚；绝不留下半写状态
            let backup = installedURL.appendingPathExtension("old")
            try? FileManager.default.removeItem(at: backup)
            let hadOld = FileManager.default.fileExists(atPath: installedURL.path)
            if hadOld {
                do { try FileManager.default.moveItem(at: installedURL, to: backup) }
                catch { return false }
            }
            do { try FileManager.default.copyItem(at: mountedApp, to: installedURL) }
            catch {
                if hadOld { try? FileManager.default.moveItem(at: backup, to: installedURL) } // 回滚
                return false
            }
            try? FileManager.default.removeItem(at: backup)
            // 重启由调用方经 AppDelegate（terminate 流程内 spawn，避免单实例锁竞态）
            return true
        }
        // 开发/便携位置运行：打开挂载卷让用户手动拖入，不自动替换
        NSWorkspace.shared.open(URL(fileURLWithPath: volumePath))
        return true
    }
}
