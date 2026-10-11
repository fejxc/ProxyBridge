import Foundation

/// 日志脱敏（纯函数）。规则对应 02-TECHNICAL-DESIGN §9：
/// - 过滤 ANSI 控制序列与其他不可打印控制字符（保留换行/制表）；
/// - 截断超长行；
/// - 可选遮挡：私钥路径、user@host、IPv4、常见 token 形态。
enum LogRedaction {

    static let maxMessageLength = 2_000

    /// 去掉 ANSI CSI/OSC 序列与其余控制字符。SSH stderr 可能夹带转义序列，
    /// 绝不能原样进入 UI 富文本。
    static func sanitize(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var iter = raw.unicodeScalars.makeIterator()
        var pending: [Unicode.Scalar] = []

        func flushPending() {
            out.append(contentsOf: pending)
            pending.removeAll()
        }

        while let c = iter.next() {
            if c == "\u{1B}" { // ESC
                flushPending()
                var consumedTerminator = false
                var depth = 0
                while let n = iter.next() {
                    if n == "[" && depth == 0 {
                        depth = 1 // CSI：吃到最终字节 0x40–0x7E
                        continue
                    }
                    if n == "]" && depth == 0 {
                        depth = 2 // OSC：吃到 BEL 或 ST
                        continue
                    }
                    if depth == 1 {
                        if n.value >= 0x40 && n.value <= 0x7E {
                            consumedTerminator = true
                            break
                        }
                    } else if depth == 2 {
                        if n == "\u{07}" { // BEL
                            consumedTerminator = true
                            break
                        }
                        if n == "\u{1B}" {
                            // 可能是 ST 的 ESC \
                            if let next = iter.next(), next == "\\" {
                                consumedTerminator = true
                                break
                            }
                            continue
                        }
                        if n == "\n" {
                            consumedTerminator = true
                            break
                        }
                        continue
                    } else {
                        break // 单字符转义（如 ESC c）直接丢弃
                    }
                }
                _ = consumedTerminator
                continue
            }
            // 丢弃 C0 控制字符（保留 \n \t）、DEL、C1 控制字符（0x80–0x9F，
            // VT100 终端以 ESC 开头的 8 位形式出现）、以及 Unicode 格式/双向控制符
            // （Cf：零宽连接符、从右到左标记等，可被用于视觉欺骗）。
            let isAllowedControl = (c == "\n" || c == "\t")
            let isC1 = (c.value >= 0x80 && c.value <= 0x9F)
            let isUnicodeFormat = c.properties.generalCategory == .format
            if !isAllowedControl && ((c.value < 0x20) || c.value == 0x7F || isC1 || isUnicodeFormat) {
                continue
            }
            pending.append(c)
            if pending.count > 64 { flushPending() }
        }
        flushPending()
        var s = String(out)
        if s.count > maxMessageLength {
            s = String(s.prefix(maxMessageLength)) + "…(截断)"
        }
        return s
    }

    struct Options: OptionSet, Sendable {
        let rawValue: Int
        static let keyPaths = Options(rawValue: 1 << 0)
        static let userHost = Options(rawValue: 1 << 1)
        static let ipAddresses = Options(rawValue: 1 << 2)
        static let tokens = Options(rawValue: 1 << 3)
        static let all: Options = [.keyPaths, .userHost, .ipAddresses, .tokens]
        static let export: Options = .all
    }

    /// 按选项遮挡敏感内容。遮挡输出保持可读（[路径] / [用户@主机] / [IP] / [凭据]）。
    static func redact(_ message: String, options: Options = .all) -> String {
        var s = message
        if options.contains(.keyPaths) {
            // 任意用户目录下的 .ssh 路径（~、绝对路径、任意家目录形态）
            s = replace(pattern: #"(?:~|/[\w.\-]+(?:/[\w.\-]+)*)/\.ssh/[^\s"']+"#, in: s, with: "[密钥路径]")
            // 常见私钥/证书文件后缀（无论目录）
            s = replace(pattern: #"[^\s"]+\.(pem|key|p12|pfx)\b"#, in: s, with: "[密钥文件]")
        }
        if options.contains(.userHost) {
            s = replace(pattern: #"[A-Za-z_][A-Za-z0-9._-]*@[A-Za-z0-9.-]+"#, in: s, with: "[用户@主机]")
        }
        if options.contains(.ipAddresses) {
            s = replace(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, in: s, with: "[IP]")
        }
        if options.contains(.tokens) {
            // Bearer/Basic token 与长十六进制/ssh-ed25519 形态
            s = replace(pattern: #"(?i)(bearer|token)\s+[A-Za-z0-9._~+/=-]{8,}"#, in: s, with: "$1 [凭据]")
            s = replace(pattern: #"ssh-(rsa|ed25519|dss|ecDSA) [A-Za-z0-9+/=]{20,}"#, in: s, with: "[公钥内容]")
        }
        return s
    }

    /// 入库前的默认处理：先 sanitize，再保守脱敏（日志界面默认不显示密钥路径与凭据）。
    static func sanitizeForStorage(_ raw: String) -> String {
        redact(sanitize(raw), options: [.keyPaths, .tokens])
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = NSMutableString(string: text)
        re.replaceMatches(in: ns, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
        return ns as String
    }
}
