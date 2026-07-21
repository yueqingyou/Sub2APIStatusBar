import Combine
import SwiftUI
import Sub2APIStatusCore

struct LoginPanel: View {
    @ObservedObject var model: MonitorViewModel
    @FocusState private var focusedField: LoginField?

    private var formState: LoginFormState {
        LoginFormState(
            baseURL: model.settingsDraft.baseURL,
            email: model.loginEmail,
            password: model.loginPassword
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ClaudeTheme.elevatedCard)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ClaudeTheme.accent.opacity(0.08))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(ClaudeTheme.glassBorder, lineWidth: 0.75)
                    Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .frame(width: 56, height: 56)
                .shadow(color: ClaudeTheme.glassShadow, radius: 7, y: 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text("TokenRouter")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text(strings.phrase("连接你的服务", "Connect your server"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(strings.phrase("语言", "Language"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ClaudeTheme.secondaryText)
                        GlassSegmentedControl(
                            selection: languageBinding,
                            items: languageItems
                        )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(strings.phrase("外观", "Appearance"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(ClaudeTheme.secondaryText)
                        GlassSegmentedControl(
                            selection: appearanceBinding,
                            items: appearanceItems
                        )
                    }

                    TextField(strings.phrase("服务地址", "Server URL"), text: $model.settingsDraft.baseURL)
                        .themedTextField()
                        .focused($focusedField, equals: .baseURL)
                        .onChange(of: model.settingsDraft.baseURL) { _ in
                            model.scheduleSettingsAutosave(refreshAfterSave: false)
                        }

                    TextField(strings.phrase("账号", "Account"), text: $model.loginEmail)
                        .themedTextField()
                        .focused($focusedField, equals: .email)

                    SecureField(strings.phrase("密码", "Password"), text: $model.loginPassword)
                        .themedTextField()
                        .focused($focusedField, equals: .password)

                    RefreshIntervalControl(
                        seconds: $model.settingsDraft.refreshIntervalSeconds,
                        strings: strings,
                        title: strings.phrase("刷新间隔", "Refresh Interval")
                    ) {
                        model.scheduleSettingsAutosave(refreshAfterSave: false)
                    }
                }
            }

            if let error = model.settingsError {
                MessageRow(message: error)
            }

            Button {
                model.loginAndSave()
            } label: {
                HStack {
                    if model.isLoggingIn {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "key.fill")
                    }
                    Text(model.isLoggingIn ? strings.phrase("连接中...", "Connecting...") : strings.phrase("登录", "Login"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!formState.canSubmit || model.isLoggingIn)

            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(strings.phrase("手动令牌", "Manual token"))
                        .font(.headline)
                    SecureField("Bearer Token", text: $model.settingsDraft.authToken)
                        .themedTextField()
                        .focused($focusedField, equals: .authToken)
                        .onChange(of: model.settingsDraft.authToken) { _ in
                            model.scheduleSettingsAutosave(refreshAfterSave: false)
                        }
                    Button {
                        model.saveSettings()
                    } label: {
                        Label(strings.phrase("保存令牌", "Save Token"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.settingsDraft.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Spacer()

            HStack {
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
        }
        .padding(22)
        .frame(width: 520, height: 680)
        .background(PanelBackground())
        .environment(\.appLanguage, model.settingsDraft.language)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = model.settingsDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .baseURL : .email
            }
        }
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

    init(model: MonitorViewModel) {
        self.model = model
        _renderState = StateObject(wrappedValue: SettingsRenderState(model: model))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                settingsHeader

                generalSettingsCard

                menuBarSettingsCard

                taskConsoleSettingsCard

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

    private var settingsHeader: some View {
        PanelPageHeader(
            title: strings.phrase("设置", "Settings"),
            subtitle: strings.phrase("外观、连接、菜单栏与更新", "Appearance, connection, menu bar, and updates")
        )
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

                settingsRow("Base URL") {
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

                Text(strings.phrase(
                    "事件时间线默认折叠，仅在展开任务卡时显示最近事件，用于排查 hooks 上报细节。",
                    "The event timeline is collapsed by default. Recent events appear only after expanding a task card for hook diagnostics."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    private var adminMonitoringSettingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(strings.phrase("管理员监控", "Admin Monitoring"))
                    .font(.headline)

                Text(strings.phrase("使用当前管理员账号权限选择要监控的用户。普通用户账号不会显示这些项目。", "Use the current admin account to choose which user to monitor. Normal user accounts do not show these items."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

                if renderState.hasRealtimeConcurrency {
                    Text(strings.phrase("实时并发来自管理员运维接口。", "Realtime concurrency comes from the admin ops endpoint."))
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

                SecureField("Bearer Token", text: authTokenBinding)
                    .themedTextField()
                    .focused($focusedField, equals: .authToken)

                TextField("Email", text: loginEmailBinding)
                    .themedTextField()
                SecureField(strings.phrase("密码", "Password"), text: loginPasswordBinding)
                    .themedTextField()
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
    @Published private(set) var hasRealtimeConcurrency: Bool
    @Published private(set) var loginEmail: String
    @Published private(set) var loginPassword: String
    @Published private(set) var isLoggingIn: Bool
    @Published private(set) var configHasAuthToken: Bool

    private var cancellables: Set<AnyCancellable> = []

    init(model: MonitorViewModel) {
        draft = model.settingsDraft
        settingsError = model.settingsError
        adminUsers = model.adminUsers
        isAdminAccount = model.snapshot.currentUser?.isAdmin == true
        currentUserID = model.snapshot.currentUser?.id
        hasRealtimeConcurrency = model.snapshot.realtimeConcurrency != nil
        loginEmail = model.loginEmail
        loginPassword = model.loginPassword
        isLoggingIn = model.isLoggingIn
        configHasAuthToken = !model.config.authToken.isEmpty

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
                    currentUserID: $0.currentUser?.id,
                    hasRealtimeConcurrency: $0.realtimeConcurrency != nil
                )
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] accessState in
                self?.isAdminAccount = accessState.isAdminAccount
                self?.currentUserID = accessState.currentUserID
                self?.hasRealtimeConcurrency = accessState.hasRealtimeConcurrency
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
    }
}

private struct SettingsAccessState: Equatable {
    let isAdminAccount: Bool
    let currentUserID: Int64?
    let hasRealtimeConcurrency: Bool
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
