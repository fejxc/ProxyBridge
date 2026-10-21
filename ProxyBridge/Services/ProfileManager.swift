import Foundation

/// 服务器配置的存储与生命周期（CRUD、校验、草稿态、~/.ssh/config 导入、落盘）。
/// 从 AppViewModel 拆出的自治组件：持有 profiles / currentProfileId / editorIsNewDraft，
/// 会话侧状态（快照、隧道偏好、通知、密码）经 attach 装配的闭包回调宿主，时序与拆分前一致。
@MainActor
@Observable
final class ProfileManager {
    // MARK: - 依赖（注入）

    private let profileStore: ProfileRepository
    private let logStore: LogStore

    init(profileStore: ProfileRepository, logStore: LogStore) {
        self.profileStore = profileStore
        self.logStore = logStore
    }

    /// 装配需要引用宿主 ViewModel 状态的闭包（init 阶段 self 尚不可捕获，故两段式）。
    /// 必须在 loadFromDisk 之前调用（AppViewModel 于 init 内装配）。
    func attach(
        snapshot: @escaping (UUID) -> TunnelSnapshot?,
        applySnapshot: @escaping (TunnelSnapshot) -> Void,
        updateReconnectPreference: @escaping (_ id: UUID, _ reconnectEnabled: Bool, _ rememberPassword: Bool) -> Void,
        onProfileAdded: @escaping (UUID) -> Void,
        onProfileRemoving: @escaping (UUID) -> Void
    ) {
        self.snapshot = snapshot
        self.applySnapshot = applySnapshot
        self.updateReconnectPreference = updateReconnectPreference
        self.onProfileAdded = onProfileAdded
        self.onProfileRemoving = onProfileRemoving
    }

    private var snapshot: (UUID) -> TunnelSnapshot? = { _ in nil }
    private var applySnapshot: (TunnelSnapshot) -> Void = { _ in }
    private var updateReconnectPreference: (UUID, Bool, Bool) -> Void = { _, _, _ in }
    private var onProfileAdded: (UUID) -> Void = { _ in }
    private var onProfileRemoving: (UUID) -> Void = { _ in }

    // MARK: - 状态

    private(set) var profiles: [ServerProfile] = []
    private(set) var currentProfileId: UUID?
    /// 侧栏「添加服务器」置位的「新草稿」信号；编辑器据此本地建立未保存草稿。
    private(set) var editorIsNewDraft = false
    private var document: ProfilesDocument = .empty()

    var current: ServerProfile? {
        profiles.first { $0.id == currentProfileId }
    }

    func profile(id: UUID) -> ServerProfile? {
        profiles.first { $0.id == id }
    }

    // MARK: - 启动装载

    /// 从磁盘装载配置；损坏时隔离备份并以空配置启动（与拆分前 bootstrap 流程一致）。
    func loadFromDisk() {
        do {
            document = try profileStore.load()
        } catch ProfileRepositoryError.corrupted(let underlying) {
            do {
                let side = try profileStore.quarantineCorruptFile()
                logStore.append(
                    raw: "配置文件无法解析（\(LogRedaction.sanitize(underlying))），已备份至 \(side.lastPathComponent) 并以空配置启动",
                    level: .error
                )
            } catch {
                logStore.append(raw: "配置文件无法解析，且备份失败：\(error.localizedDescription)", level: .error)
            }
            document = .empty()
        } catch {
            logStore.append(raw: "读取配置失败：\(error.localizedDescription)", level: .error)
            document = .empty()
        }
        profiles = document.profiles
        currentProfileId = document.currentProfileId ?? profiles.first?.id
    }

    private func persist() {
        document = ProfilesDocument(
            schemaVersion: ProfilesDocument.currentSchemaVersion,
            profiles: profiles,
            currentProfileId: currentProfileId
        )
        do {
            try profileStore.save(document)
        } catch {
            logStore.append(raw: "保存配置失败：\(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - 选择与草稿

    func selectProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        // 切换选择即离开「新建草稿」编辑态，编辑器需跟随展示被选服务器
        editorIsNewDraft = false
        currentProfileId = id
        persist()
        logStore.append(raw: "切换当前服务器：\(profiles.first { $0.id == id }?.name ?? "?")", level: .info, profileId: id)
    }

    /// 新 profile 的编辑初值。不含真实服务器默认值（约束：示例不得内置为默认）。
    func makeNewProfileDraft() -> ServerProfile {
        ServerProfile(
            name: "新服务器 \(profiles.count + 1)",
            host: "",
            sshPort: 22,
            username: "",
            remotePort: 17891
        )
    }

    func requestCreateProfile() {
        editorIsNewDraft = true
    }

    /// 编辑器保存草稿。校验失败的非法配置拒绝保存（U06「拒绝保存」半边）。
    @discardableResult
    func saveDraftProfile(_ profile: ServerProfile) -> Bool {
        let validation = ServerProfileRule.validate(profile)
        guard validation.isValid else {
            logStore.append(
                raw: "服务器「\(profile.name)」配置未通过校验，已拒绝保存：\(validation.errors.joined(separator: "；"))",
                level: .error, profileId: profile.id
            )
            return false
        }
        editorIsNewDraft = false
        upsert(profile)
        currentProfileId = profile.id
        persist()
        if let conflict = remotePortConflictDescription(for: profile) {
            logStore.append(raw: "端口冲突提示：\(conflict)", level: .warning, profileId: profile.id)
        }
        return true
    }

    /// 放弃草稿。
    func discardDraft() {
        editorIsNewDraft = false
    }

    // MARK: - CRUD

    /// F02「端口冲突提示」：同主机同远程监听端口会互相顶掉远端监听。
    func remotePortConflictDescription(for profile: ServerProfile) -> String? {
        func ports(_ profile: ServerProfile) -> Set<Int> {
            switch profile.connectionMode {
            case .automatic:
                var result: Set<Int> = [profile.remotePort, profile.remoteSocksPort]
                if profile.httpAdapterEnabled { result.insert(profile.remoteHTTPPort) }
                return result
            case .staticForward:
                var result: Set<Int> = [profile.remotePort]
                if profile.httpAdapterEnabled { result.insert(profile.remoteHTTPPort) }
                return result
            case .reverseDynamic:
                var result: Set<Int> = [profile.remoteSocksPort]
                if profile.httpAdapterEnabled { result.insert(profile.remoteHTTPPort) }
                return result
            }
        }
        let requestedPorts = ports(profile)
        let conflicts = profiles.filter {
            $0.id != profile.id && $0.host == profile.host && !ports($0).isDisjoint(with: requestedPorts)
        }
        guard !conflicts.isEmpty else { return nil }
        let overlappingPorts = Set(conflicts.flatMap { ports($0).intersection(requestedPorts) })
        let portsText = overlappingPorts.sorted().map(String.init).joined(separator: "、")
        return "「\(profile.name)」与 \(conflicts.map(\.name).joined(separator: "、")) 在同一 SSH 主机上占用重叠的远程端口（\(portsText)），同时连接会互相失败"
    }

    /// 新增或更新。若目标 profile 存在活跃连接，则按规范提示需要重连。
    func upsert(_ profile: ServerProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            let old = profiles[idx]
            profiles[idx] = profile
            let connectionRelevantChange = old.host != profile.host
                || old.sshPort != profile.sshPort
                || old.username != profile.username
                || old.authMode != profile.authMode
                || old.identityFilePath != profile.identityFilePath
                || old.remotePort != profile.remotePort
                || old.remoteSocksPort != profile.remoteSocksPort
                || old.remoteHTTPPort != profile.remoteHTTPPort
                || old.connectionMode != profile.connectionMode
                || old.httpAdapterEnabled != profile.httpAdapterEnabled
                || old.relayPort != profile.relayPort
            if connectionRelevantChange,
               var snap = snapshot(profile.id), snap.phase == .connected || snap.phase == .degraded {
                snap.phase = .degraded
                snap.humanReadableDetail = "配置已修改，需断开后重连才能生效（当前隧道仍使用旧配置）"
                applySnapshot(snap)
                logStore.append(raw: "服务器「\(profile.name)」连接参数已修改，需要手动重连", level: .warning, profileId: profile.id)
            }
            logStore.append(raw: "已保存服务器「\(profile.name)」", level: .success, profileId: profile.id)
        } else {
            profiles.append(profile)
            onProfileAdded(profile.id)
            if currentProfileId == nil { currentProfileId = profile.id }
            logStore.append(raw: "新增服务器「\(profile.name)」", level: .success, profileId: profile.id)
        }
        updateReconnectPreference(profile.id, profile.reconnectEnabled, profile.rememberPassword)
        persist()
    }

    /// 删除前的安全检查：活跃连接先断开（由本 App 管理的进程）。
    func delete(_ id: UUID) {
        onProfileRemoving(id) // 宿主：断开隧道、清密码/通知/快照/冲突卡等会话侧状态
        let name = profiles.first { $0.id == id }?.name ?? "?"
        profiles.removeAll { $0.id == id }
        if currentProfileId == id {
            currentProfileId = profiles.first?.id
        }
        logStore.append(raw: "已删除服务器「\(name)」", level: .warning, profileId: id)
        persist()
    }

    // MARK: - ~/.ssh/config 导入

    /// 可导入的 ssh config 条目；文件不存在返回 nil。
    func availableSSHConfigEntries() -> [SSHConfigEntry]? {
        SSHConfigParser.loadDefaultConfig()
    }

    /// 导入选中的条目为服务器（校验失败或与既有配置重复的跳过）。返回成功导入数。
    @discardableResult
    func importSSHConfigEntries(_ entries: [SSHConfigEntry]) -> Int {
        var imported = 0
        for entry in entries {
            var profile = ServerProfile(
                name: entry.alias,
                host: entry.hostName ?? entry.alias,
                sshPort: entry.port ?? 22,
                username: entry.user ?? "",
                remotePort: 17891
            )
            if let identity = entry.identityFile {
                profile.authMode = .identityFile
                profile.identityFilePath = identity
            }
            guard ServerProfileRule.validate(profile).isValid else { continue }
            guard !profiles.contains(where: {
                $0.host == profile.host && $0.sshPort == profile.sshPort && $0.username == profile.username
            }) else { continue }
            upsert(profile)
            imported += 1
        }
        if imported > 0 {
            logStore.append(raw: "从 ~/.ssh/config 导入 \(imported) 台服务器（仅 HostName/Port/User/IdentityFile，不含其他指令）", level: .success)
        }
        return imported
    }
}
