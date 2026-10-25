import SwiftUI
import AppKit

// MARK: - 设计令牌（Apple 原生语义：系统语义色 + 语义字阶）
//
// 颜色全部映射到系统语义色：自动跟随浅色/深色外观、增强对比度设置与系统强调色，
// 不再手工维护两套 hex。状态色用系统四色，与系统控件视觉一致；中性色对应
// label / secondaryLabel / separator / controlBackgroundColor 等系统语义。
//
// 字阶使用语义字阶（title3 / body / callout / subheadline / footnote / caption2），
// 不再手工指定字号——原生应用的字号是离散有节奏的，且语义字阶免费获得文本大小
// 偏好缩放。等宽数据（IP/端口）经 MonoText 保留参数化字号，属数据表格惯例。

enum Palette {
    // 状态色（系统四色）
    static let blue = Color(nsColor: .systemBlue)
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    // 中性色（系统语义色）
    static let ink = Color.primary
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let softFill = Color(nsColor: .quaternaryLabelColor)

    /// 状态色调 → 颜色。
    static func tone(_ tone: StatusTone) -> Color {
        switch tone {
        case .gray: return muted
        case .blue: return blue
        case .green: return green
        case .orange: return orange
        case .red: return red
        }
    }

    /// 自愈状态色：迁移 magpie Routing 面板的 wait/green/red 语义。
    static func recoveryTone(_ decision: TunnelRecoveryDecision) -> StatusTone {
        switch decision.state {
        case .scheduled, .executed: return .blue
        case .succeeded: return .green
        case .budgetExhausted: return .orange
        }
    }
}

// MARK: - 复用组件

/// 分区卡（系统设置的分组样式：控件底色 + 圆角，无描边——
/// 分组层次靠底色与间距表达，不靠线框叠加）。
@MainActor
struct SectionCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.ink)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// 状态胶囊（颜色 + 文本，永远成对出现）。面板内只保留顶部一个。
@MainActor
struct StatusTag: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Palette.tone(tone))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.tone(tone))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Palette.tone(tone).opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("状态：\(text)")
    }
}

/// 元信息行（原 MiniBadge 胶囊的极简替代）：仅次级文本，状态语义由可选色点表达。
@MainActor
struct MetaLine: View {
    let text: String
    var tone: StatusTone? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let tone {
                Circle()
                    .fill(Palette.tone(tone))
                    .frame(width: 5, height: 5)
            }
            Text(text)
                .font(.caption2)
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 三层健康检查行（图标 + 主文案 + 次文案）。
@MainActor
struct HealthCheckRow: View {
    let title: String
    let display: HealthCheckDisplay
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(fillColor)
                Image(systemName: display.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(detail)")
    }

    private var fillColor: Color {
        switch display {
        case .ok: return Palette.green
        case .unknown: return Palette.orange
        case .failed: return Palette.red.opacity(0.75)
        }
    }
}

/// 表单行：左标签（+说明）贴左缘、右控件靠右的显式布局。
/// 不用 LabeledContent——macOS 上它把标签朝控件对齐，左边缘参差。
@MainActor
struct FormRow<Control: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(Palette.ink)
                if let help {
                    Text(help)
                        .font(.caption2)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 3)
    }
}

/// 等宽数字文本（IP/端口）。数据保留参数化字号（表格惯例），非展示文本。
@MainActor
struct MonoText: View {
    let text: String
    var weight: Font.Weight = .semibold
    var size: CGFloat = 12

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// 提示信息块（原型 infoBlock；柔和底色，无描边）。
@MainActor
struct InfoBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.footnote)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.muted)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
