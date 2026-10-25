import SwiftUI

/// 主机指纹核对卡（P0 首次连接引导）：ssh-keyscan 获取指纹 → 用户核对 →
/// 写入 known_hosts 并自动重连。密码卡同款布局，面板与设置窗口共用。
@MainActor
struct HostKeyTrustCard: View {
    @Environment(AppViewModel.self) private var model

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "fingerprint")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.orange)
                    Text(L10n.t("「") + (model.pendingHostKeyProfileName ?? L10n.t("服务器")) + L10n.t("」是首次连接"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                }
                Text(L10n.t("本机尚无该服务器的主机密钥记录。请在下方获取指纹，并通过可信渠道（服务器管理员、云控制台）核对一致后再信任；不匹配说明连接可能被劫持，请勿继续。"))
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                switch model.hostKeyScan {
                case .idle:
                    HStack(spacing: 8) {
                        Button {
                            model.requestHostKeyScan()
                        } label: {
                            Label(L10n.t("获取主机指纹（ssh-keyscan）"), systemImage: "waveform.path.ecg")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        Button(L10n.t("暂不处理"), role: .destructive) {
                            model.dismissHostKeyPrompt()
                        }
                        .controlSize(.large)
                        .buttonStyle(.bordered)
                    }
                case .scanning:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("正在获取主机指纹…")).font(.subheadline)
                    }
                case .failed(let reason):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(Palette.red)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button(L10n.t("重试获取")) { model.requestHostKeyScan() }
                                .controlSize(.large)
                                .buttonStyle(.bordered)
                            Button(L10n.t("暂不处理"), role: .destructive) {
                                model.dismissHostKeyPrompt()
                            }
                            .controlSize(.large)
                            .buttonStyle(.bordered)
                        }
                    }
                case .fetched(let records):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(records, id: \.keyType) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.keyType)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Palette.muted)
                                MonoText(text: record.fingerprint, size: 10.5)
                            }
                        }
                        HStack(spacing: 8) {
                            Button {
                                model.confirmHostKeyAndReconnect()
                            } label: {
                                Label(L10n.t("指纹一致，信任并重连"), systemImage: "checkmark.seal")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)
                            Button(L10n.t("不一致，放弃"), role: .destructive) {
                                model.dismissHostKeyPrompt()
                            }
                            .controlSize(.large)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("核对服务器主机指纹"))
    }
}
