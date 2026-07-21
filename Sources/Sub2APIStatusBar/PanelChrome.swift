import SwiftUI

struct PanelFooter: View {
    @ObservedObject var model: MonitorViewModel
    let strings: AppStrings

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.openDashboard()
            } label: {
                Label(strings.phrase("打开控制台", "Open"), systemImage: "safari")
            }
            .disabled(model.config.baseURL.isEmpty)

            Spacer()

            Button {
                model.quit()
            } label: {
                Label(strings.phrase("退出", "Quit"), systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption.weight(.medium))
        .foregroundStyle(ClaudeTheme.secondaryText)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(ClaudeTheme.footer)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ClaudeTheme.border)
                .frame(height: 0.5)
                .allowsHitTesting(false)
        }
    }
}

enum PanelPage: String, Identifiable, Equatable {
    case overview
    case accounts
    case tasks
    case settings

    var id: String { rawValue }

    func title(strings: AppStrings) -> String {
        switch self {
        case .overview:
            return strings.phrase("概览", "Overview")
        case .accounts:
            return strings.phrase("账号", "Accounts")
        case .tasks:
            return strings.phrase("任务", "Tasks")
        case .settings:
            return strings.phrase("设置", "Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            return "square.grid.2x2"
        case .accounts:
            return "person.2"
        case .tasks:
            return "checklist"
        case .settings:
            return "gearshape"
        }
    }

    static func availablePages(isAdmin: Bool) -> [PanelPage] {
        isAdmin ? [.overview, .accounts, .tasks, .settings] : [.overview, .tasks, .settings]
    }
}

struct RefreshActionButton: View {
    let isRefreshing: Bool
    let label: String
    let action: () -> Void
    @State private var rotation = 0.0

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(ClaudeTheme.elevatedCard)
                    .overlay {
                        Circle()
                            .fill(isRefreshing ? ClaudeTheme.accent.opacity(0.13) : ClaudeTheme.elevatedCard.opacity(0.42))
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        Circle()
                            .stroke(ClaudeTheme.glassBorder, lineWidth: 0.75)
                            .allowsHitTesting(false)
                    }
                    .frame(width: 30, height: 30)
                SafeSystemImage(
                    systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                    fallbackName: "arrow.clockwise"
                )
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isRefreshing ? ClaudeTheme.accent : ClaudeTheme.secondaryText)
                    .rotationEffect(.degrees(rotation))
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .help(label)
        .accessibilityLabel(label)
        .onChange(of: isRefreshing) { refreshing in
            if refreshing {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    rotation = 0
                }
            }
        }
        .onAppear {
            if isRefreshing {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        }
    }
}

struct RefreshIntervalControl: View {
    @Binding var seconds: Double
    let strings: AppStrings
    var title: String?
    let onChange: () -> Void

    private let presetSeconds = [5, 15, 30, 60, 120, 300]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ClaudeTheme.secondaryText)
            }

            HStack(alignment: .center, spacing: 12) {
                Text("\(currentSeconds)s")
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ClaudeTheme.primaryText)
                    .frame(width: 56, alignment: .center)

                Stepper("", value: refreshIntervalBinding, in: 5...300, step: 5)
                    .labelsHidden()
                    .controlSize(.small)

                Text("5-300s")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ClaudeTheme.secondaryText)
            }

            HStack(spacing: 6) {
                ForEach(presetSeconds, id: \.self) { preset in
                    presetButton(preset)
                }
            }

            Text(strings.phrase("失败自动重试，并保留上次成功数据。", "Failures retry automatically and keep the last successful data."))
            .font(.caption2)
            .foregroundStyle(ClaudeTheme.secondaryText)
        }
    }

    private var currentSeconds: Int {
        Int(seconds.rounded())
    }

    private var refreshIntervalBinding: Binding<Double> {
        Binding(
            get: { seconds },
            set: { value in
                updateSeconds(Int(value.rounded()))
            }
        )
    }

    private func presetButton(_ preset: Int) -> some View {
        let isSelected = currentSeconds == preset
        let foreground = isSelected ? ClaudeTheme.primaryText : ClaudeTheme.secondaryText
        let background = isSelected ? ClaudeTheme.accent.opacity(0.14) : Color.clear
        let border = isSelected ? ClaudeTheme.accent.opacity(0.22) : Color.clear

        return Button {
            updateSeconds(preset)
        } label: {
            Text("\(preset)s")
                .font(.caption.weight(.semibold))
                .foregroundStyle(foreground)
                .frame(minWidth: 38)
                .padding(.vertical, 5)
                .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(border, lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
        }
        .buttonStyle(.plain)
    }

    private func updateSeconds(_ value: Int) {
        let next = Double(min(max(value, 5), 300))
        guard next != seconds else {
            return
        }
        seconds = next
        onChange()
    }
}

struct PanelPageTabs: View {
    @Binding var selection: PanelPage
    let pages: [PanelPage]
    let strings: AppStrings

    var body: some View {
        HStack(spacing: 4) {
            ForEach(pages) { page in
                tabButton(page)
            }
        }
        .padding(4)
        .glassSurface(cornerRadius: 11)
    }

    private func tabButton(_ page: PanelPage) -> some View {
        let isSelected = selection == page
        let foreground = isSelected ? ClaudeTheme.primaryText : ClaudeTheme.secondaryText
        let background = isSelected ? ClaudeTheme.elevatedCard : Color.clear
        let border = isSelected ? ClaudeTheme.glassBorder : Color.clear

        return Button {
            selection = page
        } label: {
            HStack(spacing: 6) {
                SafeSystemImage(systemName: page.systemImage, fallbackName: "circle")
                Text(page.title(strings: strings))
                    .lineLimit(1)
            }
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(border, lineWidth: 0.75)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
