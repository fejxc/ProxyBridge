import AppKit
import ServiceManagement
import UserNotifications

@MainActor
protocol AppSystemIntegrating: AnyObject {
    var onSleep: (() -> Void)? { get set }
    var onWake: (() -> Void)? { get set }
    var loginState: LoginItemState { get }
    func setLoginEnabled(_ enabled: Bool) async throws
    func notificationPermission(request: Bool) async throws -> NotificationPermission
    func postNotification(profileID: UUID, body: String) async throws
    func clearNotifications()
    func stopObserving()
}

enum LoginItemState: Equatable {
    case disabled, enabled, requiresApproval, unavailable
    var description: String {
        switch self {
        case .disabled: return "未开启登录启动"
        case .enabled: return "已在系统注册，登录后启动应用"
        case .requiresApproval: return "等待系统授权：请到系统设置的「通用 → 登录项」确认"
        case .unavailable: return "系统未找到此应用；请先安装到 Applications"
        }
    }
}

enum NotificationPermission: Equatable, Sendable {
    case notDetermined, allowed, denied
    var description: String {
        switch self {
        case .notDetermined: return "尚未授权通知；点击「授权通知」后由系统询问"
        case .allowed: return "通知已授权；异常提醒会合并，避免重复打扰"
        case .denied: return "系统通知被关闭，可到系统设置的「通知 → ProxyBridge」修改"
        }
    }
}

@MainActor
final class AppSystemServices: AppSystemIntegrating {
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSleep?() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake?() }
        })
    }

    var loginState: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func setLoginEnabled(_ enabled: Bool) async throws {
        if enabled {
            if loginState != .enabled && loginState != .requiresApproval { try SMAppService.mainApp.register() }
        } else if loginState == .enabled || loginState == .requiresApproval {
            try await SMAppService.mainApp.unregister()
        }
    }

    func notificationPermission(request: Bool) async throws -> NotificationPermission {
        let center = UNUserNotificationCenter.current()
        let rawStatus: Int = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus.rawValue)
            }
        }
        let status = UNAuthorizationStatus(rawValue: rawStatus) ?? .denied
        if status == .notDetermined && request {
            return try await center.requestAuthorization(options: [.alert, .sound]) ? .allowed : .denied
        }
        switch status {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func postNotification(profileID: UUID, body: String) async throws {
        guard !Task.isCancelled, try await notificationPermission(request: false) == .allowed else { return }
        guard !Task.isCancelled else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "ProxyBridge 连接异常"
        content.body = body // Fixed wording: no server address, username or credential.
        content.sound = .default
        let id = "connection-\(profileID.uuidString)"
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        if Task.isCancelled {
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    func clearNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    func stopObserving() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }
}

/// Pure policy separates notification incidents from UI rendering.
struct ConnectionNotificationPolicy {
    var degradedDelay: TimeInterval = 60
    var cooldown: TimeInterval = 300
    private var lastSent: [UUID: Date] = [:]
    mutating func shouldSend(profileID: UUID, now: Date) -> Bool {
        if let previous = lastSent[profileID], now.timeIntervalSince(previous) < cooldown { return false }
        lastSent[profileID] = now
        return true
    }
    mutating func reset(profileID: UUID) { lastSent[profileID] = nil }
    static func message(for phase: TunnelPhase) -> String? {
        switch phase {
        case .authRequired: return "SSH 身份验证或服务器指纹需要处理，请打开应用查看。"
        case .error: return "SSH 连接失败，请打开应用查看原因。"
        case .degraded: return "代理连接持续未通过验证，请打开应用检查。"
        default: return nil
        }
    }
}
