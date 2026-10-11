import SwiftUI

@main
struct ProxyBridgeApp: App {
    /// 阶段 A：Mock 服务装配。阶段 B/C 在此替换为真实实现
    /// （LocalProxyDetector / SSH TunnelCoordinator），UI 不感知差异。
    @State private var model = AppViewModel.phaseADefault()

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
