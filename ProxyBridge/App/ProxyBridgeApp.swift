import SwiftUI
import AppKit
import Carbon

@main
@MainActor
struct ProxyBridgeEntry {
    static func main() {
        ProxyBridgeApp.main()
    }
}

@MainActor
struct ProxyBridgeApp: App {
    @NSApplicationDelegateAdaptor(ProxyBridgeAppDelegate.self) private var delegate
    @State private var model: AppViewModel

    init() {
        let live = AppViewModel.live()
        _model = State(initialValue: live)
        delegate.model = live
        live.showSettingsWindow = { [weak delegate] in delegate?.showSettings() }
        live.relaunchAfterUpdate = { [weak delegate] in delegate?.requestRelaunchAfterUpdate() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.menuBarSymbolName)
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel(Text("ProxyBridge：" + model.overallPresentation.title))
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.openSettings(tab: .servers) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class ProxyBridgeAppDelegate: NSObject, NSApplicationDelegate {
    var model: AppViewModel?
    private var settingsController: NSWindowController?
    /// 更新安装后退出时重启（见 relaunch()）。
    private var relaunchOnExit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例：已有实例 → 通知其激活（打开设置窗）并退出自身。
        // 锁由 flock 持有，崩溃时内核自动释放，无需清理。
        guard SingleInstanceGuard.acquire() else {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(SingleInstanceGuard.activateNotificationName),
                object: nil, deliverImmediately: true
            )
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(SingleInstanceGuard.activateNotificationName),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSettings() }
        }

        // 清扫上次实例崩溃遗留的孤儿 ssh（占远端端口的元凶之一），如实记录
        let orphans = LocalOrphanSweeper.sweep()
        if !orphans.isEmpty {
            let detail = orphans.map { "PID \($0.pid)" }.joined(separator: "、")
            model?.logStore.append(
                raw: "启动清扫：终止了上次实例遗留的孤儿 ssh（\(detail)），远端端口随之释放",
                level: .warning
            )
        }

        // Login items stay quiet; explicit launches provide visible feedback.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginItem = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
            || event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem))?.booleanValue == true
        if !loginItem { showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 更新安装完成后的重启：标记退出时重启。
    /// 新进程经 `sleep 1` 延迟启动，确保本实例已退出、单实例锁已释放。
    func requestRelaunchAfterUpdate() {
        relaunchOnExit = true
        NSApplication.shared.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
        guard relaunchOnExit, let executable = Bundle.main.executableURL else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; exec '\(executable.path)'"]
        try? task.run()
    }

    func showSettings() {
        guard let model else { return }
        if settingsController == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "ProxyBridge"
            window.identifier = NSUserInterfaceItemIdentifier("ProxyBridgeSettings")
            window.minSize = NSSize(width: 860, height: 600)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView().environment(model))
            window.center()
            settingsController = NSWindowController(window: window)
        }
        if settingsController?.window?.isMiniaturized == true { settingsController?.window?.deminiaturize(nil) }
        settingsController?.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }
}
