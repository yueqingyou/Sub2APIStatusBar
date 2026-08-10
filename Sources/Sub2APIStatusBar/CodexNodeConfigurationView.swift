import SwiftUI
import Sub2APIStatusCore

struct CodexNodeConfigurationView: View {
    @ObservedObject var model: MonitorViewModel
    let strings: AppStrings
    @State private var isFormPresented = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                nodeListCard
                installPreviewCard
                if isFormPresented {
                    formCard
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var nodeListCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(strings.phrase("已登记节点", "Registered Nodes"), systemImage: "server.rack")
                        .font(.headline)
                    if !model.codexNodes.isEmpty {
                        Text(String(model.codexNodes.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ClaudeTheme.secondaryText)
                    }
                    Spacer()
                    Button {
                        model.resetCodexNodeForm(kind: .local)
                        isFormPresented = true
                    } label: {
                        Label(strings.phrase("本机", "Local"), systemImage: "plus")
                    }
                    Button {
                        model.resetCodexNodeForm(kind: .remote)
                        isFormPresented = true
                    } label: {
                        Label(strings.phrase("远端", "Remote"), systemImage: "plus")
                    }
                }
                .buttonStyle(.borderless)
                if model.codexNodes.isEmpty {
                    Text(strings.phrase("暂无节点", "No nodes"))
                        .font(.callout)
                        .foregroundStyle(ClaudeTheme.secondaryText)
                } else {
                    VStack(spacing: 10) {
                        ForEach(model.codexNodes) { node in
                            nodeRow(node)
                        }
                    }
                }
            }
        }
    }

    private func nodeRow(_ node: CodexNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                SafeSystemImage(
                    systemName: node.kind == .local ? "desktopcomputer" : "network",
                    fallbackName: "server.rack"
                )
                .foregroundStyle(node.kind == .local ? ClaudeTheme.success : ClaudeTheme.accent)
                .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name)
                        .font(.callout.weight(.semibold))
                    Text("\(node.id) · \(nodeKindLabel(node.kind))")
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.secondaryText)
                }
                Spacer()
                Button(strings.phrase("编辑", "Edit")) {
                    model.editCodexNode(id: node.id)
                    isFormPresented = true
                }
                Button(role: .destructive) {
                    model.removeCodexNode(id: node.id)
                } label: {
                    Text(strings.phrase("删除", "Delete"))
                }
            }
            InfoRow(label: strings.phrase("接收端", "Receiver"), value: node.hookReceiverURL.absoluteString)
            if node.kind == .remote {
                InfoRow(label: strings.phrase("本机监听", "Local Listener"), value: "127.0.0.1:\(node.localReceiverPort)")
            }
            if let ssh = node.ssh {
                InfoRow(label: "SSH", value: ssh.destination)
            }
            if let codexHomeOverride = node.codexHomeOverride {
                InfoRow(label: "CODEX_HOME", value: codexHomeOverride)
            }
            if let health = model.codexNodeHealthStatuses[node.id] {
                InfoRow(label: strings.phrase("健康", "Health"), value: healthText(health))
            }
            if let status = model.codexTunnelStatuses[node.id] {
                InfoRow(label: "SSH-R", value: tunnelStatusText(status))
            }
            if let message = model.codexNodeOperationMessages[node.id] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button {
                    model.prepareCodexHookInstallPreview(nodeID: node.id)
                } label: {
                    if model.preparingCodexNodeInstallPreviewIDs.contains(node.id) {
                        Label(strings.phrase("生成预览中", "Preparing Preview"), systemImage: "hourglass")
                    } else {
                        Label(strings.phrase("预览 hooks", "Preview Hooks"), systemImage: "doc.text.magnifyingglass")
                    }
                }
                .disabled(model.preparingCodexNodeInstallPreviewIDs.contains(node.id) || model.installingCodexNodeIDs.contains(node.id))

                Button {
                    model.sendCodexTestEvent(nodeID: node.id)
                } label: {
                    Label(strings.phrase("测试事件", "Test Event"), systemImage: "paperplane")
                }

                if node.kind == .remote {
                    Menu {
                        Button {
                            model.refreshCodexTunnelStatus(nodeID: node.id)
                        } label: {
                            Label(strings.phrase("检查 SSH-R", "Check SSH-R"), systemImage: "arrow.clockwise")
                        }
                        Button {
                            model.startCodexTunnel(nodeID: node.id)
                        } label: {
                            Label(strings.phrase("重启 SSH-R", "Restart SSH-R"), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        }
                        Button {
                            model.stopCodexTunnel(id: node.id)
                        } label: {
                            Label(strings.phrase("停止 SSH-R", "Stop SSH-R"), systemImage: "stop.circle")
                        }
                    } label: {
                        Label(strings.phrase("更多", "More"), systemImage: "ellipsis.circle")
                    }
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .glassSurface(cornerRadius: 10)
    }

    @ViewBuilder
    private var installPreviewCard: some View {
        if let preview = model.codexHookInstallPreview {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(strings.phrase("hooks 写入预览", "Hooks Install Preview"), systemImage: "doc.text.magnifyingglass")
                            .font(.headline)
                        Spacer()
                        Text(preview.node.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ClaudeTheme.secondaryText)
                    }

                    Text(strings.phrase(
                        "确认后才会备份并修改该节点的用户级 Codex config.toml。",
                        "Confirmation backs up and modifies this node's user-level Codex config.toml."
                    ))
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.secondaryText)

                    VStack(alignment: .leading, spacing: 6) {
                        InfoRow(label: strings.phrase("配置", "Config"), value: preview.plan.codexConfigPath)
                        InfoRow(label: strings.phrase("备份", "Backup"), value: preview.plan.codexConfigBackupPath)
                    }

                    ScrollView([.vertical, .horizontal]) {
                        Text(preview.configDiff)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(ClaudeTheme.primaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(minHeight: 180, maxHeight: 260)
                    .glassSurface(cornerRadius: 8)

                    HStack {
                        Button {
                            model.confirmCodexHookInstallPreview()
                        } label: {
                            if model.installingCodexNodeIDs.contains(preview.nodeID) {
                                Label(strings.phrase("写入中", "Writing"), systemImage: "hourglass")
                            } else {
                                Label(strings.phrase("确认写入", "Confirm Install"), systemImage: "checkmark.circle.fill")
                            }
                        }
                        .disabled(model.installingCodexNodeIDs.contains(preview.nodeID))
                        .keyboardShortcut(.defaultAction)

                        Button(role: .cancel) {
                            model.cancelCodexHookInstallPreview()
                        } label: {
                            Label(strings.phrase("取消", "Cancel"), systemImage: "xmark.circle")
                        }
                        .disabled(model.installingCodexNodeIDs.contains(preview.nodeID))

                        Spacer()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var formCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(nodeFormTitle, systemImage: "slider.horizontal.3")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text(strings.phrase("节点类型", "Node Type"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ClaudeTheme.secondaryText)
                    GlassSegmentedControl(
                        selection: nodeKindBinding,
                        items: [
                            GlassSegmentedItem(
                                value: .local,
                                title: strings.phrase("本机", "Local"),
                                systemImage: "desktopcomputer"
                            ),
                            GlassSegmentedItem(
                                value: .remote,
                                title: strings.phrase("远端", "Remote"),
                                systemImage: "network"
                            ),
                        ]
                    )
                }

                if model.codexNodeForm.kind == .remote {
                    remoteFields
                } else {
                    localFields
                }

                if let error = model.codexNodeError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button {
                        if model.saveCodexNodeForm() {
                            isFormPresented = false
                        }
                    } label: {
                        Label(strings.phrase("保存节点", "Save Node"), systemImage: "checkmark.circle.fill")
                    }
                    .keyboardShortcut(.defaultAction)

                    Button {
                        model.resetCodexNodeForm(kind: model.codexNodeForm.kind)
                    } label: {
                        Label(strings.phrase("重置表单", "Reset Form"), systemImage: "arrow.counterclockwise")
                    }

                    Button(role: .cancel) {
                        isFormPresented = false
                    } label: {
                        Label(strings.phrase("取消", "Cancel"), systemImage: "xmark")
                    }

                    Spacer()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var nodeFormTitle: String {
        model.editingCodexNodeID == nil
            ? strings.phrase("新增节点", "Add Node")
            : strings.phrase("编辑节点", "Edit Node")
    }

    private var localFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            twoColumnFields(
                left: field(strings.phrase("节点 ID", "Node ID"), text: $model.codexNodeForm.id),
                right: field(strings.phrase("显示名称", "Display Name"), text: $model.codexNodeForm.name)
            )
            twoColumnFields(
                left: field(strings.phrase("本机监听端口", "Local Receiver Port"), text: $model.codexNodeForm.localReceiverPort),
                right: secureField(strings.phrase("节点密钥", "Secret"), text: $model.codexNodeForm.secret)
            )
            field(
                "CODEX_HOME",
                text: $model.codexNodeForm.codexHomeOverride,
                help: strings.phrase("本机留空时读取环境变量", "Uses the local environment when empty")
            )
        }
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            sshConfigPicker
            twoColumnFields(
                left: field(strings.phrase("SSH 主机", "SSH Host"), text: $model.codexNodeForm.sshHost),
                right: field(strings.phrase("SSH 用户", "SSH User"), text: $model.codexNodeForm.sshUser)
            )
            twoColumnFields(
                left: field(strings.phrase("SSH 端口", "SSH Port"), text: $model.codexNodeForm.sshPort),
                right: field(strings.phrase("SSH 私钥路径", "SSH Identity File"), text: $model.codexNodeForm.sshIdentityFile)
            )
        }
    }

    private var nodeKindBinding: Binding<CodexNodeKind> {
        Binding(
            get: { model.codexNodeForm.kind },
            set: { model.setCodexNodeFormKind($0) }
        )
    }

    private var sshConfigPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    model.loadSSHConfigHosts()
                } label: {
                    Label(strings.phrase("读取 SSH 配置", "Load SSH Config"), systemImage: "folder.badge.gearshape")
                }

                if !model.sshConfigHosts.isEmpty {
                    Picker(strings.phrase("SSH Host", "SSH Host"), selection: $model.selectedSSHConfigHostID) {
                        ForEach(model.sshConfigHosts) { host in
                            Text("\(host.alias) · \(host.displayDestination)")
                                .tag(host.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)

                    Button {
                        model.applySelectedSSHConfigHost()
                    } label: {
                        Label(strings.phrase("填入表单", "Fill Form"), systemImage: "arrow.down.doc")
                    }
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private func twoColumnFields<Left: View, Right: View>(left: Left, right: Right) -> some View {
        HStack(alignment: .top, spacing: 10) {
            left
            right
        }
    }

    private func field(_ label: String, text: Binding<String>, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(ClaudeTheme.secondaryText)
            TextField("", text: text)
                .themedTextField()
                .accessibilityLabel(label)
                .help(help ?? label)
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(ClaudeTheme.secondaryText)
            SecureField("", text: text)
                .credentialTextInput()
                .themedTextField()
                .accessibilityLabel(label)
        }
    }

    private func tunnelStatusText(_ status: SSHTunnelStatus) -> String {
        switch status.state {
        case .starting:
            return strings.phrase("启动中", "Starting")
        case .running:
            return strings.phrase("运行中", "Running")
        case let .failed(exitCode):
            return strings.phrase("失败 \(exitCode)", "Failed \(exitCode)")
        }
    }

    private func nodeKindLabel(_ kind: CodexNodeKind) -> String {
        switch kind {
        case .local:
            return strings.phrase("本机", "Local")
        case .remote:
            return strings.phrase("远端", "Remote")
        }
    }

    private func healthText(_ status: CodexNodeHealthStatus) -> String {
        var parts = [healthStateName(status.state)]
        if let lastSeenAt = status.lastSeenAt {
            parts.append(strings.phrase(
                "最近事件 \(lastSeenAt.formatted(date: .omitted, time: .shortened))",
                "Last event \(lastSeenAt.formatted(date: .omitted, time: .shortened))"
            ))
        }
        if let lastTestEventAt = status.lastTestEventAt {
            parts.append(strings.phrase(
                "最近测试 \(lastTestEventAt.formatted(date: .omitted, time: .shortened))",
                "Last test \(lastTestEventAt.formatted(date: .omitted, time: .shortened))"
            ))
        }
        if let detail = status.detail {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }

    private func healthStateName(_ state: CodexNodeHealthState) -> String {
        switch state {
        case .unconfigured:
            return strings.phrase("未配置 hooks", "Hooks Unconfigured")
        case .installed:
            return strings.phrase("已安装", "Installed")
        case .waitingForTrust:
            return strings.phrase("等待信任", "Awaiting Trust")
        case .healthy:
            return strings.phrase("健康", "Healthy")
        case .receiverFailed:
            return strings.phrase("接收端失败", "Receiver Failed")
        case .tunnelFailed:
            return strings.phrase("SSH-R 失败", "SSH-R Failed")
        case .installFailed:
            return strings.phrase("安装失败", "Install Failed")
        case .configWriteFailed:
            return strings.phrase("配置读取/写入失败", "Config Read/Write Failed")
        case .invalidSignature:
            return strings.phrase("签名错误", "Invalid Signature")
        case .stale:
            return strings.phrase("事件过期", "Stale")
        }
    }
}
