import SwiftUI

/// 远端端口冲突诊断卡：显示占用者清单，用户确认后仅清理「自家残留」
/// （同用户僵尸 sshd / 带 App token 的孤儿 Privoxy），他人进程只报告。
@MainActor
struct RemotePortConflictCard: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles.and.bubbles")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.orange)
                    Text(L10n.t("「") + (model.portConflictProfileName ?? L10n.t("服务器")) + L10n.t("」远端端口被占用"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                }

                switch model.portConflict?.state {
                case .inspecting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("正在经 SSH 诊断端口占用…")).font(.subheadline)
                    }
                case .unavailable(let reason):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(Palette.red)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button(L10n.t("重试诊断")) { model.reinspectRemoteResidue() }
                                .buttonStyle(.bordered)
                            Button(L10n.t("忽略"), role: .destructive) { model.dismissPortConflictCard() }
                                .buttonStyle(.bordered)
                        }
                    }
                case .cleaning:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("正在清理远端残留…")).font(.subheadline)
                    }
                case .report(let holdings):
                    report(holdings)
                case nil:
                    EmptyView()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("远端端口冲突诊断")
    }

    @ViewBuilder
    private func report(_ holdings: [RemotePortHolding]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(holdings) { holding in
                HStack(spacing: 8) {
                    MonoText(text: "127.0.0.1:\(holding.port)", weight: .medium, size: 10.5)
                    Spacer(minLength: 4)
                    Text(holding.pid > 0
                         ? "PID \(holding.pid) · \(holding.comm)"
                         : L10n.t("内核残留（无进程）"))
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                    MetaLine(text: badgeText(for: holding.kind), tone: badgeTone(for: holding.kind))
                }
            }
            Text(L10n.t("仅清理同用户的僵尸 sshd 与本 App 的孤儿 Privoxy；其他进程不会被触碰。"))
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if holdings.contains(where: { $0.kind.isCleanable }) {
                    Button {
                        model.cleanRemoteResidueAndReconnect()
                    } label: {
                        Label(L10n.t("清理残留并重连"), systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                Button(L10n.t("重新诊断")) { model.reinspectRemoteResidue() }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
                Button(L10n.t("忽略"), role: .destructive) { model.dismissPortConflictCard() }
                    .controlSize(.large)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func badgeText(for kind: RemotePortHolding.Kind) -> String {
        switch kind {
        case .staleSSHD: return L10n.t("僵尸 sshd · 可清理")
        case .ownedPrivoxy: return L10n.t("孤儿 Privoxy · 可清理")
        case .residual: return L10n.t("TIME_WAIT 残留 · 约 60s 过期")
        case .busy: return L10n.t("有活连接 · 不清理")
        case .thirdParty: return L10n.t("其他进程 · 不清理")
        }
    }

    private func badgeTone(for kind: RemotePortHolding.Kind) -> StatusTone {
        switch kind {
        case .staleSSHD, .ownedPrivoxy: return .orange
        case .residual, .busy, .thirdParty: return .gray
        }
    }
}
