import Combine
import Foundation
import SwiftUI
import Sub2APIStatusCore

struct LoginPanel: View {
    @ObservedObject var model: MonitorViewModel
    @FocusState private var focusedField: LoginField?
    @State private var showsAdvancedOptions = false

    private var formState: LoginFormState {
        LoginFormState(
            baseURL: model.settingsDraft.baseURL,
            email: model.loginEmail,
            password: model.loginPassword
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    loginPageHeader
                    credentialsCard

                    if let error = model.settingsError {
                        MessageRow(message: error)
                    }

                    interfaceCard
                    advancedOptionsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }

            footer
        }
        .environment(\.appLanguage, model.settingsDraft.language)
    }

    private var header: some View {
        HStack(spacing: 10) {
            PanelBrandMark(statusTint: nil)

            VStack(alignment: .leading, spacing: 2) {
                Text("TokenRouter")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }

            Spacer()

            StatusPill(
                title: strings.phrase("未登录", "Signed Out"),
                tint: ClaudeTheme.slate,
                systemImage: "person.crop.circle.badge.xmark"
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(ClaudeTheme.header)
    }

    private var loginPageHeader: some View {
        PanelPageHeader(title: strings.phrase("登录", "Sign In"))
    }

    private var credentialsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    credentialLabel(strings.phrase("服务地址", "Server URL"))
                    TextField("https://tokenrouter.example.com", text: $model.settingsDraft.baseURL)
                        .loginCredentialField()
                        .focused($focusedField, equals: .baseURL)
                        .onSubmit {
                            focusedField = .email
                        }
                        .onChange(of: model.settingsDraft.baseURL) { _ in
                            model.scheduleSettingsAutosave(refreshAfterSave: false)
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    credentialLabel(strings.phrase("账号", "Account"))
                    TextField("name@example.com", text: $model.loginEmail)
                        .loginCredentialField()
                        .focused($focusedField, equals: .email)
                        .onSubmit {
                            focusedField = .password
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    credentialLabel(strings.phrase("密码", "Password"))
                    SecureField("", text: $model.loginPassword)
                        .loginCredentialField()
                        .accessibilityLabel(strings.phrase("密码", "Password"))
                        .focused($focusedField, equals: .password)
                        .onSubmit {
                            submitLogin()
                        }
                }

                Button {
                    submitLogin()
                } label: {
                    HStack(spacing: 7) {
                        if model.isLoggingIn {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            SafeSystemImage(systemName: "key.fill", fallbackName: "key")
                        }
                        Text(model.isLoggingIn ? strings.phrase("连接中...", "Connecting...") : strings.phrase("登录", "Sign In"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!formState.canSubmit || model.isLoggingIn)
            }
        }
    }

    private var interfaceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    credentialLabel(strings.phrase("语言", "Language"))
                    GlassSegmentedControl(
                        selection: languageBinding,
                        items: languageItems
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    credentialLabel(strings.phrase("外观", "Appearance"))
                    GlassSegmentedControl(
                        selection: appearanceBinding,
                        items: appearanceItems
                    )
                }
            }
        }
    }

    private var advancedOptionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsAdvancedOptions.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(strings.phrase("高级选项", "Advanced Options"))
                            .font(.headline)
                            .foregroundStyle(ClaudeTheme.primaryText)
                        Spacer()
                        SafeSystemImage(systemName: "chevron.right", fallbackName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ClaudeTheme.secondaryText)
                            .rotationEffect(.degrees(showsAdvancedOptions ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showsAdvancedOptions {
                    RefreshIntervalControl(
                        seconds: $model.settingsDraft.refreshIntervalSeconds,
                        strings: strings,
                        title: strings.phrase("刷新间隔", "Refresh Interval")
                    ) {
                        model.scheduleSettingsAutosave(refreshAfterSave: false)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(strings.phrase("手动令牌", "Manual Token"))
                            .font(.callout.weight(.semibold))
                        SecureField("Bearer Token", text: manualTokenBinding)
                            .loginCredentialField()
                            .focused($focusedField, equals: .authToken)
                    }

                    Button {
                        model.saveSettings()
                    } label: {
                        Label(strings.phrase("保存令牌", "Save Token"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.settingsDraft.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                model.openURL(model.settingsDraft.baseURL)
            } label: {
                Label(strings.phrase("打开服务", "Open Server"), systemImage: "safari")
            }
            .disabled(model.settingsDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
    }

    private func credentialLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(ClaudeTheme.secondaryText)
    }

    private func submitLogin() {
        guard formState.canSubmit, !model.isLoggingIn else {
            return
        }
        focusedField = nil
        model.loginAndSave()
    }

    private var strings: AppStrings {
        AppStrings(model.settingsDraft.language)
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.settingsDraft.language },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.language = value }
            }
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { model.settingsDraft.appearance },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.appearance = value }
            }
        )
    }

    private var manualTokenBinding: Binding<String> {
        Binding(
            get: { model.settingsDraft.authToken },
            set: { value in
                model.settingsDraft.authToken = value
                model.scheduleSettingsAutosave(refreshAfterSave: false)
            }
        )
    }

    private var languageItems: [GlassSegmentedItem<AppLanguage>] {
        [AppLanguage.zhHans, .en].map {
            GlassSegmentedItem(value: $0, title: strings.languageName($0))
        }
    }

    private var appearanceItems: [GlassSegmentedItem<AppAppearance>] {
        AppAppearance.allCases.map {
            GlassSegmentedItem(
                value: $0,
                title: strings.appearanceName($0),
                systemImage: $0.systemImageName
            )
        }
    }
}

struct SettingsView: View {
    let model: MonitorViewModel
    @StateObject private var renderState: SettingsRenderState
    @FocusState private var focusedField: SettingsField?
    @State private var adminUserSearchText = ""

    private static let maxAdminUserPickerOptions = 20
    private static let hardwareMonitorPageIntervalOptions: [Double] = [5, 15, 30, 60, 300, 900, 1_800, 3_600, 21_600, 86_400]
    private static let hardwareMonitorOfflineIntervalOptions: [Double] = [5, 15, 30, 60, 120, 300]
    private static let hardwareMonitorBatteryIntervalOptions: [Double] = [300, 900, 1_800, 3_600, 21_600, 86_400]

    init(model: MonitorViewModel) {
        self.model = model
        _renderState = StateObject(wrappedValue: SettingsRenderState(model: model))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                generalSettingsCard

                menuBarSettingsCard

                taskConsoleSettingsCard

                hardwareMonitorSettingsCard

                if isAdminAccount {
                    adminMonitoringSettingsCard
                }

                UpdateSettingsSection(model: model)

                connectionSection

                if let error = renderState.settingsError {
                    MessageRow(message: error)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: focusedField) { focus in
            if focus == nil {
                model.scheduleSettingsAutosave(refreshAfterSave: true)
            }
        }
    }

    private var generalSettingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(strings.phrase("基础", "General"))
                    .font(.headline)

                settingsRow(strings.phrase("语言", "Language")) {
                    GlassSegmentedControl(
                        selection: languageBinding,
                        items: languageItems
                    )
                }

                settingsRow(strings.phrase("外观", "Appearance")) {
                    GlassSegmentedControl(
                        selection: appearanceBinding,
                        items: appearanceItems
                    )
                }

                settingsRow(strings.phrase("启动", "Startup")) {
                    GlassCheckbox(
                        isOn: launchAtLoginBinding,
                        title: strings.phrase("登录时打开", "Open at Login")
                    )
                }

                settingsRow(strings.phrase("服务地址", "Server URL")) {
                    TextField("https://sub2api.example.com", text: baseURLBinding)
                        .themedTextField()
                        .focused($focusedField, equals: .baseURL)
                }

                settingsRow(strings.phrase("刷新", "Refresh")) {
                    RefreshIntervalControl(
                        seconds: refreshIntervalBinding,
                        strings: strings
                    ) {
                        model.scheduleSettingsAutosave(refreshAfterSave: false)
                    }
                }
            }
        }
    }

    private var menuBarSettingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(strings.phrase("菜单栏", "Menu Bar"))
                    .font(.headline)

                GlassCheckbox(
                    isOn: showsMenuBarTextBinding,
                    title: strings.phrase("在菜单栏显示文字", "Show text in menu bar")
                )

                settingsRow(strings.phrase("统计窗口", "Usage window")) {
                    GlassSegmentedControl(
                        selection: menuBarUsageWindowBinding,
                        items: usageWindowItems
                    )
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text(strings.phrase("显示项目", "Menu bar items"))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(availableMenuBarDisplayItems) { item in
                            GlassCheckbox(
                                isOn: menuBarItemBinding(item),
                                title: strings.menuBarItemName(item),
                                compact: true
                            )
                        }
                    }
                }
            }
        }
    }

    private var taskConsoleSettingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(strings.phrase("任务控制台", "Task Console"))
                    .font(.headline)

                settingsRow(strings.phrase("时间线事件", "Timeline Events")) {
                    Picker("", selection: codexTaskTimelineEventLimitBinding) {
                        ForEach(Array(AppConfig.codexTaskTimelineEventLimitRange), id: \.self) { limit in
                            Text(strings.phrase("最近 \(limit) 条", "Latest \(limit) Events")).tag(limit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var hardwareMonitorSettingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(strings.phrase("硬件监控屏", "Hardware Monitor"))
                    .font(.headline)

                GlassCheckbox(
                    isOn: hardwareMonitorEnabledBinding,
                    title: strings.phrase("启用硬件监控屏", "Enable hardware monitor")
                )

                if renderState.draft.hardwareMonitorEnabled {
                    hardwareMonitorIntervalRow(
                        strings.phrase("概览页", "Overview"),
                        binding: hardwareMonitorPageIntervalBinding(\.overviewIntervalSeconds)
                    )
                    hardwareMonitorIntervalRow(
                        strings.phrase("任务页", "Tasks"),
                        binding: hardwareMonitorPageIntervalBinding(\.tasksIntervalSeconds)
                    )
                    hardwareMonitorIntervalRow(
                        strings.phrase("配额页", "Quota"),
                        binding: hardwareMonitorPageIntervalBinding(\.quotaIntervalSeconds)
                    )
                    hardwareMonitorIntervalRow(
                        strings.phrase("设备页", "Device"),
                        binding: hardwareMonitorPageIntervalBinding(\.deviceIntervalSeconds)
                    )
                    hardwareMonitorIntervalRow(
                        strings.phrase("电量刷新", "Battery"),
                        binding: hardwareMonitorPageIntervalBinding(\.batterySampleIntervalSeconds),
                        options: Self.hardwareMonitorBatteryIntervalOptions
                    )
                    Text(strings.phrase(
                        "仅控制板载电量采样；显示值不变时不会刷新屏幕。",
                        "Controls only onboard battery sampling; unchanged values do not refresh the screen."
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    GlassCheckbox(
                        isOn: hardwareMonitorOfflineCheckEnabledBinding,
                        title: strings.phrase("独立检查离线状态", "Check offline status independently")
                    )
                    if renderState.draft.hardwareMonitorSyncSettings.offlineCheckIntervalSeconds != nil {
                        hardwareMonitorIntervalRow(
                            strings.phrase("离线检查", "Offline check"),
                            binding: hardwareMonitorOfflineIntervalBinding,
                            options: Self.hardwareMonitorOfflineIntervalOptions
                        )
                    } else {
                        Text(strings.phrase(
                            "关闭后仅随页面同步检查离线状态。",
                            "When off, offline status is checked only during page sync."
                        ))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    GlassCheckbox(
                        isOn: hardwareMonitorNightSleepEnabledBinding,
                        title: strings.phrase("启用北京时间夜间休眠", "Enable Beijing-time night sleep")
                    )
                    if renderState.draft.hardwareMonitorSyncSettings.nightSleepEnabled {
                        settingsRow(strings.phrase("休眠时段", "Sleep window")) {
                            HStack(spacing: 8) {
                                hardwareMonitorTimePicker(
                                    minuteOfDay: hardwareMonitorNightSleepStartBinding,
                                    title: strings.phrase("休眠开始", "Sleep starts")
                                )
                                Text(strings.phrase("至", "to"))
                                    .foregroundStyle(.secondary)
                                hardwareMonitorTimePicker(
                                    minuteOfDay: hardwareMonitorNightSleepEndBinding,
                                    title: strings.phrase("休眠结束", "Sleep ends")
                                )
                            }
                        }
                        Text(strings.phrase(
                            "该时段按北京时间执行，屏幕、蓝牙同步和固件升级均会离线；按屏幕 KEY 可提前唤醒。休眠期间修改的设置会在设备下次连接后生效。",
                            "This window follows Beijing time. The screen, Bluetooth sync, and firmware update are offline; press the screen's KEY to wake early. Changes made while asleep apply after the next connection."
                        ))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: hardwareMonitorStatusSymbol)
                        .foregroundStyle(hardwareMonitorStatusColor)
                    Text(hardwareMonitorStatusText)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                if renderState.draft.hardwareMonitorEnabled {
                    hardwareFirmwareUpdateView
                }
            }
        }
    }

    @ViewBuilder
    private var hardwareFirmwareUpdateView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(strings.phrase("固件", "Firmware"))
                    .font(.callout.weight(.semibold))
                Spacer()

                switch renderState.hardwareFirmwareUpdateState {
                case let .waitingForDevice(targetVersion):
                    Text(strings.phrase("内置 \(targetVersion) · 等待连接", "Bundled \(targetVersion) · Waiting"))
                        .foregroundStyle(.secondary)
                case let .available(currentVersion, targetVersion):
                    Text("\(currentVersion) → \(targetVersion)")
                        .monospacedDigit()
                    firmwareUpdateButton(strings.phrase("更新", "Update"))
                case let .upToDate(version):
                    Text(strings.phrase("\(version) · 最新", "\(version) · Current"))
                        .monospacedDigit()
                    firmwareUpdateButton(strings.phrase("重新安装", "Reinstall"))
                case let .preparing(targetVersion):
                    Text(strings.phrase("准备 \(targetVersion)", "Preparing \(targetVersion)"))
                case let .transferring(targetVersion, progressPercent):
                    Text("\(targetVersion) · \(progressPercent)%")
                        .monospacedDigit()
                case let .verifying(targetVersion):
                    Text(strings.phrase("正在校验 \(targetVersion)", "Verifying \(targetVersion)"))
                case let .restarting(targetVersion):
                    Text(strings.phrase("正在重启至 \(targetVersion)", "Restarting into \(targetVersion)"))
                case let .completed(version):
                    Label(
                        strings.phrase("\(version) · 已完成", "\(version) · Complete"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                case let .unavailable(detail):
                    Text(firmwareUpdateDetail(detail))
                        .foregroundStyle(.secondary)
                case .failed:
                    firmwareUpdateButton(strings.phrase("重试", "Retry"))
                }
            }
            .font(.callout)

            switch renderState.hardwareFirmwareUpdateState {
            case let .transferring(_, progressPercent):
                ProgressView(value: Double(progressPercent), total: 100)
                    .progressViewStyle(.linear)
                Text(strings.phrase("保持设备供电并靠近 Mac。", "Keep the device powered and near this Mac."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .preparing, .verifying, .restarting:
                Text(strings.phrase("保持设备供电并靠近 Mac。", "Keep the device powered and near this Mac."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case let .failed(detail):
                Text(firmwareUpdateDetail(detail))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
    }

    private func firmwareUpdateButton(_ title: String) -> some View {
        Button(title) {
            model.installHardwareFirmware()
        }
        .buttonStyle(.borderless)
        .disabled(!canStartFirmwareUpdate)
    }

    private var canStartFirmwareUpdate: Bool {
        switch renderState.hardwareMonitorBLEState {
        case .ready, .firmwareUpdateOnly:
            return !renderState.hardwareFirmwareUpdateState.isInProgress
                && !renderState.isInstallingAppUpdate
        default:
            return false
        }
    }

    private func firmwareUpdateDetail(_ detail: String) -> String {
        if detail.contains("one-time USB") {
            return strings.phrase("首次需要通过 USB 初始化", "One-time USB setup required")
        }
        if detail.contains("bundled hardware firmware") {
            return strings.phrase("内置固件不可用", "Bundled firmware unavailable")
        }
        if detail.contains("connection was lost") {
            return strings.phrase("升级期间蓝牙连接中断。", "Bluetooth disconnected during the update.")
        }
        if detail.contains("timed out") {
            return strings.phrase("固件升级超时。", "The firmware update timed out.")
        }
        if detail.contains("rolled back") {
            return strings.phrase("新固件启动失败，硬件已回滚。", "The new firmware failed to start and was rolled back.")
        }
        return detail
    }

    private var adminMonitoringSettingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(strings.phrase("管理员监控", "Admin Monitoring"))
                    .font(.headline)

                settingsRow(strings.phrase("监控用户", "Monitor User")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if adminUserOptions.count > Self.maxAdminUserPickerOptions {
                            TextField(strings.phrase("搜索用户邮箱或名称", "Search user email or name"), text: $adminUserSearchText)
                                .themedTextField()
                        }

                        Picker("", selection: adminMonitoredUserBinding) {
                            ForEach(visibleAdminUserOptions) { user in
                                Text(userOptionTitle(user))
                                    .tag(user.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.regular)
                        .disabled(visibleAdminUserOptions.isEmpty)

                        if adminUserOptions.count > visibleAdminUserOptions.count {
                            Text(strings.phrase(
                                "已显示 \(visibleAdminUserOptions.count) / \(adminUserOptions.count)，可搜索更多用户。",
                                "Showing \(visibleAdminUserOptions.count) / \(adminUserOptions.count). Search to find more users."
                            ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if adminUserOptions.isEmpty {
                    Text(strings.phrase("未获取到管理员用户列表，刷新后重试。", "Admin user list is unavailable. Refresh and try again."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
        }
    }

    private var connectionSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(strings.phrase("登录", "Login"))
                    .font(.headline)

                connectionField(strings.phrase("手动令牌", "Manual Token")) {
                    SecureField("Bearer Token", text: authTokenBinding)
                        .credentialTextInput()
                        .themedTextField()
                        .focused($focusedField, equals: .authToken)
                }

                connectionField(strings.phrase("账号", "Account")) {
                    TextField("name@example.com", text: loginEmailBinding)
                        .credentialTextInput()
                        .themedTextField()
                }
                connectionField(strings.phrase("密码", "Password")) {
                    SecureField("", text: loginPasswordBinding)
                        .credentialTextInput()
                        .themedTextField()
                        .accessibilityLabel(strings.phrase("密码", "Password"))
                }
                Button {
                    model.loginAndSave()
                } label: {
                    Label(strings.phrase("登录并保存令牌", "Login and Save Token"), systemImage: "key")
                }
                .disabled(!LoginFormState(baseURL: renderState.draft.baseURL, email: renderState.loginEmail, password: renderState.loginPassword).canSubmit || renderState.isLoggingIn)

                Button(role: .destructive) {
                    model.disconnect()
                } label: {
                    Label(strings.phrase("断开连接", "Disconnect"), systemImage: "person.crop.circle.badge.xmark")
                }
                .disabled(!renderState.configHasAuthToken && renderState.draft.authToken.isEmpty)
            }
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.callout.weight(.semibold))
                .opacity(label.isEmpty ? 0 : 1)
                .frame(width: 100, alignment: .trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            content()
        }
    }

    private func connectionField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(ClaudeTheme.secondaryText)
            content()
        }
    }

    private var strings: AppStrings {
        AppStrings(renderState.draft.language)
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { renderState.draft.language },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.language = value }
            }
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { renderState.draft.appearance },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.appearance = value }
            }
        )
    }

    private var showsMenuBarTextBinding: Binding<Bool> {
        Binding(
            get: { renderState.draft.showsMenuBarText },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.showsMenuBarText = value }
            }
        )
    }

    private var menuBarUsageWindowBinding: Binding<MenuBarUsageWindow> {
        Binding(
            get: { renderState.draft.menuBarUsageWindow },
            set: { value in
                model.applySettingsChange(refreshAfterSave: true) { $0.menuBarUsageWindow = value }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { renderState.draft.launchAtLogin },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.launchAtLogin = value }
            }
        )
    }

    private var codexTaskTimelineEventLimitBinding: Binding<Int> {
        Binding(
            get: { renderState.draft.codexTaskTimelineEventLimit },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.codexTaskTimelineEventLimit = value }
            }
        )
    }

    private var hardwareMonitorEnabledBinding: Binding<Bool> {
        Binding(
            get: { renderState.draft.hardwareMonitorEnabled },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.hardwareMonitorEnabled = value }
            }
        )
    }

    private func hardwareMonitorPageIntervalBinding(
        _ keyPath: WritableKeyPath<HardwareMonitorSyncSettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { renderState.draft.hardwareMonitorSyncSettings[keyPath: keyPath] },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) {
                    $0.hardwareMonitorSyncSettings[keyPath: keyPath] = value
                }
            }
        )
    }

    private var hardwareMonitorOfflineCheckEnabledBinding: Binding<Bool> {
        Binding(
            get: { renderState.draft.hardwareMonitorSyncSettings.offlineCheckIntervalSeconds != nil },
            set: { enabled in
                model.applySettingsChange(refreshAfterSave: false) {
                    $0.hardwareMonitorSyncSettings.offlineCheckIntervalSeconds = enabled ? 30 : nil
                }
            }
        )
    }

    private var hardwareMonitorOfflineIntervalBinding: Binding<Double> {
        Binding(
            get: { renderState.draft.hardwareMonitorSyncSettings.offlineCheckIntervalSeconds ?? 30 },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) {
                    $0.hardwareMonitorSyncSettings.offlineCheckIntervalSeconds = value
                }
            }
        )
    }

    private var hardwareMonitorNightSleepEnabledBinding: Binding<Bool> {
        Binding(
            get: { renderState.draft.hardwareMonitorSyncSettings.nightSleepEnabled },
            set: { enabled in
                model.applySettingsChange(refreshAfterSave: false) {
                    $0.hardwareMonitorSyncSettings.nightSleepEnabled = enabled
                }
            }
        )
    }

    private var hardwareMonitorNightSleepStartBinding: Binding<Int> {
        hardwareMonitorNightSleepMinuteBinding(\.nightSleepStartMinute)
    }

    private var hardwareMonitorNightSleepEndBinding: Binding<Int> {
        hardwareMonitorNightSleepMinuteBinding(\.nightSleepEndMinute)
    }

    private func hardwareMonitorNightSleepMinuteBinding(
        _ keyPath: WritableKeyPath<HardwareMonitorSyncSettings, Int>
    ) -> Binding<Int> {
        Binding(
            get: { renderState.draft.hardwareMonitorSyncSettings[keyPath: keyPath] },
            set: { value in
                let otherMinute = keyPath == \.nightSleepStartMinute
                    ? renderState.draft.hardwareMonitorSyncSettings.nightSleepEndMinute
                    : renderState.draft.hardwareMonitorSyncSettings.nightSleepStartMinute
                let adjustedValue: Int
                if value == otherMinute {
                    adjustedValue = keyPath == \.nightSleepStartMinute
                        ? (value + 1_439) % 1_440
                        : (value + 1) % 1_440
                } else {
                    adjustedValue = value
                }
                model.applySettingsChange(refreshAfterSave: false) {
                    $0.hardwareMonitorSyncSettings[keyPath: keyPath] = adjustedValue
                }
            }
        )
    }

    private func hardwareMonitorTimePicker(
        minuteOfDay: Binding<Int>,
        title: String
    ) -> some View {
        let hour = Binding<Int>(
            get: { minuteOfDay.wrappedValue / 60 },
            set: { minuteOfDay.wrappedValue = $0 * 60 + minuteOfDay.wrappedValue % 60 }
        )
        let minute = Binding<Int>(
            get: { minuteOfDay.wrappedValue % 60 },
            set: { minuteOfDay.wrappedValue = (minuteOfDay.wrappedValue / 60) * 60 + $0 }
        )
        return HStack(spacing: 2) {
            Picker("\(title) · \(strings.phrase("小时", "Hour"))", selection: hour) {
                ForEach(0..<24, id: \.self) { value in
                    Text(String(format: "%02d", value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text(":")
                .monospacedDigit()
            Picker("\(title) · \(strings.phrase("分钟", "Minute"))", selection: minute) {
                ForEach(0..<60, id: \.self) { value in
                    Text(String(format: "%02d", value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .monospacedDigit()
    }

    private func hardwareMonitorIntervalRow(
        _ title: String,
        binding: Binding<Double>,
        options: [Double] = SettingsView.hardwareMonitorPageIntervalOptions
    ) -> some View {
        settingsRow(title) {
            Picker("", selection: binding) {
                ForEach(options, id: \.self) { interval in
                    Text(hardwareMonitorIntervalLabel(interval)).tag(interval)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hardwareMonitorIntervalLabel(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        if value >= 86_400, value.isMultiple(of: 86_400) {
            let days = value / 86_400
            return strings.phrase("\(days) 天", "\(days) d")
        }
        if value >= 3_600, value.isMultiple(of: 3_600) {
            let hours = value / 3_600
            return strings.phrase("\(hours) 小时", "\(hours) h")
        }
        if value >= 60, value.isMultiple(of: 60) {
            let minutes = value / 60
            return strings.phrase("\(minutes) 分钟", "\(minutes) min")
        }
        return strings.phrase("\(value) 秒", "\(value) s")
    }

    private var hardwareMonitorStatusText: String {
        switch renderState.hardwareMonitorBLEState {
        case .disabled:
            return strings.phrase("未启用", "Disabled")
        case .waitingForBluetooth:
            return strings.phrase("正在等待蓝牙可用", "Waiting for Bluetooth")
        case .scanning:
            return strings.phrase(
                "正在扫描；首次连接请长按屏幕 KEY 进入配对",
                "Scanning; hold the screen's KEY to pair for the first time"
            )
        case let .scheduledSleep(wakeMinute):
            return strings.phrase(
                "夜间休眠时段 · 设备预计于北京时间 \(hardwareMonitorClockLabel(wakeMinute)) 唤醒",
                "Night sleep window · Expected wake at \(hardwareMonitorClockLabel(wakeMinute)) Beijing time"
            )
        case let .connecting(deviceName):
            return strings.phrase("正在连接 \(deviceName)", "Connecting to \(deviceName)")
        case let .connected(deviceName):
            return strings.phrase("已连接 \(deviceName)，正在握手", "Connected to \(deviceName); handshaking")
        case let .ready(deviceName, firmwareVersion):
            return strings.phrase(
                "\(deviceName) · 固件 \(firmwareVersion)",
                "\(deviceName) · Firmware \(firmwareVersion)"
            )
        case let .firmwareUpdateOnly(deviceName, firmwareVersion, _):
            return strings.phrase(
                "\(deviceName) · 固件 \(firmwareVersion) · 等待升级",
                "\(deviceName) · Firmware \(firmwareVersion) · Update required"
            )
        case let .unavailable(detail):
            return strings.phrase("蓝牙不可用：\(detail)", "Bluetooth unavailable: \(detail)")
        case let .failed(detail):
            return strings.phrase("连接失败：\(detail)", "Connection failed: \(detail)")
        }
    }

    private var hardwareMonitorStatusSymbol: String {
        switch renderState.hardwareMonitorBLEState {
        case .ready:
            return "checkmark.circle.fill"
        case .firmwareUpdateOnly:
            return "arrow.triangle.2.circlepath"
        case .scheduledSleep:
            return "moon.fill"
        case .connecting, .connected, .scanning, .waitingForBluetooth:
            return "antenna.radiowaves.left.and.right"
        case .unavailable, .failed:
            return "exclamationmark.triangle.fill"
        case .disabled:
            return "circle"
        }
    }

    private var hardwareMonitorStatusColor: Color {
        switch renderState.hardwareMonitorBLEState {
        case .ready:
            return .green
        case .firmwareUpdateOnly:
            return .orange
        case .scheduledSleep:
            return .blue
        case .unavailable, .failed:
            return .orange
        default:
            return .secondary
        }
    }

    private func hardwareMonitorClockLabel(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    private var languageItems: [GlassSegmentedItem<AppLanguage>] {
        [AppLanguage.zhHans, .en].map {
            GlassSegmentedItem(value: $0, title: strings.languageName($0))
        }
    }

    private var appearanceItems: [GlassSegmentedItem<AppAppearance>] {
        AppAppearance.allCases.map {
            GlassSegmentedItem(
                value: $0,
                title: strings.appearanceName($0),
                systemImage: $0.systemImageName
            )
        }
    }

    private var usageWindowItems: [GlassSegmentedItem<MenuBarUsageWindow>] {
        MenuBarUsageWindow.allCases.map {
            GlassSegmentedItem(value: $0, title: strings.usageWindowName($0))
        }
    }

    private var isAdminAccount: Bool {
        renderState.isAdminAccount
    }

    private var availableMenuBarDisplayItems: [MenuBarDisplayItem] {
        CapabilityPolicy(isAdminAccount: isAdminAccount).visibleMenuBarDisplayItems
    }

    private var adminUserOptions: [AdminUserSummary] {
        renderState.adminUsers
    }

    private var visibleAdminUserOptions: [AdminUserSummary] {
        let selectedID = selectedAdminMonitoredUserID
        let query = adminUserSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchedUsers: [AdminUserSummary]
        if query.isEmpty {
            matchedUsers = Array(adminUserOptions.prefix(Self.maxAdminUserPickerOptions))
        } else {
            matchedUsers = Array(adminUserOptions.filter { adminUser($0, matches: query) }.prefix(Self.maxAdminUserPickerOptions))
        }

        guard let selectedUser = adminUserOptions.first(where: { $0.id == selectedID }),
              matchedUsers.contains(where: { $0.id == selectedID }) == false else {
            return matchedUsers
        }
        return [selectedUser] + Array(matchedUsers.prefix(Self.maxAdminUserPickerOptions - 1))
    }

    private var adminMonitoredUserBinding: Binding<Int64> {
        Binding(
            get: {
                selectedAdminMonitoredUserID
            },
            set: { value in
                model.applySettingsChange(refreshAfterSave: true) { draft in
                    draft.monitorMode = .admin
                    draft.adminMonitoredUserID = value
                }
            }
        )
    }

    private var selectedAdminMonitoredUserID: Int64 {
        renderState.draft.adminMonitoredUserID
            ?? renderState.currentUserID
            ?? adminUserOptions.first?.id
            ?? 0
    }

    private func adminUser(_ user: AdminUserSummary, matches query: String) -> Bool {
        user.email.lowercased().contains(query)
            || user.username.lowercased().contains(query)
            || String(user.id).contains(query)
    }

    private func userOptionTitle(_ user: AdminUserSummary) -> String {
        let name = user.displayName
        if name == user.email {
            return user.email
        }
        return "\(name) <\(user.email)>"
    }

    private func menuBarItemBinding(_ item: MenuBarDisplayItem) -> Binding<Bool> {
        Binding(
            get: {
                renderState.draft.menuBarDisplayItems.contains(item)
            },
            set: { isEnabled in
                model.applySettingsChange(refreshAfterSave: false) { draft in
                    if item.isAdminOnly {
                        guard isAdminAccount else {
                            draft.menuBarDisplayItems.removeAll { $0 == item }
                            return
                        }
                        draft.monitorMode = .admin
                    }
                    if isEnabled {
                        if !draft.menuBarDisplayItems.contains(item) {
                            draft.menuBarDisplayItems.append(item)
                        }
                    } else {
                        draft.menuBarDisplayItems.removeAll { $0 == item }
                    }
                }
            }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { renderState.draft.baseURL },
            set: { value in
                model.settingsDraft.baseURL = value
                model.scheduleSettingsAutosave(refreshAfterSave: false)
            }
        )
    }

    private var authTokenBinding: Binding<String> {
        Binding(
            get: { renderState.draft.authToken },
            set: { value in
                model.settingsDraft.authToken = value
                model.scheduleSettingsAutosave(refreshAfterSave: false)
            }
        )
    }

    private var refreshIntervalBinding: Binding<Double> {
        Binding(
            get: { renderState.draft.refreshIntervalSeconds },
            set: { model.settingsDraft.refreshIntervalSeconds = $0 }
        )
    }

    private var loginEmailBinding: Binding<String> {
        Binding(
            get: { renderState.loginEmail },
            set: { model.loginEmail = $0 }
        )
    }

    private var loginPasswordBinding: Binding<String> {
        Binding(
            get: { renderState.loginPassword },
            set: { model.loginPassword = $0 }
        )
    }
}

@MainActor
private final class SettingsRenderState: ObservableObject {
    @Published private(set) var draft: AppConfig
    @Published private(set) var settingsError: String?
    @Published private(set) var adminUsers: [AdminUserSummary]
    @Published private(set) var isAdminAccount: Bool
    @Published private(set) var currentUserID: Int64?
    @Published private(set) var loginEmail: String
    @Published private(set) var loginPassword: String
    @Published private(set) var isLoggingIn: Bool
    @Published private(set) var configHasAuthToken: Bool
    @Published private(set) var hardwareMonitorBLEState: HardwareMonitorBLEConnectionState
    @Published private(set) var hardwareFirmwareUpdateState: HardwareFirmwareUpdateState
    @Published private(set) var isInstallingAppUpdate: Bool

    private var cancellables: Set<AnyCancellable> = []

    init(model: MonitorViewModel) {
        draft = model.settingsDraft
        settingsError = model.settingsError
        adminUsers = model.adminUsers
        isAdminAccount = model.snapshot.currentUser?.isAdmin == true
        currentUserID = model.snapshot.currentUser?.id
        loginEmail = model.loginEmail
        loginPassword = model.loginPassword
        isLoggingIn = model.isLoggingIn
        configHasAuthToken = !model.config.authToken.isEmpty
        hardwareMonitorBLEState = model.hardwareMonitorBLEState
        hardwareFirmwareUpdateState = model.hardwareFirmwareUpdateState
        isInstallingAppUpdate = model.isInstallingUpdate

        model.$settingsDraft
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.draft = $0 }
            .store(in: &cancellables)
        model.$settingsError
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.settingsError = $0 }
            .store(in: &cancellables)
        model.$adminUsers
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.adminUsers = $0 }
            .store(in: &cancellables)
        model.$snapshot
            .map {
                SettingsAccessState(
                    isAdminAccount: $0.currentUser?.isAdmin == true,
                    currentUserID: $0.currentUser?.id
                )
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] accessState in
                self?.isAdminAccount = accessState.isAdminAccount
                self?.currentUserID = accessState.currentUserID
            }
            .store(in: &cancellables)
        model.$loginEmail
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.loginEmail = $0 }
            .store(in: &cancellables)
        model.$loginPassword
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.loginPassword = $0 }
            .store(in: &cancellables)
        model.$isLoggingIn
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.isLoggingIn = $0 }
            .store(in: &cancellables)
        model.$config
            .map { !$0.authToken.isEmpty }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.configHasAuthToken = $0 }
            .store(in: &cancellables)
        model.$hardwareMonitorBLEState
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.hardwareMonitorBLEState = $0 }
            .store(in: &cancellables)
        model.$hardwareFirmwareUpdateState
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.hardwareFirmwareUpdateState = $0 }
            .store(in: &cancellables)
        model.$isInstallingUpdate
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] in self?.isInstallingAppUpdate = $0 }
            .store(in: &cancellables)
    }
}

private struct SettingsAccessState: Equatable {
    let isAdminAccount: Bool
    let currentUserID: Int64?
}

private extension AppAppearance {
    var systemImageName: String {
        switch self {
        case .system:
            return "display"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }
}

private enum SettingsField: Hashable {
    case baseURL
    case authToken
}

private enum LoginField: Hashable {
    case baseURL
    case email
    case password
    case authToken
}
