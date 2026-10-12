import SwiftUI

/// SSH 密码输入卡（密码模式）：菜单栏面板与设置窗口共用，
/// 确保用户无论盯着哪个窗口都能看到密码请求。
struct PasswordPromptCard: View {
    @Environment(AppViewModel.self) private var model

    @State private var passwordInput = ""
    @State private var rememberInput = false

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.orange)
                    Text("「\(model.pendingPasswordProfileName ?? "服务器")」需要 SSH 密码")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                Text("密码仅用于本次连接（经系统 PTY 交给 ssh）；勾选「记住」则存入本机钥匙串，之后自动登录。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("记住密码（本机钥匙串）", isOn: $rememberInput)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10.5))
                HStack(spacing: 8) {
                    SecureField("SSH 密码", text: $passwordInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                    Button("提交", action: submit)
                        .buttonStyle(.borderedProminent)
                        .disabled(passwordInput.isEmpty)
                    Button("取消", role: .destructive) {
                        passwordInput = ""
                        rememberInput = false
                        model.cancelPasswordPrompt()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .onChange(of: model.pendingPasswordProfileId) { _, _ in
            passwordInput = ""
            rememberInput = false
        }
        .onDisappear {
            passwordInput = ""
            rememberInput = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("输入 SSH 密码")
    }

    private func submit() {
        guard !passwordInput.isEmpty else { return }
        let input = passwordInput
        let remember = rememberInput
        passwordInput = ""
        rememberInput = false
        model.submitPassword(input, remember: remember)
    }
}
