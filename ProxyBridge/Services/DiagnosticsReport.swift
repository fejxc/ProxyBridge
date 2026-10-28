import Foundation

/// 诊断包（纯函数 + 磁盘日志尾段读取）：把「可贴到 GitHub issue 的证据」一键落成一个文件。
/// 隐私边界与日志一致——出机内容一律经 LogRedaction.redact(.all)：
/// 服务器 host / 端口不主动写入（profile 只取名称与模式）；密码、密钥、凭据永不包含。
enum DiagnosticsReport {

    struct ServerInfo: Equatable, Sendable {
        let name: String
        let mode: String
        let status: String
    }

    struct Content: Equatable, Sendable {
        let appVersion: String
        let systemVersion: String
        let servers: [ServerInfo]
        /// 当前选中服务器的健康摘要行（title + detail）；无活跃会话时为 nil。
        let activeSummary: String?
        /// 内存环形缓冲的会话日志（调用方以 LogStore.exportText(redacted: true) 取得）。
        let sessionLogs: String
        let diskLogPathLabel: String?
        let diskLogTail: String?
        let diskLogTruncated: Bool
    }

    static func markdown(_ content: Content, now: Date = Date()) -> String {
        var out: [String] = []
        out.append("# ProxyBridge 诊断包")
        out.append("")
        out.append("> 本文件由 ProxyBridge 生成，内容已按日志同规则脱敏（密钥路径 / 凭据 / IP / 用户@主机）。")
        out.append("> 生成时间：\(timestampFormatter.string(from: now)) · 可直接附到 GitHub issue：<https://github.com/fejxc/ProxyBridge/issues>")
        out.append("")
        out.append("## 环境")
        out.append("")
        out.append("- 应用版本：\(content.appVersion)")
        out.append("- 系统：\(content.systemVersion)")
        out.append("")
        out.append("## 连接状态")
        out.append("")
        if content.servers.isEmpty {
            out.append("- 尚未配置服务器")
        } else {
            for server in content.servers {
                out.append("- 服务器「\(server.name)」：\(server.mode) — \(server.status)")
            }
        }
        if let summary = content.activeSummary {
            out.append("- 当前服务器健康摘要：\(summary)")
        }
        out.append("")
        out.append("## 会话日志（环形缓冲，最多 \(LogStore.capacity) 条）")
        out.append("")
        // 咽喉加固：无论调用方传什么，出机前统一再过一遍导出级脱敏（对已脱敏文本幂等）。
        out.append(fenced(content.sessionLogs.isEmpty ? nil : LogRedaction.redact(content.sessionLogs, options: .all), empty: "（本次会话无日志）"))
        out.append("")
        if let label = content.diskLogPathLabel {
            out.append("## 磁盘日志末段（\(label)，仅末段；完整记录在本机）")
            out.append("")
            if let tail = content.diskLogTail, !tail.isEmpty {
                if content.diskLogTruncated {
                    out.append("（超过读取上限，已截断保留末尾）")
                    out.append("")
                }
                out.append(fenced(LogRedaction.redact(tail, options: .all), empty: nil))
            } else {
                out.append("（无磁盘日志）")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// 读取磁盘日志末段并逐行做导出级脱敏。文件缺失返回 nil；文件超长时从字节上限处
    /// 起读并丢弃首个可能不完整的行，行数超限再按行截断，truncated 如实标注。
    static func diskLogTail(
        url: URL,
        maxLines: Int = 120,
        maxBytes: Int = 32 * 1024
    ) -> (text: String, truncated: Bool)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var truncated = false
        var payload = data
        if payload.count > maxBytes {
            payload = Data(payload.suffix(maxBytes))
            truncated = true
            if let firstNewline = payload.firstIndex(of: UInt8(ascii: "\n")) {
                payload = Data(payload[payload.index(after: firstNewline)...])
            }
        }
        var lines = String(decoding: payload, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
            truncated = true
        }
        let redacted = lines.map { LogRedaction.redact($0, options: .all) }.joined(separator: "\n")
        return (redacted, truncated)
    }

    static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func fenced(_ text: String?, empty: String?) -> String {
        guard let text, !text.isEmpty else {
            return empty ?? ""
        }
        return "```\n\(text)\n```"
    }
}
