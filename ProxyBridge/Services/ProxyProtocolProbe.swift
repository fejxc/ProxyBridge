import Foundation

// MARK: - 探测结论（02-TECHNICAL-DESIGN §4.2）

/// 单次代理协议探测的结论。只有真实完成代理路径请求（TLS 校验 + 2xx/3xx）才算 verified。
enum ProbeOutcome: Equatable, Sendable {
    /// 经代理完成完整请求，收到 2xx/3xx。
    case verified(statusCode: Int)
    /// 端口有响应但不是该协议可用代理（404 页面 / CONNECT 被拒等）。
    case reachableNotProxy(statusCode: Int?)
    /// 代理要求认证（407）。
    case authRequired
    case connectionRefused
    case timeout
    case tlsError
    case failed(reason: String)

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

/// 探测执行抽象（测试注入 fake / 生产 curl）。
protocol ProxyProbeExecuting: AnyObject, Sendable {
    func probe(host: String, port: Int, protocol: ProxyProtocol) async -> ProbeOutcome
}

// MARK: - curl 探测器

/// 用 /usr/bin/curl 做真实代理协议探测。
/// 安全约束：参数数组直传（绝不经 shell）、环境变量最小化、
/// 验证 URL 来自代码白名单、host/port 经校验后逐字保真。
final class CurlProxyProbe: ProxyProbeExecuting {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    /// 固定验证目标（PRD F01：检验目标由 App 明确说明）。仅用于判定代理可用性。
    static let verificationURL = "https://www.example.com/"
    static let urlWhitelist: Set<String> = ["https://www.example.com/"]

    let connectTimeoutSeconds: Int
    let maxTimeSeconds: Int

    init(connectTimeoutSeconds: Int = 2, maxTimeSeconds: Int = 8) {
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.maxTimeSeconds = maxTimeSeconds
    }

    func probe(host: String, port: Int, protocol: ProxyProtocol) async -> ProbeOutcome {
        guard FileManager.default.isExecutableFile(atPath: Self.executableURL.path) else {
            return .failed(reason: "系统缺少 /usr/bin/curl")
        }
        guard Self.isValidProbeHost(host), (1...65_535).contains(port) else {
            return .failed(reason: "探测参数未通过校验（host/port）")
        }
        let args = Self.arguments(
            host: host, port: port, protocol: `protocol`,
            urlString: Self.verificationURL,
            connectTimeout: connectTimeoutSeconds, maxTime: maxTimeSeconds
        )
        // Task 取消时终止在途 curl（否则陈旧探测会占满 --max-time 窗口）
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.run(arguments: args, cancellationBox: box))
                }
            }
        } onCancel: {
            box.terminateIfRunning()
        }
    }

    /// 参数数组构建（纯函数，U07 同源保真：host/port 逐字进入数组，无任何拼接 shell）。
    static func arguments(
        host: String, port: Int, protocol: ProxyProtocol,
        urlString: String, connectTimeout: Int, maxTime: Int
    ) -> [String] {
        precondition(urlWhitelist.contains(urlString), "验证 URL 必须来自白名单")
        // IPv6 字面量必须加方括号，否则 curl 报「无法解析代理地址」（exit 5）
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let proxyValue: String
        switch `protocol` {
        case .http: proxyValue = "http://\(hostPart):\(port)"
        case .socks5: proxyValue = "\(hostPart):\(port)" // --socks5-hostname 直接 host:port，DNS 经代理解析
        }
        return [
            // -q 必须是第一个参数：跳过 ~/.curlrc 等配置文件。
            // 已实测：无 -q 时 curlrc 中的 `-x` 可劫持探测目标（exit 7 假代理），有 -q 时被忽略。
            "-q",
            "--noproxy", "",
            `protocol`.curlProxyFlag, proxyValue,
            "--connect-timeout", String(connectTimeout),
            "--max-time", String(maxTime),
            "--silent", "--show-error",
            "--output", "/dev/null",
            "--write-out", "%{http_code}",
            urlString,
        ]
    }

    /// Task 取消 → 终止在途 curl 的桥接（线程安全持有 Process 引用）。
    final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        func set(_ process: Process) {
            lock.lock()
            self.process = process
            lock.unlock()
        }

        func terminateIfRunning() {
            lock.lock()
            let process = self.process
            lock.unlock()
            if let process, process.isRunning {
                process.terminate()
            }
        }
    }

    /// 阻塞执行（调用方负责放到后台队列）。顺序：先读空管道再 wait，避免死锁。
    /// `cancellationBox` 非 nil 时登记进程引用，供 Task 取消时 terminate。
    static func run(arguments: [String], cancellationBox: ProcessBox? = nil) -> ProbeOutcome {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // 最小环境：杜绝 http_proxy / all_proxy 等环境变量干扰探测判断（§4.2）
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return .failed(reason: "无法启动 curl：\(error.localizedDescription)")
        }
        cancellationBox?.set(process)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        cancellationBox?.set(Process()) // 失效旧引用，防止取消时误杀无关进程

        return parse(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// 退出码 + %{http_code} + stderr → 结论（纯函数，U12 语义核心）。
    /// curl 退出码参考：5 代理解析失败、6 域名解析失败、7 连接被拒、28 超时、
    /// 35 SSL 握手失败、56 接收失败（CONNECT 被拒/407 经 stderr 区分）、60 证书校验失败。
    /// 注意：HTTPS 验证流程中代理回 407 时 curl 以 exit 56 退出（stdout 为 000），
    /// 必须结合 stderr 的「response 407」才能给出认证判定。
    static func parse(exitCode: Int32, stdout: String, stderr: String = "") -> ProbeOutcome {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = Int(trimmed).flatMap { $0 > 0 ? $0 : nil }
        switch exitCode {
        case 0:
            guard let code else { return .failed(reason: "curl 成功退出但无有效 HTTP 状态码") }
            if (200...399).contains(code) { return .verified(statusCode: code) }
            if code == 407 { return .authRequired }
            return .reachableNotProxy(statusCode: code)
        case 5:
            return .failed(reason: "无法解析代理地址")
        case 6:
            return .failed(reason: "无法解析验证站点域名（DNS 不可用？）")
        case 7:
            return .connectionRefused
        case 28:
            return .timeout
        case 35, 58, 60:
            return .tlsError
        case 56:
            // CONNECT 阶段失败：407 → 认证问题；其余按「非代理端口」呈现
            if stderr.contains("response 407") {
                return .authRequired
            }
            return .reachableNotProxy(statusCode: code)
        default:
            let stderrTrimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderrTrimmed.isEmpty ? trimmed : stderrTrimmed
            if !detail.isEmpty {
                return .failed(reason: "curl 退出码 \(exitCode)：\(detail.prefix(160))")
            }
            return .failed(reason: "curl 退出码 \(exitCode)")
        }
    }

    /// 探测主机白名单校验（IP/主机名/IPv6 字面量字符集；防 curl 参数注入面）。
    static func isValidProbeHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("-"), host.count <= 253 else { return false }
        return host.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || char == "." || char == "-" || char == ":")
        }
    }
}
