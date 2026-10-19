import Foundation

@MainActor
final class RuntimeTunnelSpy: TunnelService {
    var onEvent: (@MainActor (TunnelEvent) -> Void)?
    var connections: [TunnelConfiguration] = []
    var active: Set<UUID> = []
    var remoteChecks = 0
    var localChecks = 0
    var stops = 0
    func connect(configuration: TunnelConfiguration) {
        connections.append(configuration)
        active.insert(configuration.profile.id)
        var snapshot = TunnelSnapshot.idle(configuration.profile.id)
        snapshot.phase = .connecting
        onEvent?(.snapshot(snapshot))
    }
    func emit(_ snapshot: TunnelSnapshot) {
        if snapshot.sshProcessRunning { active.insert(snapshot.profileId) }
        else if snapshot.phase == .error || snapshot.phase == .authRequired { active.remove(snapshot.profileId) }
        onEvent?(.snapshot(snapshot))
    }
    func disconnect(profileID: UUID) { active.remove(profileID); onEvent?(.snapshot(.idle(profileID))) }
    func runHealthCheck(profileID: UUID) { remoteChecks += 1 }
    func runLocalHealthCheck(profileID: UUID) { localChecks += 1 }
    func isActive(profileID: UUID) -> Bool { active.contains(profileID) }
    func terminateAllSessions() { stops += 1; active.removeAll() }
    func submitPassword(profileID: UUID, password: String, remember: Bool) {}
    func cancelPasswordPrompt(profileID: UUID) { disconnect(profileID: profileID) }
}

@MainActor
final class RuntimeSystemSpy: AppSystemIntegrating {
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    var onNetworkRestored: (() -> Void)?
    var loginState: LoginItemState = .disabled
    var permission: NotificationPermission = .notDetermined
    var loginShouldFail = false
    var requests = 0
    var notifications: [String] = []
    var updateNotifications: [String] = []
    var networkRestoredCalls = 0
    func simulateNetworkRestored() {
        networkRestoredCalls += 1
        onNetworkRestored?()
    }
    func setLoginEnabled(_ enabled: Bool) async throws {
        if loginShouldFail { throw NSError(domain: "RuntimeTest", code: 1) }
        loginState = enabled ? .requiresApproval : .disabled
    }
    func notificationPermission(request: Bool) async throws -> NotificationPermission {
        if request { requests += 1; permission = .allowed }
        return permission
    }
    func postNotification(profileID: UUID, body: String) async throws {
        if permission == .allowed { notifications.append(body) }
    }
    func postUpdateNotification(version: String) async throws {
        if permission == .allowed { updateNotifications.append(version) }
    }
    func clearNotifications() { notifications.removeAll() }
    func stopObserving() {}
}
