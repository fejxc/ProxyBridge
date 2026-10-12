import SwiftUI

@main
struct ProxyBridgeEntry {
    static func main() {
        SSHProcessLauncher.runPTYChildIfRequested()
        ProxyBridgeApp.main()
    }
}

struct ProxyBridgeApp: App {
    /// 生产装配：系统代理检测与 SSH 隧道。
    @State private var model = AppViewModel.live()

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

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
