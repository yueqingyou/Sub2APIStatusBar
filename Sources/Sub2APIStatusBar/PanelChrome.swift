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
        .padding(12)
        .background(ClaudeTheme.footer)
    }
}

enum PanelPage: String, CaseIterable, Identifiable, Equatable {
    case overview
    case codexNodes
    case codexTasks
    case settings

    var id: String { rawValue }

    func title(strings: AppStrings) -> String {
        switch self {
        case .overview:
            return strings.phrase("概览", "Overview")
        case .codexTasks:
            return strings.phrase("任务", "Tasks")
        case .codexNodes:
            return strings.phrase("节点", "Nodes")
        case .settings:
            return strings.phrase("设置", "Settings")
        }
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
                    .fill(isRefreshing ? ClaudeTheme.accent.opacity(0.13) : ClaudeTheme.elevatedCard.opacity(0.54))
                    .frame(width: 30, height: 30)
                Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
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
                    .padding(.vertical, 6)
                    .background(ClaudeTheme.elevatedCard, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(ClaudeTheme.border, lineWidth: 1)
                    )

                Stepper("", value: refreshIntervalBinding, in: 1...300, step: 5)
                    .labelsHidden()
                    .controlSize(.small)

                Text("1-300s")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ClaudeTheme.secondaryText)
            }

            HStack(spacing: 6) {
                ForEach(presetSeconds, id: \.self) { preset in
                    Button {
                        updateSeconds(preset)
                    } label: {
                        Text("\(preset)s")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(currentSeconds == preset ? ClaudeTheme.primaryText : ClaudeTheme.secondaryText)
                            .frame(minWidth: 38)
                            .padding(.vertical, 5)
                            .background(
                                currentSeconds == preset ? ClaudeTheme.accent.opacity(0.22) : ClaudeTheme.elevatedCard,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(currentSeconds == preset ? ClaudeTheme.accent.opacity(0.58) : ClaudeTheme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
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

    private func updateSeconds(_ value: Int) {
        let next = Double(min(max(value, 1), 300))
        guard next != seconds else {
            return
        }
        seconds = next
        onChange()
    }
}

struct PanelPageTabs: View {
    @Binding var selection: PanelPage
    let strings: AppStrings
    @State private var hoveredPage: PanelPage?

    private let tabHeight: CGFloat = 34
    private let cornerRadius: CGFloat = 10

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PanelPage.allCases) { page in
                tabButton(for: page)
            }
        }
        .padding(4)
        .frame(height: tabHeight + 8)
        .background(ClaudeTheme.tabBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(ClaudeTheme.border, lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.16), value: selection)
        .animation(.easeOut(duration: 0.12), value: hoveredPage)
    }

    private func tabButton(for page: PanelPage) -> some View {
        let isSelected = selection == page
        let isHovered = hoveredPage == page

        return Button {
            guard selection != page else {
                return
            }
            selection = page
        } label: {
            Text(page.title(strings: strings))
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? ClaudeTheme.primaryText : ClaudeTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: tabHeight)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tabFill(isSelected: isSelected, isHovered: isHovered))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(isSelected ? ClaudeTheme.border : Color.clear, lineWidth: 1)
                )
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(ClaudeTheme.accent.opacity(0.72))
                            .frame(width: 26, height: 2)
                            .padding(.bottom, 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onHover { isHovered in
            hoveredPage = isHovered ? page : nil
        }
        .accessibilityLabel(page.title(strings: strings))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func tabFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return ClaudeTheme.tabSelected
        }
        if isHovered {
            return ClaudeTheme.elevatedCard.opacity(0.55)
        }
        return .clear
    }
}
