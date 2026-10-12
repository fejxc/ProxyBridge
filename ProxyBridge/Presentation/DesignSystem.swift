import SwiftUI
import AppKit

// MARK: - 设计令牌（03-UI-SPEC §1；深浅色自适应）

enum Palette {
    /// 动态 NSColor：浅色/深色分别提供。
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: dynamic(light: NSColor(rgb: light), dark: NSColor(rgb: dark)))
    }

    // 状态色（浅 / 深）
    static let blue = color(light: 0x2563EB, dark: 0x5B8DEF)
    static let green = color(light: 0x159A64, dark: 0x2FB886)
    static let orange = color(light: 0xD58A28, dark: 0xE0A34E)
    static let red = color(light: 0xC84646, dark: 0xE06161)
    // 中性色
    static let ink = color(light: 0x172338, dark: 0xE6EBF2)
    static let muted = color(light: 0x64748B, dark: 0x93A0B4)
    static let background = color(light: 0xF6F8FB, dark: 0x1C2230)
    static let surface = color(light: 0xFFFFFF, dark: 0x242B3A)
    static let border = color(light: 0xE3E8EF, dark: 0x333C4D)
    static let softFill = color(light: 0xF8FAFC, dark: 0x2A3244)

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
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

// MARK: - 复用组件

/// 卡片容器（圆角 10、细描边）。
struct SectionCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
    }
}

/// 状态胶囊标签（颜色 + 文本，永远成对出现）。
struct StatusTag: View {
    let text: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Palette.tone(tone))
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11, weight: .bold))
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

/// 三层健康检查行（图标 + 主文案 + 次文案）。
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
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.system(size: 11))
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

/// 表单行：左标签 + 右控件。
struct FormRow<Control: View>: View {
    let label: String
    var help: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                control
                if let help {
                    Text(help)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 等宽数字文本（IP/端口）。
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

/// 提示信息块（原型 infoBlock）。
struct InfoBlock: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.muted)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.softFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Palette.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
