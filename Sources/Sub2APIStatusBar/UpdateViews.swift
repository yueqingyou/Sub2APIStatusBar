import SwiftUI
import Sub2APIStatusCore

struct UpdateSettingsSection: View {
    @ObservedObject var model: MonitorViewModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(strings.phrase("更新", "Updates"))
                        .font(.headline)
                    Spacer()
                    if model.isCheckingForUpdates || model.isInstallingUpdate {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let updateInfo = model.updateInfo, updateInfo.isUpdateAvailable {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(ClaudeTheme.success)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(strings.updateStatus(updateInfo))
                                .font(.callout.weight(.medium))
                            Text(updateInfo.latestRelease.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let message = model.updateStatusMessage,
                               message != strings.updateStatus(updateInfo),
                               message != updateInfo.statusText {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else if let message = model.updateStatusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(strings.phrase("检查 GitHub Releases 中的新版本。", "Checks GitHub Releases for newer versions."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    Button {
                        model.checkForUpdates()
                    } label: {
                        Label(strings.phrase("立即检查", "Check Now"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isCheckingForUpdates || model.isInstallingUpdate)

                    if model.updateInfo?.isUpdateAvailable == true {
                        if model.updateInfo?.latestRelease.installArchiveAsset() != nil {
                            Button {
                                model.installUpdate()
                            } label: {
                                Label(strings.phrase("安装更新", "Install Update"), systemImage: "arrow.down.circle")
                            }
                            .disabled(model.isCheckingForUpdates || model.isInstallingUpdate)
                        }

                        Button {
                            model.openLatestRelease()
                        } label: {
                            Label(strings.phrase("打开发布页", "Open Release"), systemImage: "safari")
                        }
                        .disabled(model.isInstallingUpdate)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var strings: AppStrings {
        AppStrings(model.settingsDraft.language)
    }
}

struct UpdateAvailableBanner: View {
    @Environment(\.appLanguage) private var language

    let info: UpdateInfo
    let isInstalling: Bool
    let statusMessage: String?
    let installUpdate: () -> Void
    let openRelease: () -> Void

    private var canInstallDirectly: Bool {
        info.latestRelease.installArchiveAsset() != nil
    }

    private var detailText: String {
        if let statusMessage,
           statusMessage != info.statusText,
           statusMessage != strings.updateStatus(info) {
            return statusMessage
        }
        return canInstallDirectly
            ? strings.phrase("可直接安装，也可以打开 GitHub 发布页。", "Install directly or open the GitHub release.")
            : strings.phrase("从 GitHub 下载最新版本。", "Download the latest release from GitHub.")
    }

    var body: some View {
        HStack(spacing: 10) {
            if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.success)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(strings.updateStatus(info))
                    .font(.callout.weight(.semibold))
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canInstallDirectly {
                Button {
                    installUpdate()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .disabled(isInstalling)
                .help(strings.phrase("安装更新", "Install update"))
            }
            Button {
                openRelease()
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .disabled(isInstalling)
            .help(strings.phrase("打开发布页", "Open release"))
        }
        .padding(12)
        .glassSurface(cornerRadius: 11)
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}
