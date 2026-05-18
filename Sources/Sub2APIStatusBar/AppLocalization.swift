import SwiftUI
import Sub2APIStatusCore

struct AppStrings {
    let language: AppLanguage

    init(_ language: AppLanguage) {
        self.language = language == .en ? .en : .zhHans
    }

    func phrase(_ zhHans: String, _ en: String) -> String {
        language == .en ? en : zhHans
    }

    func languageName(_ value: AppLanguage) -> String {
        switch value {
        case .zhHans, .auto:
            return phrase("简体中文", "Chinese")
        case .en:
            return phrase("英文", "English")
        }
    }

    func statusLabel(for snapshot: MonitorSnapshot) -> String {
        if !snapshot.connected {
            return phrase("未连接", "Disconnected")
        }

        if let summary = snapshot.subscriptionSummary {
            if summary.highestProgress >= 0.95 {
                return phrase("接近限额", "Near Limit")
            }
            if summary.highestProgress >= 0.8 {
                return phrase("用量偏高", "High Usage")
            }
            if summary.expiringSoonCount > 0 {
                return phrase("即将过期", "Expiring Soon")
            }
        }

        switch snapshot.severity {
        case .healthy:
            return phrase("正常", "OK")
        case .warning:
            return phrase("警告", "Warn")
        case .error:
            return phrase("错误", "Error")
        }
    }

    func usageWindowName(_ window: MenuBarUsageWindow) -> String {
        switch window {
        case .last24Hours:
            return phrase("过去 24 小时", "Last 24 Hours")
        case .today:
            return phrase("今天", "Today")
        }
    }

    func menuBarItemName(_ item: MenuBarDisplayItem) -> String {
        switch item {
        case .totalCost:
            return phrase("总费用", "Total Cost")
        case .totalRequests:
            return phrase("总请求", "Total Requests")
        case .model:
            return phrase("模型", "Model")
        case .reasoningEffort:
            return phrase("推理强度", "Reasoning Effort")
        case .contextLength:
            return phrase("上下文长度", "Context Length")
        case .fast:
            return phrase("Fast 状态", "Fast Enabled")
        case .inputPrice:
            return phrase("输入价格", "Input Price")
        case .outputPrice:
            return phrase("输出价格", "Output Price")
        case .rpm:
            return phrase("实时 RPM", "Realtime RPM")
        }
    }

    func updateStatus(_ info: UpdateInfo) -> String {
        if info.isUpdateAvailable {
            return phrase("发现版本 \(info.latestRelease.version)。", "Version \(info.latestRelease.version) is available.")
        }
        return phrase("当前已是最新版本。", "You are up to date.")
    }

    func activeStatus(_ rawValue: String) -> String {
        rawValue.lowercased() == "active" ? phrase("活跃", "Active") : rawValue
    }

    func updated(at date: Date?) -> String {
        guard let date else {
            return phrase("等待首次刷新", "Waiting for first refresh")
        }
        return phrase(
            "更新于 \(date.formatted(date: .omitted, time: .shortened))",
            "Updated \(date.formatted(date: .omitted, time: .shortened))"
        )
    }
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .zhHans
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}
