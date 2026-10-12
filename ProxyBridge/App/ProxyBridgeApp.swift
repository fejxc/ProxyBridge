import SwiftUI
import AppKit
import Carbon

@main
@MainActor
struct ProxyBridgeEntry {
    static func main() {
        SSHProcessLauncher.runPTYChildIfRequested()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
