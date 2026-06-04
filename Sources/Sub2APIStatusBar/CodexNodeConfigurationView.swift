import SwiftUI
import Sub2APIStatusCore

struct CodexNodeConfigurationView: View {
    @ObservedObject var model: MonitorViewModel
    let strings: AppStrings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard
                nodeListCard
                installPreviewCard
                formCard
            }
            .padding(16)
        }
    }

    private var summaryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(strings.phrase("Codex 节点与 hooks", "Codex Nodes and Hooks"), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Text(strings.phrase(
                    "配置本机或远端 Codex hooks，远端事件通过 SSH-R 回传。",
                    "Configure local or remote Codex hooks. Remote events return through SSH-R."
                ))
                .font(.callout)
                .foregroundStyle(ClaudeTheme.secondaryText)
                HStack(spacing: 8) {
                    receiverBadge
                    Spacer()
                    Button {
                        model.resetCodexNodeForm(kind: .local)
                    } label: {
                        Label(strings.phrase("新增本机", "Add Local"), systemImage: "plus")
                    }
                    Button {
                        model.resetCodexNodeForm(kind: .remote)
                    } label: {
                        Label(strings.phrase("新增远端", "Add Remote"), systemImage: "plus")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var receiverBadge: some View {
        Text(strings.phrase("已配置 \(model.codexNodes.count) 个节点", "\(model.codexNodes.count) nodes configured"))
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(ClaudeTheme.primaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(ClaudeTheme.elevatedCard, in: Capsule())
            .overlay(Capsule().stroke(ClaudeTheme.border, lineWidth: 1))
    }

    @ViewBuilder
    private var nodeListCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(strings.phrase("已登记节点", "Registered Nodes"), systemImage: "server.rack")
                    .font(.headline)
                if model.codexNodes.isEmpty {
                    Text(strings.phrase(
                        "尚未登记节点。保存下方表单后，接收端会按节点端口启动。",
                        "No node has been registered. After saving the form below, receivers will start for the node ports."
                    ))
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
                Image(systemName: node.kind == .local ? "desktopcomputer" : "network")
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
                }
                Button(role: .destructive) {
                    model.removeCodexNode(id: node.id)
                } label: {
                    Text(strings.phrase("删除", "Delete"))
                }
            }
            InfoRow(label: strings.phrase("接收端", "Receiver"), value: node.hookReceiverURL.absoluteString)
            InfoRow(label: strings.phrase("本机监听", "Local Listener"), value: "127.0.0.1:\(node.localReceiverPort)")
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
        .background(ClaudeTheme.elevatedCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ClaudeTheme.border, lineWidth: 1)
        )
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
                    .background(ClaudeTheme.textFieldBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ClaudeTheme.border, lineWidth: 1)
                    )

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
                Label(strings.phrase("节点表单", "Node Form"), systemImage: "slider.horizontal.3")
                    .font(.headline)

                Picker(strings.phrase("节点类型", "Node Type"), selection: nodeKindBinding) {
                    Text(strings.phrase("本机", "Local")).tag(CodexNodeKind.local)
                    Text(strings.phrase("远端", "Remote")).tag(CodexNodeKind.remote)
                }
                .pickerStyle(.segmented)

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
                        model.saveCodexNodeForm()
                    } label: {
                        Label(strings.phrase("保存节点", "Save Node"), systemImage: "checkmark.circle.fill")
                    }
                    .keyboardShortcut(.defaultAction)

                    Button {
                        model.resetCodexNodeForm(kind: model.codexNodeForm.kind)
                    } label: {
                        Label(strings.phrase("重置表单", "Reset Form"), systemImage: "arrow.counterclockwise")
                    }

                    Spacer()
                    Text(strings.phrase("保存节点后可在节点卡片中安装 hooks。", "After saving a node, install hooks from its node card."))
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.secondaryText)
                }
                .buttonStyle(.borderless)
            }
        }
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
            field(strings.phrase("CODEX_HOME（本机留空则读取环境变量）", "CODEX_HOME (local uses environment when empty)"), text: $model.codexNodeForm.codexHomeOverride)
        }
    }

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.phrase(
                "远端只需 SSH 连接，可读取 ~/.ssh/config 或手动填写；节点参数会自动生成。",
                "Remote nodes only need SSH settings; load ~/.ssh/config or enter them manually. Node parameters are generated."
            ))
            .font(.caption)
            .foregroundStyle(ClaudeTheme.secondaryText)
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

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(ClaudeTheme.secondaryText)
            TextField(label, text: text)
                .themedTextField()
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(ClaudeTheme.secondaryText)
            SecureField(label, text: text)
                .themedTextField()
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
