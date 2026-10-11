import SwiftUI

@main
struct ProxyBridgeApp: App {
    /// 生产装配：本地代理检测为真实实现；SSH 隧道在阶段 C 前为 Mock。
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
