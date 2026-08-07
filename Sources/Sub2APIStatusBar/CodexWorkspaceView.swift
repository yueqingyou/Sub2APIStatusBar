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
                        title: strings.phrase("任务", "Tasks")
                    )
                    Spacer()
                    if selection == .activity, !model.codexNodes.isEmpty {
                        Label("\(healthyNodeCount)/\(model.codexNodes.count)", systemImage: "server.rack")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(healthyNodeCount == model.codexNodes.count ? ClaudeTheme.success : ClaudeTheme.warning)
                    }
                }

                GlassSegmentedControl(
                    selection: $selection,
                    items: [
                        GlassSegmentedItem(
                            value: .activity,
                            title: strings.phrase("任务动态", "Activity"),
                            systemImage: "waveform.path.ecg"
                        ),
                        GlassSegmentedItem(
                            value: .nodes,
                            title: strings.phrase("节点管理", "Nodes"),
                            systemImage: "server.rack"
                        ),
                    ]
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Group {
                if selection == .activity {
                    taskView
                } else {
                    nodeView
                }
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
