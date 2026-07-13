import Foundation

public enum AppCapability: String, Sendable, Equatable, Hashable {
    case codexTaskMonitoring
    case codexNodeConfiguration
    case adminNormalAccounts
    case adminRealtimeConcurrency
    case adminSelectedUserMonitoring
}

public struct CapabilityPolicy: Sendable, Equatable {
    public let isAdminAccount: Bool

    public init(isAdminAccount: Bool) {
        self.isAdminAccount = isAdminAccount
    }

    public func allows(_ capability: AppCapability) -> Bool {
        switch capability {
        case .codexTaskMonitoring, .codexNodeConfiguration:
            return true
        case .adminNormalAccounts, .adminRealtimeConcurrency, .adminSelectedUserMonitoring:
            return isAdminAccount
        }
    }

    public var visibleMenuBarDisplayItems: [MenuBarDisplayItem] {
        MenuBarDisplayItem.allCases.filter { item in
            switch item {
            case .normalAccounts:
                return allows(.adminNormalAccounts)
            case .realtimeConcurrency:
                return allows(.adminRealtimeConcurrency)
            case .fiveHourRemaining, .sevenDayRemaining:
                return isAdminAccount
            case .rpm:
                return !isAdminAccount
            default:
                return true
            }
        }
    }
}
