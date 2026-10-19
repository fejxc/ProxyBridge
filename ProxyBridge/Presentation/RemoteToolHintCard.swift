import SwiftUI

/// 远端依赖缺失提示卡（P2）：从「如实报障」到「给出下一步」。
/// 缺 curl / Privoxy 时提供安装指引复制 + 一键重试验证（App 不代装软件）。
@MainActor
struct RemoteToolHintCard: View {
    let tool: RemoteCommandTemplate.RemoteTool
    let onRetry: () -> Void
    let onCopy: () -> Void

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.orange)
                    Text(L10n.t("远端缺少 ") + tool.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                Text(tool == .curl
                     ? "端到端验证需要在服务器上运行 curl；缺少它时连接只能显示「未验证 ≠ 可用」。复制下方指引安装后重试验证。"
                     : "Codex HTTP 兼容入口需要服务器上的 Privoxy（SOCKS5 不受影响）。复制指引安装后重试验证；App 不会替你安装软件。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        onCopy()
                    } label: {
                        Label(L10n.t("复制安装指引"), systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    Button {
                        onRetry()
                    } label: {
                        Label(L10n.t("已安装，重试验证"), systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("远端缺少 ") + tool.displayName)
    }
}
