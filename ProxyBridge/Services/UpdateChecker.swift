import Foundation

/// 一次更新检查的结论。
struct UpdateInfo: Equatable, Sendable {
    var latestVersion: String   // 如 "1.4.0"（无 v 前缀）
    var releaseURL: URL
    /// 通用 DMG 下载地址与校验文件（应用内安装用；缺失时回退浏览器下载）。
    var dmgURL: URL? = nil
    var sha256URL: URL? = nil
}

/// 更新检查抽象（测试注入）。
@MainActor
protocol UpdateChecking: AnyObject {
    /// 获取最新已发布版本；网络失败/解析失败返回 nil（如实静默，不打扰用户）。
    func latestRelease() async -> UpdateInfo?
}

/// 真实实现：GitHub Releases `latest` API（匿名 GET，无任何遥测上行）。
@MainActor
final class GitHubReleaseUpdateChecker: UpdateChecking {
    private let repoSlug: String
    private let session: URLSession

    init(repoSlug: String = "fejxc/ProxyBridge") {
        self.repoSlug = repoSlug
        self.session = URLSession(configuration: .ephemeral)
    }

    func latestRelease() async -> UpdateInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let page = object["html_url"] as? String,
              let pageURL = URL(string: page) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Version.isValidVersion(version) else { return nil }
        // 资产：通用 DMG 与 .sha256（供应用内下载安装）
        var dmgURL: URL?
        var sha256URL: URL?
        if let assets = object["assets"] as? [[String: Any]] {
            for asset in assets {
                guard let name = asset["name"] as? String,
                      let link = asset["browser_download_url"] as? String,
                      let linkURL = URL(string: link) else { continue }
                if name.hasSuffix("universal.dmg") { dmgURL = linkURL }
                if name.hasSuffix(".dmg.sha256") { sha256URL = linkURL }
            }
        }
        return UpdateInfo(latestVersion: version, releaseURL: pageURL, dmgURL: dmgURL, sha256URL: sha256URL)
    }
}

/// 版本比较（纯函数，测试覆盖）。
enum Version {
    /// 语义化比较：`1.10.0 > 1.9.0`。解析失败的输入返回 false（绝不因解析问题误报更新）。
    static func isNewer(candidate: String, current: String) -> Bool {
        let c = parse(candidate)
        let cur = parse(current)
        guard c.count > 0, cur.count > 0 else { return false }
        for i in 0..<max(c.count, cur.count) {
            let a = i < c.count ? c[i] : 0
            let b = i < cur.count ? cur[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// 校验 `X.Y.Z` 形态（GitHub tag 用）。
    static func isValidVersion(_ value: String) -> Bool {
        !parse(value).isEmpty
    }

    private static func parse(_ value: String) -> [Int] {
        let parts = value.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return [] }
        return parts.compactMap { $0 }
    }
}
