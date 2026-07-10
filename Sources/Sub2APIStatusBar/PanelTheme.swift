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
}

enum ClaudeTheme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let header = Color(nsColor: .windowBackgroundColor)
    static let footer = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let elevatedCard = Color(nsColor: .controlBackgroundColor)
    static let tabBackground = Color(nsColor: .controlBackgroundColor)
    static let tabSelected = Color(nsColor: .controlAccentColor).opacity(0.16)
    static let border = Color(nsColor: .separatorColor).opacity(0.55)
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let muted = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color(nsColor: .controlAccentColor)
    static let success = Color(nsColor: .systemGreen)
    static let slate = Color(nsColor: .systemGray)
    static let sand = Color(nsColor: .systemTeal)
    static let gold = Color(nsColor: .systemYellow)
    static let warm = Color(nsColor: .systemPink)
    static let ink = Color(nsColor: .systemIndigo)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let textFieldBackground = Color(nsColor: .textBackgroundColor)
    static let avatarBackground = Color(nsColor: .controlAccentColor)
    static let avatarForeground = Color.white
}

extension View {
    func appAppearance(_ appearance: AppAppearance) -> some View {
        preferredColorScheme(appearance.preferredColorScheme)
    }

    func themedTextField() -> some View {
        self
            .textFieldStyle(.roundedBorder)
    }
}

struct PanelBackground: View {
    var body: some View {
        ClaudeTheme.background
            .ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        .padding(10)
        .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ClaudeTheme.primaryText)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(ClaudeTheme.secondaryText)
                .lineLimit(1)
        }
        .frame(minHeight: 42, alignment: .leading)
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
