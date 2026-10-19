import Foundation

// MARK: - 代理出口 IP 指纹（节点切换检测）
//
// Clash 等客户端切换节点时，本地端口与系统设置都不变——现有检测完全无感。
// 出口 IP 是唯一普适的指纹：经本地代理请求一个返回出口 IP 的轻量端点，
// IP 变化即代表节点切换（或节点自身出口变化）。不依赖任何代理客户端的
// 控制接口。探测失败如实返回 nil（不猜测），退回现有行为。

/// 出口 IP 探测抽象（测试注入）。
protocol EgressIPProbing: AnyObject, Sendable {
    /// 经指定代理端点获取出口 IP；任何失败返回 nil（端点不可达/输出非法）。
    func probe(host: String, port: Int, protocol: ProxyProtocol) async -> String?
}

/// 生产实现：/usr/bin/curl 经代理 GET 出口端点，解析 stdout 中的 IP。
/// 安全约束与 CurlProxyProbe 同源：参数数组直传不经 shell、-q 跳过 curlrc、
/// 最小环境变量、独立 URL 白名单。
final class CurlEgressIPProbe: EgressIPProbing {
    static let egressURL = "https://api.ip.sb/ip"
    static let urlWhitelist: Set<String> = [egressURL]

    private let connectTimeoutSeconds: Int
    private let maxTimeSeconds: Int

    init(connectTimeoutSeconds: Int = 2, maxTimeSeconds: Int = 6) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.maxTimeSeconds = maxTimeSeconds
    }

    func probe(host: String, port: Int, protocol: ProxyProtocol) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: CurlProxyProbe.executableURL.path),
              CurlProxyProbe.isValidProbeHost(host),
              (1...65_535).contains(port) else { return nil }
        let args = Self.arguments(
            host: host, port: port, protocol: `protocol`,
            connectTimeout: connectTimeoutSeconds, maxTime: maxTimeSeconds
        )
        let box = CurlProxyProbe.ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let output = Self.run(arguments: args, cancellationBox: box)
                    continuation.resume(returning: Self.parseIP(output))
                }
            }
        } onCancel: {
            box.terminateIfRunning()
        }
    }

    /// 参数构建（纯函数）：经代理取回端点响应体（stdout 即 IP 文本）。
    static func arguments(
        host: String, port: Int, protocol: ProxyProtocol,
        connectTimeout: Int, maxTime: Int
    ) -> [String] {
        precondition(urlWhitelist.contains(egressURL))
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let proxyValue: String
        switch `protocol` {
        case .http, .mixed: proxyValue = "http://\(hostPart):\(port)"
        case .socks5: proxyValue = "\(hostPart):\(port)"
        }
        return [
            "-q",
            "--noproxy", "",
            `protocol`.curlProxyFlag, proxyValue,
            "--connect-timeout", String(connectTimeout),
            "--max-time", String(maxTime),
            "--silent", "--show-error",
            egressURL,
        ]
    }

    /// 阻塞执行（复用 CurlProxyProbe 的管道/取消模式），返回 stdout。
    static func run(arguments: [String], cancellationBox: CurlProxyProbe.ProcessBox? = nil) -> String {
        let process = Process()
        process.executableURL = CurlProxyProbe.executableURL
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return ""
        }
        cancellationBox?.set(process)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        cancellationBox?.set(Process())
        guard process.terminationStatus == 0 else { return "" }
        return String(decoding: outData, as: UTF8.self)
    }

    /// 解析 IP（纯函数）：接受 IPv4 / IPv6 字面量；其余（HTML/空/多行垃圾）返回 nil。
    static func parseIP(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("<"), trimmed.count <= 45 else { return nil }
        // IPv4
        let v4 = trimmed.split(separator: ".")
        if v4.count == 4,
           v4.allSatisfy({ part in
               guard let value = Int(part), (0...255).contains(value), part.count <= 3 else { return false }
               return true
           }) {
            return trimmed
        }
        // IPv6（粗校验：hex 与冒号，至少两处冒号）
        if trimmed.contains(":"), trimmed.allSatisfy({ $0.isHexDigit || $0 == ":" }),
           trimmed.filter({ $0 == ":" }).count >= 2 {
            return trimmed
        }
        return nil
    }
}
