import SwiftUI
import AppKit
import Carbon

@main
@MainActor
struct ProxyBridgeEntry {
    static func main() {
        // 单实例锁必须在 App 装配之前获取：ProxyBridgeApp.init 会同步跑 bootstrap
        // （恢复中断的更新换位、读盘、SCDynamicStore 注册、curl 探测），锁若等到
        // applicationDidFinishLaunching 才获取，双开时第二个实例已完整执行过这些
        // 副作用才退出，与首个实例产生竞态。
        guard SingleInstanceGuard.acquire() else {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name(SingleInstanceGuard.activateNotificationName),
                object: nil, deliverImmediately: true
            )
            exit(0)
        }
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
        // 锁已在 ProxyBridgeEntry.main() 获取；这里只登记「第二个实例请求激活」，
        // 打开设置窗把用户带回前台。
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
                styleMask: [.titled, .fullSizeContentView, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "ProxyBridge"
            // 标题栏透明 + 内容延伸到标题栏下方：侧栏的玻璃材质才会占据整个左列，
            // 否则标题栏是一条不透明的灰条，窗口看起来没有通透感
            window.titlebarAppearsTransparent = true
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
