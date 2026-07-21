import AppKit
import SwiftUI
import Sub2APIStatusCore

extension AppAppearance {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }

    static func resolved(from effectiveAppearance: NSAppearance) -> AppAppearance {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

enum ClaudeTheme {
    static let background = adaptiveColor(
        light: NSColor(srgbRed: 0.965, green: 0.972, blue: 0.985, alpha: 0.72),
        dark: NSColor(srgbRed: 0.055, green: 0.062, blue: 0.078, alpha: 0.82)
    )
    static let header = adaptiveColor(
        light: NSColor.white.withAlphaComponent(0.38),
        dark: NSColor.white.withAlphaComponent(0.035)
    )
    static let footer = adaptiveColor(
        light: NSColor.white.withAlphaComponent(0.32),
        dark: NSColor.white.withAlphaComponent(0.025)
    )
    static let card = adaptiveColor(
        light: NSColor.white.withAlphaComponent(0.64),
        dark: NSColor.white.withAlphaComponent(0.065)
    )
    static let elevatedCard = adaptiveColor(
        light: NSColor.white.withAlphaComponent(0.86),
        dark: NSColor.white.withAlphaComponent(0.105)
    )
    static let tabBackground = adaptiveColor(
        light: NSColor.white.withAlphaComponent(0.36),
        dark: NSColor.black.withAlphaComponent(0.12)
    )
    static let tabSelected = adaptiveColor(
        light: NSColor.white.withAlphaComponent(0.84),
        dark: NSColor.white.withAlphaComponent(0.11)
    )
    static let border = adaptiveColor(
        light: NSColor.black.withAlphaComponent(0.075),
        dark: NSColor.white.withAlphaComponent(0.10)
    )
    static let glassBorder = adaptiveColor(
        light: NSColor.black.withAlphaComponent(0.095),
        dark: NSColor.white.withAlphaComponent(0.13)
    )
    static let panelSheen = adaptiveColor(
        light: NSColor.white.withAlphaComponent(0.34),
        dark: NSColor.white.withAlphaComponent(0.055)
    )
    static let glassShadow = adaptiveColor(
        light: NSColor.black.withAlphaComponent(0.065),
        dark: NSColor.black.withAlphaComponent(0.28)
    )
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let muted = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color(nsColor: .controlAccentColor)
    static let success = adaptiveColor(
        light: NSColor(srgbRed: 0.16, green: 0.52, blue: 0.34, alpha: 1),
        dark: NSColor(srgbRed: 0.35, green: 0.74, blue: 0.51, alpha: 1)
    )
    static let slate = Color(nsColor: .systemGray)
    static let sand = Color(nsColor: .systemTeal)
    static let gold = adaptiveColor(
        light: NSColor(srgbRed: 0.66, green: 0.50, blue: 0.14, alpha: 1),
        dark: NSColor(srgbRed: 0.82, green: 0.66, blue: 0.28, alpha: 1)
    )
    static let warm = Color(nsColor: .systemPink)
    static let ink = Color(nsColor: .systemIndigo)
    static let warning = adaptiveColor(
        light: NSColor(srgbRed: 0.70, green: 0.43, blue: 0.10, alpha: 1),
        dark: NSColor(srgbRed: 0.88, green: 0.59, blue: 0.24, alpha: 1)
    )
    static let danger = adaptiveColor(
        light: NSColor(srgbRed: 0.70, green: 0.24, blue: 0.24, alpha: 1),
        dark: NSColor(srgbRed: 0.90, green: 0.43, blue: 0.42, alpha: 1)
    )
    static let textFieldBackground = adaptiveColor(
        light: NSColor.white.withAlphaComponent(0.70),
        dark: NSColor.white.withAlphaComponent(0.075)
    )
    static let progressTrack = adaptiveColor(
        light: NSColor.black.withAlphaComponent(0.075),
        dark: NSColor.white.withAlphaComponent(0.10)
    )
    static let avatarBackground = Color(nsColor: .controlAccentColor)
    static let avatarForeground = Color.white

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

enum PanelMetrics {
    static let badgeCornerRadius: CGFloat = 6
}

extension View {
    func appAppearance(_ appearance: AppAppearance) -> some View {
        preferredColorScheme(appearance.preferredColorScheme)
    }

    func themedTextField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(ClaudeTheme.textFieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ClaudeTheme.glassBorder, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: ClaudeTheme.glassShadow.opacity(0.45), radius: 2, y: 1)
    }

    func glassSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(
            GlassSurfaceModifier(
                cornerRadius: cornerRadius
            )
        )
    }
}

struct PanelBackground: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    ClaudeTheme.panelSheen,
                    ClaudeTheme.background,
                    ClaudeTheme.accent.opacity(0.012),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(ClaudeTheme.card, in: shape)
            .overlay {
                shape
                    .stroke(ClaudeTheme.glassBorder, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassSurface()
    }
}

struct MessageRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .glassSurface(cornerRadius: 10)
    }
}

struct SectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(ClaudeTheme.primaryText)
            GlassCard {
                content
            }
        }
    }
}

struct PanelPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(ClaudeTheme.primaryText)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(ClaudeTheme.secondaryText)
                .lineLimit(1)
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.callout)
    }
}

struct GlassSegmentedItem<Value: Equatable> {
    let value: Value
    let title: String
    var systemImage: String?
}

struct GlassSegmentedControl<Value: Equatable>: View {
    @Binding var selection: Value
    let items: [GlassSegmentedItem<Value>]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                segment(item)
            }
        }
        .padding(4)
        .background(ClaudeTheme.tabBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ClaudeTheme.glassBorder, lineWidth: 0.75)
                .allowsHitTesting(false)
        }
    }

    private func segment(_ item: GlassSegmentedItem<Value>) -> some View {
        let isSelected = selection == item.value

        return Button {
            selection = item.value
        } label: {
            HStack(spacing: 6) {
                if let systemImage = item.systemImage {
                    SafeSystemImage(systemName: systemImage, fallbackName: "circle")
                        .font(.system(size: 12, weight: .medium))
                }
                Text(item.title)
                    .lineLimit(1)
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? ClaudeTheme.primaryText : ClaudeTheme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                isSelected ? ClaudeTheme.tabSelected : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? ClaudeTheme.glassBorder : Color.clear, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct GlassCheckbox: View {
    @Binding var isOn: Bool
    let title: String
    var compact = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: compact ? 6 : 8) {
                SafeSystemImage(
                    systemName: isOn ? "checkmark.square.fill" : "square",
                    fallbackName: "square"
                )
                .font(.system(size: compact ? 13 : 14, weight: .medium))
                .foregroundStyle(isOn ? ClaudeTheme.accent : ClaudeTheme.secondaryText)

                Text(title)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(ClaudeTheme.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 22 : 26, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "1" : "0")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct GlassProgressBar: View {
    let value: Double
    let tint: Color
    var height: CGFloat = 6

    private var normalizedValue: Double {
        min(max(value, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(ClaudeTheme.progressTrack)
                Capsule()
                    .fill(tint.opacity(0.82))
                    .frame(width: progressWidth(in: proxy.size.width))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text(String(format: "%.0f%%", normalizedValue * 100)))
    }

    private func progressWidth(in availableWidth: CGFloat) -> CGFloat {
        guard normalizedValue > 0 else {
            return 0
        }
        return max(height, availableWidth * normalizedValue)
    }
}

struct StatusPill: View {
    let title: String
    let tint: Color
    var systemImage: String?

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: PanelMetrics.badgeCornerRadius,
            style: .continuous
        )

        HStack(spacing: 4) {
            if let systemImage {
                SafeSystemImage(systemName: systemImage, fallbackName: "circle")
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.08), in: shape)
        .overlay {
            shape
                .stroke(tint.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

struct GlassLoadingState: View {
    let message: String

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.callout)
                .foregroundStyle(ClaudeTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .glassSurface()
    }
}

struct GlassEmptyState: View {
    let title: String
    let systemImage: String
    var minHeight: CGFloat = 104

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(ClaudeTheme.slate.opacity(0.07))
                SafeSystemImage(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ClaudeTheme.slate)
            }
            .frame(width: 34, height: 34)

            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(ClaudeTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .glassSurface()
    }
}

struct SafeSystemImage: View {
    let systemName: String
    var fallbackName = "circle.grid.3x3.fill"

    var body: some View {
        if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: nil) {
            Image(nsImage: image)
                .renderingMode(.template)
        } else {
            Image(systemName: "questionmark.circle")
        }
    }
}
