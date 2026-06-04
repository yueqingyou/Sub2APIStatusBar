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
    static let background = LinearGradient(
        colors: [
            adaptive(light: rgb(0.992, 0.970, 0.930), dark: rgb(0.055, 0.060, 0.064)),
            adaptive(light: rgb(0.965, 0.925, 0.858), dark: rgb(0.090, 0.086, 0.078)),
            adaptive(light: rgb(0.940, 0.868, 0.780), dark: rgb(0.130, 0.106, 0.086)),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let header = adaptive(light: rgb(0.982, 0.950, 0.900), dark: rgb(0.105, 0.104, 0.098))
    static let footer = adaptive(light: rgb(0.965, 0.930, 0.878), dark: rgb(0.085, 0.082, 0.076))
    static let card = adaptive(light: rgb(1.000, 0.978, 0.934), dark: rgb(0.150, 0.143, 0.132))
    static let elevatedCard = adaptive(light: rgb(0.992, 0.950, 0.880), dark: rgb(0.180, 0.170, 0.156))
    static let tabBackground = adaptive(light: rgb(0.930, 0.875, 0.790), dark: rgb(0.115, 0.110, 0.102))
    static let tabSelected = adaptive(light: rgb(1.000, 0.970, 0.905), dark: rgb(0.245, 0.222, 0.196))
    static let border = adaptive(light: rgb(0.55, 0.44, 0.31), dark: rgb(0.82, 0.76, 0.66)).opacity(0.22)
    static let primaryText = adaptive(light: rgb(0.180, 0.145, 0.105), dark: rgb(0.94, 0.91, 0.86))
    static let secondaryText = adaptive(light: rgb(0.460, 0.395, 0.310), dark: rgb(0.66, 0.62, 0.55))
    static let muted = adaptive(light: rgb(0.560, 0.480, 0.380), dark: rgb(0.62, 0.59, 0.52))
    static let accent = adaptive(light: rgb(0.760, 0.310, 0.145), dark: rgb(0.86, 0.38, 0.19))
    static let success = adaptive(light: rgb(0.500, 0.410, 0.245), dark: rgb(0.71, 0.58, 0.38))
    static let slate = adaptive(light: rgb(0.400, 0.470, 0.480), dark: rgb(0.55, 0.60, 0.60))
    static let sand = adaptive(light: rgb(0.650, 0.500, 0.315), dark: rgb(0.72, 0.62, 0.48))
    static let gold = adaptive(light: rgb(0.760, 0.450, 0.160), dark: rgb(0.84, 0.58, 0.29))
    static let warm = adaptive(light: rgb(0.760, 0.340, 0.160), dark: rgb(0.82, 0.45, 0.25))
    static let ink = adaptive(light: rgb(0.410, 0.320, 0.245), dark: rgb(0.64, 0.55, 0.46))
    static let warning = adaptive(light: rgb(0.780, 0.440, 0.120), dark: rgb(0.86, 0.58, 0.22))
    static let danger = adaptive(light: rgb(0.760, 0.190, 0.160), dark: rgb(0.86, 0.31, 0.25))
    static let textFieldBackground = adaptive(light: rgb(1.000, 0.988, 0.952), dark: rgb(0.060, 0.058, 0.054))
    static let avatarBackground = LinearGradient(
        colors: [
            adaptive(light: rgb(0.880, 0.570, 0.330), dark: rgb(0.70, 0.48, 0.30)),
            adaptive(light: rgb(0.650, 0.350, 0.210), dark: rgb(0.42, 0.30, 0.22)),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let avatarForeground = adaptive(light: rgb(1.000, 0.955, 0.880), dark: rgb(0.98, 0.90, 0.78))

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return dark
            }
            return light
        })
    }
}

extension View {
    func appAppearance(_ appearance: AppAppearance) -> some View {
        preferredColorScheme(appearance.preferredColorScheme)
    }

    func themedTextField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ClaudeTheme.textFieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ClaudeTheme.border, lineWidth: 1)
            )
    }
}

struct PanelBackground: View {
    var body: some View {
        ZStack {
            ClaudeTheme.background

            Circle()
                .fill(ClaudeTheme.accent.opacity(0.12))
                .frame(width: 150, height: 150)
                .offset(x: 250, y: -255)

            Circle()
                .fill(ClaudeTheme.sand.opacity(0.10))
                .frame(width: 130, height: 130)
                .offset(x: -250, y: 255)
        }
        .ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(ClaudeTheme.border, lineWidth: 1)
            )
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
        .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ClaudeTheme.border, lineWidth: 1)
        )
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
