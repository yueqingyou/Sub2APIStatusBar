import SwiftUI

struct CodexWorkspaceView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case activity
        case nodes

        var id: String { rawValue }
    }

    @ObservedObject var model: MonitorViewModel
    let strings: AppStrings
    @State private var selection: Section = .activity

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    PanelPageHeader(
                        title: strings.phrase("任务", "Tasks"),
                        subtitle: strings.phrase("Codex 任务与节点", "Codex tasks and nodes")
                    )
                    Spacer()
                    if selection == .activity, !model.codexNodes.isEmpty {
                        Label("\(healthyNodeCount)/\(model.codexNodes.count)", systemImage: "server.rack")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(healthyNodeCount == model.codexNodes.count ? ClaudeTheme.success : ClaudeTheme.warning)
                    }
                }

                Picker("", selection: $selection) {
                    Text(strings.phrase("任务动态", "Activity")).tag(Section.activity)
                    Text(strings.phrase("节点管理", "Nodes")).tag(Section.nodes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ZStack {
                taskView
                    .opacity(selection == .activity ? 1 : 0)
                    .allowsHitTesting(selection == .activity)
                    .accessibilityHidden(selection != .activity)
                nodeView
                    .opacity(selection == .nodes ? 1 : 0)
                    .allowsHitTesting(selection == .nodes)
                    .accessibilityHidden(selection != .nodes)
            }
        }
    }

    private var taskView: some View {
        CodexTaskConsoleView(
            activities: model.snapshot.codexTaskActivities,
            latestUsage: model.snapshot.latestUsage,
            realtimeConcurrency: model.snapshot.realtimeConcurrency,
            timelineEventLimit: model.config.codexTaskTimelineEventLimit,
            strings: strings,
            showsPageHeader: false
        )
    }

    private var nodeView: some View {
        CodexNodeConfigurationView(model: model, strings: strings, showsPageHeader: false)
    }

    private var healthyNodeCount: Int {
        model.codexNodes.filter { model.codexNodeHealthStatuses[$0.id]?.state == .healthy }.count
    }
}
