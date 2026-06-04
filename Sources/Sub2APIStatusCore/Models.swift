import Foundation

public enum Sub2APIError: Error, LocalizedError, Equatable, Sendable {
    case api(code: Int, message: String)
    case missingData
    case invalidBaseURL
    case badStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case let .api(code, message):
            return "API \(code): \(message)"
        case .missingData:
            return "Response did not include data."
        case .invalidBaseURL:
            return "Base URL is invalid."
        case let .badStatus(status, message):
            return "HTTP \(status): \(message)"
        }
    }

    public var isUnauthorized: Bool {
        switch self {
        case let .badStatus(status, _):
            return status == 401
        default:
            return false
        }
    }

    public var isTransientFailure: Bool {
        switch self {
        case let .badStatus(status, _):
            return status == 429 || (500..<600).contains(status)
        default:
            return false
        }
    }
}

public struct Sub2APIEnvelope<Value: Decodable & Sendable>: Decodable, Sendable {
    public let code: Int
    public let message: String
    public let data: Value?

    public func value() throws -> Value {
        guard code == 0 else {
            throw Sub2APIError.api(code: code, message: message)
        }
        guard let data else {
            throw Sub2APIError.missingData
        }
        return data
    }
}

public struct LoginRequest: Encodable, Sendable {
    public let email: String
    public let password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

public struct LoginFormState: Equatable, Sendable {
    public var baseURL: String
    public var email: String
    public var password: String

    public init(baseURL: String, email: String, password: String) {
        self.baseURL = baseURL
        self.email = email
        self.password = password
    }

    public var canSubmit: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }
}

public struct AuthResponse: Decodable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let tokenType: String?
    public let user: CurrentUser?
}

public struct CurrentUserResponse: Decodable, Equatable, Sendable {
    public let user: CurrentUser

    private enum CodingKeys: String, CodingKey {
        case user
    }

    public init(user: CurrentUser) {
        self.user = user
    }

    public init(from decoder: Decoder) throws {
        if let wrapped = try? decoder.container(keyedBy: CodingKeys.self),
           wrapped.contains(.user) {
            user = try wrapped.decode(CurrentUser.self, forKey: .user)
            return
        }

        user = try CurrentUser(from: decoder)
    }
}

public struct CurrentUser: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int64
    public let email: String
    public let username: String?
    public let role: String
    public let balance: Double?
    public let concurrency: Int
    public let status: String?

    public var isAdmin: Bool {
        role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "admin"
    }
}

public struct AdminUserSummary: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int64
    public let email: String
    public let username: String
    public let role: String
    public let balance: Double
    public let status: String
    public let concurrency: Int
    public let currentConcurrency: Int?

    public init(
        id: Int64,
        email: String,
        username: String,
        role: String,
        balance: Double,
        status: String,
        concurrency: Int,
        currentConcurrency: Int? = nil
    ) {
        self.id = id
        self.email = email
        self.username = username
        self.role = role
        self.balance = balance
        self.status = status
        self.concurrency = concurrency
        self.currentConcurrency = currentConcurrency
    }

    public var displayName: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? email : username
    }
}

public struct AdminUsersPage: Decodable, Equatable, Sendable {
    public let items: [AdminUserSummary]
    public let total: Int
    public let page: Int
    public let pageSize: Int
    public let pages: Int
}

public struct UserRealtimeConcurrency: Decodable, Identifiable, Equatable, Sendable {
    public var id: Int64 { userID }

    public let userID: Int64
    public let userEmail: String
    public let username: String
    public let currentInUse: Int64
    public let maxCapacity: Int64
    public let loadPercentage: Double
    public let waitingInQueue: Int64

    public init(
        userID: Int64,
        userEmail: String,
        username: String,
        currentInUse: Int64,
        maxCapacity: Int64,
        loadPercentage: Double,
        waitingInQueue: Int64
    ) {
        self.userID = userID
        self.userEmail = userEmail
        self.username = username
        self.currentInUse = currentInUse
        self.maxCapacity = maxCapacity
        self.loadPercentage = loadPercentage
        self.waitingInQueue = waitingInQueue
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case userEmail
        case username
        case currentInUse
        case maxCapacity
        case loadPercentage
        case waitingInQueue
    }
}

public struct AdminUserConcurrencyStats: Decodable, Equatable, Sendable {
    public let enabled: Bool
    public let users: [String: UserRealtimeConcurrency]
    public let timestamp: Date?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case users = "user"
        case timestamp
    }

    public func concurrency(
        forUserID userID: Int64,
        userEmail: String,
        username: String?,
        maxCapacity: Int
    ) -> UserRealtimeConcurrency? {
        guard enabled else {
            return nil
        }

        if let exact = users[String(userID)] {
            return exact
        }

        return UserRealtimeConcurrency(
            userID: userID,
            userEmail: userEmail,
            username: username ?? "",
            currentInUse: 0,
            maxCapacity: Int64(maxCapacity),
            loadPercentage: 0,
            waitingInQueue: 0
        )
    }
}

public struct AdminSubscriptionGroup: Decodable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let dailyLimitUSD: Double?
    public let weeklyLimitUSD: Double?
    public let monthlyLimitUSD: Double?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case dailyLimitUSD = "dailyLimitUsd"
        case weeklyLimitUSD = "weeklyLimitUsd"
        case monthlyLimitUSD = "monthlyLimitUsd"
    }
}

public struct AdminUserSubscription: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int64
    public let userID: Int64
    public let groupID: Int64
    public let startsAt: String?
    public let expiresAt: String?
    public let status: String
    public let dailyUsageUSD: Double
    public let weeklyUsageUSD: Double
    public let monthlyUsageUSD: Double
    public let group: AdminSubscriptionGroup?

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "userId"
        case groupID = "groupId"
        case startsAt
        case expiresAt
        case status
        case dailyUsageUSD = "dailyUsageUsd"
        case weeklyUsageUSD = "weeklyUsageUsd"
        case monthlyUsageUSD = "monthlyUsageUsd"
        case group
    }
}

public struct RealtimeMetrics: Decodable, Equatable, Sendable {
    public let activeRequests: Int
    public let requestsPerMinute: Double
    public let averageResponseTime: Double
    public let errorRate: Double

    public init(activeRequests: Int = 0, requestsPerMinute: Double = 0, averageResponseTime: Double = 0, errorRate: Double = 0) {
        self.activeRequests = activeRequests
        self.requestsPerMinute = requestsPerMinute
        self.averageResponseTime = averageResponseTime
        self.errorRate = errorRate
    }

    private enum CodingKeys: String, CodingKey {
        case activeRequests
        case requestsPerMinute
        case averageResponseTime
        case errorRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeRequests = try container.decodeIfPresent(Int.self, forKey: .activeRequests) ?? 0
        requestsPerMinute = try container.decodeIfPresent(Double.self, forKey: .requestsPerMinute) ?? 0
        averageResponseTime = try container.decodeIfPresent(Double.self, forKey: .averageResponseTime) ?? 0
        errorRate = try container.decodeIfPresent(Double.self, forKey: .errorRate) ?? 0
    }
}

public struct DashboardStats: Decodable, Equatable, Sendable {
    public let totalUsers: Int
    public let activeUsers: Int
    public let totalAPIKeys: Int
    public let activeAPIKeys: Int
    public let totalAccounts: Int
    public let normalAccounts: Int
    public let errorAccounts: Int
    public let ratelimitAccounts: Int
    public let overloadAccounts: Int
    public let totalRequests: Int64
    public let totalTokens: Int64
    public let totalInputTokens: Int64
    public let totalOutputTokens: Int64
    public let totalCacheCreationTokens: Int64
    public let totalCacheReadTokens: Int64
    public let totalCost: Double
    public let totalActualCost: Double
    public let todayRequests: Int64
    public let todayTokens: Int64
    public let todayInputTokens: Int64
    public let todayOutputTokens: Int64
    public let todayCacheCreationTokens: Int64
    public let todayCacheReadTokens: Int64
    public let todayCost: Double
    public let todayActualCost: Double
    public let averageDurationMs: Double
    public let uptime: Double
    public let rpm: Double
    public let tpm: Double

    public init(
        totalUsers: Int = 0,
        activeUsers: Int = 0,
        totalAPIKeys: Int = 0,
        activeAPIKeys: Int = 0,
        totalAccounts: Int = 0,
        normalAccounts: Int = 0,
        errorAccounts: Int = 0,
        ratelimitAccounts: Int = 0,
        overloadAccounts: Int = 0,
        totalRequests: Int64 = 0,
        totalTokens: Int64 = 0,
        totalInputTokens: Int64 = 0,
        totalOutputTokens: Int64 = 0,
        totalCacheCreationTokens: Int64 = 0,
        totalCacheReadTokens: Int64 = 0,
        totalCost: Double = 0,
        totalActualCost: Double = 0,
        todayRequests: Int64 = 0,
        todayTokens: Int64 = 0,
        todayInputTokens: Int64 = 0,
        todayOutputTokens: Int64 = 0,
        todayCacheCreationTokens: Int64 = 0,
        todayCacheReadTokens: Int64 = 0,
        todayCost: Double = 0,
        todayActualCost: Double = 0,
        averageDurationMs: Double = 0,
        uptime: Double = 0,
        rpm: Double = 0,
        tpm: Double = 0
    ) {
        self.totalUsers = totalUsers
        self.activeUsers = activeUsers
        self.totalAPIKeys = totalAPIKeys
        self.activeAPIKeys = activeAPIKeys
        self.totalAccounts = totalAccounts
        self.normalAccounts = normalAccounts
        self.errorAccounts = errorAccounts
        self.ratelimitAccounts = ratelimitAccounts
        self.overloadAccounts = overloadAccounts
        self.totalRequests = totalRequests
        self.totalTokens = totalTokens
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCacheCreationTokens = totalCacheCreationTokens
        self.totalCacheReadTokens = totalCacheReadTokens
        self.totalCost = totalCost
        self.totalActualCost = totalActualCost
        self.todayRequests = todayRequests
        self.todayTokens = todayTokens
        self.todayInputTokens = todayInputTokens
        self.todayOutputTokens = todayOutputTokens
        self.todayCacheCreationTokens = todayCacheCreationTokens
        self.todayCacheReadTokens = todayCacheReadTokens
        self.todayCost = todayCost
        self.todayActualCost = todayActualCost
        self.averageDurationMs = averageDurationMs
        self.uptime = uptime
        self.rpm = rpm
        self.tpm = tpm
    }

    private enum CodingKeys: String, CodingKey {
        case totalUsers
        case activeUsers
        case totalAPIKeys = "totalApiKeys"
        case activeAPIKeys = "activeApiKeys"
        case totalAccounts
        case normalAccounts
        case errorAccounts
        case ratelimitAccounts
        case overloadAccounts
        case totalRequests
        case totalTokens
        case totalInputTokens
        case totalOutputTokens
        case totalCacheCreationTokens
        case totalCacheReadTokens
        case totalCost
        case totalActualCost
        case todayRequests
        case todayTokens
        case todayInputTokens
        case todayOutputTokens
        case todayCacheCreationTokens
        case todayCacheReadTokens
        case todayCost
        case todayActualCost
        case averageDurationMs
        case uptime
        case rpm
        case tpm
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalUsers = try container.decodeIfPresent(Int.self, forKey: .totalUsers) ?? 0
        activeUsers = try container.decodeIfPresent(Int.self, forKey: .activeUsers) ?? 0
        totalAPIKeys = try container.decodeIfPresent(Int.self, forKey: .totalAPIKeys) ?? 0
        activeAPIKeys = try container.decodeIfPresent(Int.self, forKey: .activeAPIKeys) ?? 0
        totalAccounts = try container.decodeIfPresent(Int.self, forKey: .totalAccounts) ?? 0
        normalAccounts = try container.decodeIfPresent(Int.self, forKey: .normalAccounts) ?? 0
        errorAccounts = try container.decodeIfPresent(Int.self, forKey: .errorAccounts) ?? 0
        ratelimitAccounts = try container.decodeIfPresent(Int.self, forKey: .ratelimitAccounts) ?? 0
        overloadAccounts = try container.decodeIfPresent(Int.self, forKey: .overloadAccounts) ?? 0
        totalRequests = try container.decodeIfPresent(Int64.self, forKey: .totalRequests) ?? 0
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        totalInputTokens = try container.decodeIfPresent(Int64.self, forKey: .totalInputTokens) ?? 0
        totalOutputTokens = try container.decodeIfPresent(Int64.self, forKey: .totalOutputTokens) ?? 0
        totalCacheCreationTokens = try container.decodeIfPresent(Int64.self, forKey: .totalCacheCreationTokens) ?? 0
        totalCacheReadTokens = try container.decodeIfPresent(Int64.self, forKey: .totalCacheReadTokens) ?? 0
        totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        totalActualCost = try container.decodeIfPresent(Double.self, forKey: .totalActualCost) ?? 0
        todayRequests = try container.decodeIfPresent(Int64.self, forKey: .todayRequests) ?? 0
        todayTokens = try container.decodeIfPresent(Int64.self, forKey: .todayTokens) ?? 0
        todayInputTokens = try container.decodeIfPresent(Int64.self, forKey: .todayInputTokens) ?? 0
        todayOutputTokens = try container.decodeIfPresent(Int64.self, forKey: .todayOutputTokens) ?? 0
        todayCacheCreationTokens = try container.decodeIfPresent(Int64.self, forKey: .todayCacheCreationTokens) ?? 0
        todayCacheReadTokens = try container.decodeIfPresent(Int64.self, forKey: .todayCacheReadTokens) ?? 0
        todayCost = try container.decodeIfPresent(Double.self, forKey: .todayCost) ?? 0
        todayActualCost = try container.decodeIfPresent(Double.self, forKey: .todayActualCost) ?? 0
        averageDurationMs = try container.decodeIfPresent(Double.self, forKey: .averageDurationMs) ?? 0
        uptime = try container.decodeIfPresent(Double.self, forKey: .uptime) ?? 0
        rpm = try container.decodeIfPresent(Double.self, forKey: .rpm) ?? 0
        tpm = try container.decodeIfPresent(Double.self, forKey: .tpm) ?? 0
    }
}

public struct ModelUsageSummary: Decodable, Identifiable, Equatable, Sendable {
    public var id: String { model }

    public let model: String
    public let requests: Int64
    public let totalTokens: Int64
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheCreationTokens: Int64
    public let cacheReadTokens: Int64
    public let cost: Double
    public let actualCost: Double
    public let accountCost: Double
    public let standardCost: Double

    public init(
        model: String,
        requests: Int64 = 0,
        totalTokens: Int64 = 0,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheCreationTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cost: Double = 0,
        actualCost: Double = 0,
        accountCost: Double = 0,
        standardCost: Double = 0
    ) {
        self.model = model
        self.requests = requests
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.cost = cost
        self.actualCost = actualCost
        self.accountCost = accountCost
        self.standardCost = standardCost
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case requests
        case totalTokens
        case inputTokens
        case outputTokens
        case cacheCreationTokens
        case cacheReadTokens
        case cost
        case actualCost
        case accountCost
        case standardCost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "Unknown"
        requests = try container.decodeIfPresent(Int64.self, forKey: .requests) ?? 0
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        cacheCreationTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheReadTokens) ?? 0
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        actualCost = try container.decodeIfPresent(Double.self, forKey: .actualCost) ?? 0
        accountCost = try container.decodeIfPresent(Double.self, forKey: .accountCost) ?? actualCost
        standardCost = try container.decodeIfPresent(Double.self, forKey: .standardCost) ?? cost
    }
}

public struct TrendDataPoint: Decodable, Identifiable, Equatable, Sendable {
    public var id: String { date }

    public let date: String
    public let requests: Int64
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheCreationTokens: Int64
    public let cacheReadTokens: Int64
    public let totalTokens: Int64
    public let cost: Double
    public let actualCost: Double

    public init(
        date: String,
        requests: Int64 = 0,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheCreationTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        totalTokens: Int64 = 0,
        cost: Double = 0,
        actualCost: Double = 0
    ) {
        self.date = date
        self.requests = requests
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.cost = cost
        self.actualCost = actualCost
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case requests
        case inputTokens
        case outputTokens
        case cacheCreationTokens
        case cacheReadTokens
        case totalTokens
        case cost
        case actualCost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        requests = try container.decodeIfPresent(Int64.self, forKey: .requests) ?? 0
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        cacheCreationTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheReadTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        cost = try container.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        actualCost = try container.decodeIfPresent(Double.self, forKey: .actualCost) ?? 0
    }
}

public struct DashboardTrendResponse: Decodable, Equatable, Sendable {
    public let startDate: String?
    public let endDate: String?
    public let granularity: String?
    public let trend: [TrendDataPoint]

    public init(startDate: String? = nil, endDate: String? = nil, granularity: String? = nil, trend: [TrendDataPoint] = []) {
        self.startDate = startDate
        self.endDate = endDate
        self.granularity = granularity
        self.trend = trend
    }
}

public struct DashboardModelsResponse: Decodable, Equatable, Sendable {
    public let startDate: String?
    public let endDate: String?
    public let models: [ModelUsageSummary]

    public init(startDate: String? = nil, endDate: String? = nil, models: [ModelUsageSummary] = []) {
        self.startDate = startDate
        self.endDate = endDate
        self.models = models
    }
}

public struct DashboardSnapshot: Decodable, Equatable, Sendable {
    public let generatedAt: String?
    public let stats: DashboardStats?
    public let trend: [TrendDataPoint]?
    public let modelDistribution: [ModelUsageSummary]?

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case stats
        case trend
        case modelDistribution
        case modelStats
        case modelUsage
        case models
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        stats = try container.decodeIfPresent(DashboardStats.self, forKey: .stats)
        trend = try container.decodeIfPresent([TrendDataPoint].self, forKey: .trend)
        modelDistribution = try container.decodeIfPresent([ModelUsageSummary].self, forKey: .modelDistribution)
            ?? container.decodeIfPresent([ModelUsageSummary].self, forKey: .modelStats)
            ?? container.decodeIfPresent([ModelUsageSummary].self, forKey: .modelUsage)
            ?? container.decodeIfPresent([ModelUsageSummary].self, forKey: .models)
    }
}

public struct PaginatedResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let total: Int
    public let page: Int
    public let pageSize: Int
    public let pages: Int

    public init(items: [Item] = [], total: Int = 0, page: Int = 1, pageSize: Int = 0, pages: Int = 0) {
        self.items = items
        self.total = total
        self.page = page
        self.pageSize = pageSize
        self.pages = pages
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case total
        case page
        case pageSize
        case pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? items.count
        page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? items.count
        pages = try container.decodeIfPresent(Int.self, forKey: .pages) ?? 1
    }
}

public struct UsagePeriodStats: Decodable, Equatable, Sendable {
    public let totalRequests: Int64
    public let totalInputTokens: Int64
    public let totalOutputTokens: Int64
    public let totalCacheCreationTokens: Int64
    public let totalCacheReadTokens: Int64
    public let totalTokens: Int64
    public let totalCost: Double
    public let totalActualCost: Double
    public let averageDurationMs: Double

    public init(
        totalRequests: Int64 = 0,
        totalInputTokens: Int64 = 0,
        totalOutputTokens: Int64 = 0,
        totalCacheCreationTokens: Int64 = 0,
        totalCacheReadTokens: Int64 = 0,
        totalTokens: Int64 = 0,
        totalCost: Double = 0,
        totalActualCost: Double = 0,
        averageDurationMs: Double = 0
    ) {
        self.totalRequests = totalRequests
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalCacheCreationTokens = totalCacheCreationTokens
        self.totalCacheReadTokens = totalCacheReadTokens
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.totalActualCost = totalActualCost
        self.averageDurationMs = averageDurationMs
    }

    private enum CodingKeys: String, CodingKey {
        case totalRequests
        case totalInputTokens
        case totalOutputTokens
        case totalCacheCreationTokens
        case totalCacheReadTokens
        case totalTokens
        case totalCost
        case totalActualCost
        case averageDurationMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalRequests = try container.decodeIfPresent(Int64.self, forKey: .totalRequests) ?? 0
        totalInputTokens = try container.decodeIfPresent(Int64.self, forKey: .totalInputTokens) ?? 0
        totalOutputTokens = try container.decodeIfPresent(Int64.self, forKey: .totalOutputTokens) ?? 0
        totalCacheCreationTokens = try container.decodeIfPresent(Int64.self, forKey: .totalCacheCreationTokens) ?? 0
        totalCacheReadTokens = try container.decodeIfPresent(Int64.self, forKey: .totalCacheReadTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int64.self, forKey: .totalTokens) ?? 0
        totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        totalActualCost = try container.decodeIfPresent(Double.self, forKey: .totalActualCost) ?? 0
        averageDurationMs = try container.decodeIfPresent(Double.self, forKey: .averageDurationMs) ?? 0
    }

}

public extension DashboardStats {
    init(monitoredUsageStats stats: UsagePeriodStats) {
        self.init(
            totalRequests: stats.totalRequests,
            totalTokens: stats.totalTokens,
            totalInputTokens: stats.totalInputTokens,
            totalOutputTokens: stats.totalOutputTokens,
            totalCacheCreationTokens: stats.totalCacheCreationTokens,
            totalCacheReadTokens: stats.totalCacheReadTokens,
            totalCost: stats.totalCost,
            totalActualCost: stats.totalActualCost,
            todayRequests: stats.totalRequests,
            todayTokens: stats.totalTokens,
            todayInputTokens: stats.totalInputTokens,
            todayOutputTokens: stats.totalOutputTokens,
            todayCacheCreationTokens: stats.totalCacheCreationTokens,
            todayCacheReadTokens: stats.totalCacheReadTokens,
            todayCost: stats.totalCost,
            todayActualCost: stats.totalActualCost,
            averageDurationMs: stats.averageDurationMs
        )
    }
}

public struct UsageLog: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int64
    public let userID: Int64?
    public let apiKeyID: Int64?
    public let accountID: Int64?
    public let requestID: String?
    public let model: String
    public let serviceTier: String?
    public let reasoningEffort: String?
    public let inboundEndpoint: String?
    public let upstreamEndpoint: String?
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheCreationTokens: Int64
    public let cacheReadTokens: Int64
    public let inputCost: Double
    public let outputCost: Double
    public let totalCost: Double
    public let actualCost: Double
    public let requestType: String?
    public let stream: Bool?
    public let durationMs: Double
    public let firstTokenMs: Double?
    public let userAgent: String?
    public let billingMode: String?
    public let createdAt: Date?

    public init(
        id: Int64 = 0,
        userID: Int64? = nil,
        apiKeyID: Int64? = nil,
        accountID: Int64? = nil,
        requestID: String? = nil,
        model: String = "",
        serviceTier: String? = nil,
        reasoningEffort: String? = nil,
        inboundEndpoint: String? = nil,
        upstreamEndpoint: String? = nil,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheCreationTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        inputCost: Double = 0,
        outputCost: Double = 0,
        totalCost: Double = 0,
        actualCost: Double = 0,
        requestType: String? = nil,
        stream: Bool? = nil,
        durationMs: Double = 0,
        firstTokenMs: Double? = nil,
        userAgent: String? = nil,
        billingMode: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.apiKeyID = apiKeyID
        self.accountID = accountID
        self.requestID = requestID
        self.model = model
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
        self.inboundEndpoint = inboundEndpoint
        self.upstreamEndpoint = upstreamEndpoint
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.inputCost = inputCost
        self.outputCost = outputCost
        self.totalCost = totalCost
        self.actualCost = actualCost
        self.requestType = requestType
        self.stream = stream
        self.durationMs = durationMs
        self.firstTokenMs = firstTokenMs
        self.userAgent = userAgent
        self.billingMode = billingMode
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "userId"
        case apiKeyID = "apiKeyId"
        case accountID = "accountId"
        case requestID = "requestId"
        case model
        case serviceTier
        case reasoningEffort
        case inboundEndpoint
        case upstreamEndpoint
        case inputTokens
        case outputTokens
        case cacheCreationTokens
        case cacheReadTokens
        case inputCost
        case outputCost
        case totalCost
        case actualCost
        case requestType
        case stream
        case durationMs
        case firstTokenMs
        case userAgent
        case billingMode
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        userID = try container.decodeIfPresent(Int64.self, forKey: .userID)
        apiKeyID = try container.decodeIfPresent(Int64.self, forKey: .apiKeyID)
        accountID = try container.decodeIfPresent(Int64.self, forKey: .accountID)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        inboundEndpoint = try container.decodeIfPresent(String.self, forKey: .inboundEndpoint)
        upstreamEndpoint = try container.decodeIfPresent(String.self, forKey: .upstreamEndpoint)
        inputTokens = try container.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        cacheCreationTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try container.decodeIfPresent(Int64.self, forKey: .cacheReadTokens) ?? 0
        inputCost = try container.decodeIfPresent(Double.self, forKey: .inputCost) ?? 0
        outputCost = try container.decodeIfPresent(Double.self, forKey: .outputCost) ?? 0
        totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost) ?? inputCost + outputCost
        actualCost = try container.decodeIfPresent(Double.self, forKey: .actualCost) ?? 0
        requestType = try container.decodeIfPresent(String.self, forKey: .requestType)
        stream = try container.decodeIfPresent(Bool.self, forKey: .stream)
        durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs) ?? 0
        firstTokenMs = try container.decodeIfPresent(Double.self, forKey: .firstTokenMs)
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        billingMode = try container.decodeIfPresent(String.self, forKey: .billingMode)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    public var contextLengthTokens: Int64 {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }

    public var isFastEnabled: Bool {
        Self.normalizedServiceTier(serviceTier) == "priority"
    }

    public var inputPricePerMillion: Double? {
        Self.pricePerMillion(cost: inputCost, tokens: inputTokens)
    }

    public var outputPricePerMillion: Double? {
        Self.pricePerMillion(cost: outputCost, tokens: outputTokens)
    }

    private static func pricePerMillion(cost: Double, tokens: Int64) -> Double? {
        guard tokens > 0 else {
            return nil
        }
        return cost / Double(tokens) * 1_000_000
    }

    private static func normalizedServiceTier(_ serviceTier: String?) -> String? {
        guard let serviceTier else {
            return nil
        }

        let normalized = serviceTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return nil
        }

        let token = normalized
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        switch token {
        case "fast", "priority", "fast-mode", "fast-mode-2026-02-01":
            return "priority"
        case "default", "standard":
            return "standard"
        case "flex", "auto", "scale":
            return token
        default:
            return normalized
        }
    }
}

public struct AccountSummary: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let platform: String
    public let type: String
    public let status: String
    public let schedulable: Bool
    public let credentials: [String: String]
    public let quotaLimit: Double?
    public let quotaUsed: Double?
    public let quotaDailyLimit: Double?
    public let quotaDailyUsed: Double?
    public let quotaWeeklyLimit: Double?
    public let quotaWeeklyUsed: Double?
    public let errorMessage: String
    public let rateLimitResetAt: String?

    public init(
        id: Int64,
        name: String,
        platform: String,
        type: String,
        status: String,
        schedulable: Bool,
        credentials: [String: String] = [:],
        quotaLimit: Double?,
        quotaUsed: Double?,
        quotaDailyLimit: Double?,
        quotaDailyUsed: Double?,
        quotaWeeklyLimit: Double?,
        quotaWeeklyUsed: Double?,
        errorMessage: String,
        rateLimitResetAt: String?
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.type = type
        self.status = status
        self.schedulable = schedulable
        self.credentials = credentials
        self.quotaLimit = quotaLimit
        self.quotaUsed = quotaUsed
        self.quotaDailyLimit = quotaDailyLimit
        self.quotaDailyUsed = quotaDailyUsed
        self.quotaWeeklyLimit = quotaWeeklyLimit
        self.quotaWeeklyUsed = quotaWeeklyUsed
        self.errorMessage = errorMessage
        self.rateLimitResetAt = rateLimitResetAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case platform
        case type
        case status
        case schedulable
        case credentials
        case quotaLimit
        case quotaUsed
        case quotaDailyLimit
        case quotaDailyUsed
        case quotaWeeklyLimit
        case quotaWeeklyUsed
        case errorMessage
        case rateLimitResetAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Account"
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        schedulable = try container.decodeIfPresent(Bool.self, forKey: .schedulable) ?? (status == "active")
        credentials = (try container.decodeIfPresent(PublicCredentialStrings.self, forKey: .credentials)?.values ?? [:])
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        quotaLimit = try container.decodeIfPresent(Double.self, forKey: .quotaLimit)
        quotaUsed = try container.decodeIfPresent(Double.self, forKey: .quotaUsed)
        quotaDailyLimit = try container.decodeIfPresent(Double.self, forKey: .quotaDailyLimit)
        quotaDailyUsed = try container.decodeIfPresent(Double.self, forKey: .quotaDailyUsed)
        quotaWeeklyLimit = try container.decodeIfPresent(Double.self, forKey: .quotaWeeklyLimit)
        quotaWeeklyUsed = try container.decodeIfPresent(Double.self, forKey: .quotaWeeklyUsed)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
        rateLimitResetAt = try container.decodeIfPresent(String.self, forKey: .rateLimitResetAt)
    }

    public var highestQuotaRatio: Double? {
        [
            ratio(used: quotaUsed, limit: quotaLimit),
            ratio(used: quotaDailyUsed, limit: quotaDailyLimit),
            ratio(used: quotaWeeklyUsed, limit: quotaWeeklyLimit),
        ].compactMap { $0 }.max()
    }

    private func ratio(used: Double?, limit: Double?) -> Double? {
        guard let used, let limit, limit > 0 else {
            return nil
        }
        return used / limit
    }
}

private struct PublicCredentialStrings: Decodable {
    let values: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        values = try container.allKeys.reduce(into: [:]) { result, key in
            let decoded = try container.decode(PublicCredentialStringValue.self, forKey: key)
            if let value = decoded.value {
                result[key.stringValue] = value
            }
        }
    }
}

private struct PublicCredentialStringValue: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(String.self)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

public struct NormalAccountComposition: Equatable, Sendable {
    public let total: Int
    public let typeCounts: [String: Int]
    public let platformCounts: [String: Int]
    public let planCounts: [String: Int]

    public init(total: Int, accounts: [AccountSummary]) {
        self.total = total
        typeCounts = Self.count(accounts.map { Self.typeLabel($0.type) })
        platformCounts = Self.count(accounts.map { Self.platformLabel($0.platform) })
        planCounts = Self.count(accounts.compactMap(Self.planLabel))
    }

    public init(
        total: Int,
        typeCounts: [String: Int],
        platformCounts: [String: Int],
        planCounts: [String: Int]
    ) {
        self.total = total
        self.typeCounts = typeCounts
        self.platformCounts = platformCounts
        self.planCounts = planCounts
    }

    public func typeLine(language: AppLanguage) -> String {
        let ordered = orderedBreakdown(typeCounts, preferredOrder: ["API", "OAuth", "Setup", "Upstream", "Bedrock", "Service"])
        return joined(ordered, emptyText: language == .en ? "No active accounts" : "无正常账号")
    }

    public func detailLine(language: AppLanguage) -> String {
        let planLine = joined(
            orderedBreakdown(planCounts, preferredOrder: ["Pro", "Plus", "Team", "Free", "Ultra"]),
            emptyText: ""
        )
        if !planLine.isEmpty {
            return planLine
        }
        let platformLine = joined(
            orderedBreakdown(platformCounts, preferredOrder: ["OpenAI", "Anthropic", "Gemini", "Antigravity"]),
            emptyText: ""
        )
        if !platformLine.isEmpty {
            return platformLine
        }
        return language == .en ? "Composition unavailable" : "组成待同步"
    }

    public func compactLine(language: AppLanguage) -> String {
        let typeLine = joined(
            orderedBreakdown(typeCounts, preferredOrder: ["API", "OAuth", "Setup", "Upstream", "Bedrock", "Service"]),
            emptyText: ""
        )
        let planLine = joined(
            orderedBreakdown(planCounts, preferredOrder: ["Pro", "Plus", "Team", "Free", "Ultra"]),
            emptyText: ""
        )
        let platformLine = joined(
            orderedBreakdown(platformCounts, preferredOrder: ["OpenAI", "Anthropic", "Gemini", "Antigravity"]),
            emptyText: ""
        )
        let secondaryLine = planLine.isEmpty ? platformLine : planLine
        let parts = [typeLine, secondaryLine].filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return language == .en ? "No active accounts" : "无正常账号"
        }
        return parts.joined(separator: " · ")
    }

    private static func count(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { result, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return
            }
            result[trimmed, default: 0] += 1
        }
    }

    private static func typeLabel(_ raw: String) -> String {
        switch normalizedToken(raw) {
        case "apikey", "api-key", "api_key":
            return "API"
        case "oauth":
            return "OAuth"
        case "setup-token", "setup_token":
            return "Setup"
        case "upstream":
            return "Upstream"
        case "bedrock":
            return "Bedrock"
        case "service-account", "service_account":
            return "Service"
        default:
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func platformLabel(_ raw: String) -> String {
        switch normalizedToken(raw) {
        case "openai":
            return "OpenAI"
        case "anthropic", "claude":
            return "Anthropic"
        case "gemini":
            return "Gemini"
        case "antigravity":
            return "Antigravity"
        default:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ""
            }
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
    }

    private static func planLabel(_ account: AccountSummary) -> String? {
        guard normalizedToken(account.type) == "oauth" else {
            return nil
        }
        if let plan = nonEmptyCredential(account, "plan_type", "planType") {
            return visiblePlanLabel(plan)
        }
        if let tier = nonEmptyCredential(account, "tier_id", "tierId") {
            return visiblePlanLabel(tier)
        }
        return nil
    }

    private static func nonEmptyCredential(_ account: AccountSummary, _ keys: String...) -> String? {
        for key in keys {
            if let value = account.credentials[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func visiblePlanLabel(_ raw: String) -> String {
        let token = normalizedToken(raw)
        switch token {
        case "pro", "chatgpt-pro", "google-ai-pro", "google_ai_pro", "g1-pro-tier":
            return "Pro"
        case "plus", "chatgpt-plus":
            return "Plus"
        case "team", "chatgpt-team":
            return "Team"
        case "free", "chatgpt-free", "google-one-free", "google_one_free", "aistudio-free", "aistudio_free", "free-tier":
            return "Free"
        case "ultra", "google-ai-ultra", "google_ai_ultra", "g1-ultra-tier":
            return "Ultra"
        default:
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return ""
            }
            return trimmed
        }
    }

    private static func normalizedToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private func orderedBreakdown(_ counts: [String: Int], preferredOrder: [String]) -> [(String, Int)] {
        let preferred = preferredOrder.compactMap { label -> (String, Int)? in
            guard let count = counts[label], count > 0 else {
                return nil
            }
            return (label, count)
        }
        let preferredSet = Set(preferredOrder)
        let rest = counts
            .filter { !preferredSet.contains($0.key) && $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
        return preferred + rest
    }

    private func joined(_ items: [(String, Int)], emptyText: String) -> String {
        guard !items.isEmpty else {
            return emptyText
        }
        return items.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}

public struct AccountHealthSummary: Equatable, Sendable {
    public let total: Int
    public let active: Int
    public let schedulable: Int
    public let blocked: Int
    public let nearQuotaLimit: Int

    public init(accounts: [AccountSummary]) {
        total = accounts.count
        active = accounts.filter { $0.status == "active" }.count
        schedulable = accounts.filter(\.schedulable).count
        blocked = accounts.filter { !$0.schedulable || $0.status != "active" || !$0.errorMessage.isEmpty }.count
        nearQuotaLimit = accounts.filter { ($0.highestQuotaRatio ?? 0) >= 0.9 }.count
    }
}

public struct SubscriptionSummary: Decodable, Equatable, Sendable {
    public let activeCount: Int
    public let totalUsedUSD: Double
    public let subscriptions: [SubscriptionSummaryItem]

    public init(activeCount: Int, totalUsedUSD: Double = 0, subscriptions: [SubscriptionSummaryItem]) {
        self.activeCount = activeCount
        self.totalUsedUSD = totalUsedUSD
        self.subscriptions = subscriptions
    }

    private enum CodingKeys: String, CodingKey {
        case activeCount
        case totalUsedUSD = "totalUsedUsd"
        case subscriptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try container.decodeIfPresent([SubscriptionSummaryItem].self, forKey: .subscriptions) ?? []
        activeCount = try container.decodeIfPresent(Int.self, forKey: .activeCount) ?? subscriptions.filter { $0.status == "active" }.count
        totalUsedUSD = try container.decodeIfPresent(Double.self, forKey: .totalUsedUSD) ?? 0
    }

    public var highestProgress: Double {
        subscriptions.flatMap { [$0.dailyProgress, $0.weeklyProgress, $0.monthlyProgress] }
            .compactMap { $0 }
            .max() ?? 0
    }

    public var expiringSoonCount: Int {
        subscriptions.filter { item in
            guard let days = item.daysRemaining else {
                return false
            }
            return days <= 3
        }.count
    }

    public init(adminSubscriptions: [AdminUserSubscription], referenceDate: Date = Date()) {
        let items = adminSubscriptions.map { SubscriptionSummaryItem(adminSubscription: $0, referenceDate: referenceDate) }
        self.init(
            activeCount: items.filter { $0.status == "active" }.count,
            totalUsedUSD: items.reduce(0) { $0 + ($1.monthlyUsedUSD ?? $1.weeklyUsedUSD ?? $1.dailyUsedUSD ?? 0) },
            subscriptions: items
        )
    }
}

public struct SubscriptionSummaryItem: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int64
    public let groupName: String
    public let status: String
    public let dailyUsedUSD: Double?
    public let dailyLimitUSD: Double?
    public let weeklyUsedUSD: Double?
    public let weeklyLimitUSD: Double?
    public let monthlyUsedUSD: Double?
    public let monthlyLimitUSD: Double?
    public let dailyResetInSeconds: Double?
    public let weeklyResetInSeconds: Double?
    public let monthlyResetInSeconds: Double?
    public let dailyProgress: Double?
    public let weeklyProgress: Double?
    public let monthlyProgress: Double?
    public let expiresAt: String?
    public let daysRemaining: Int?

    public init(
        id: Int64,
        groupName: String,
        status: String,
        dailyUsedUSD: Double? = nil,
        dailyLimitUSD: Double? = nil,
        weeklyUsedUSD: Double? = nil,
        weeklyLimitUSD: Double? = nil,
        monthlyUsedUSD: Double? = nil,
        monthlyLimitUSD: Double? = nil,
        dailyResetInSeconds: Double? = nil,
        weeklyResetInSeconds: Double? = nil,
        monthlyResetInSeconds: Double? = nil,
        dailyProgress: Double?,
        weeklyProgress: Double?,
        monthlyProgress: Double?,
        expiresAt: String?,
        daysRemaining: Int?
    ) {
        self.id = id
        self.groupName = groupName
        self.status = status
        self.dailyUsedUSD = dailyUsedUSD
        self.dailyLimitUSD = dailyLimitUSD
        self.weeklyUsedUSD = weeklyUsedUSD
        self.weeklyLimitUSD = weeklyLimitUSD
        self.monthlyUsedUSD = monthlyUsedUSD
        self.monthlyLimitUSD = monthlyLimitUSD
        self.dailyResetInSeconds = dailyResetInSeconds
        self.weeklyResetInSeconds = weeklyResetInSeconds
        self.monthlyResetInSeconds = monthlyResetInSeconds
        self.dailyProgress = dailyProgress
        self.weeklyProgress = weeklyProgress
        self.monthlyProgress = monthlyProgress
        self.expiresAt = expiresAt
        self.daysRemaining = daysRemaining
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case groupName
        case status
        case dailyUsedUSD = "dailyUsedUsd"
        case dailyLimitUSD = "dailyLimitUsd"
        case weeklyUsedUSD = "weeklyUsedUsd"
        case weeklyLimitUSD = "weeklyLimitUsd"
        case monthlyUsedUSD = "monthlyUsedUsd"
        case monthlyLimitUSD = "monthlyLimitUsd"
        case dailyResetInSeconds
        case weeklyResetInSeconds
        case monthlyResetInSeconds
        case dailyProgress
        case weeklyProgress
        case monthlyProgress
        case expiresAt
        case daysRemaining
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName) ?? "Subscription"
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        dailyUsedUSD = try container.decodeIfPresent(Double.self, forKey: .dailyUsedUSD)
        dailyLimitUSD = try container.decodeIfPresent(Double.self, forKey: .dailyLimitUSD)
        weeklyUsedUSD = try container.decodeIfPresent(Double.self, forKey: .weeklyUsedUSD)
        weeklyLimitUSD = try container.decodeIfPresent(Double.self, forKey: .weeklyLimitUSD)
        monthlyUsedUSD = try container.decodeIfPresent(Double.self, forKey: .monthlyUsedUSD)
        monthlyLimitUSD = try container.decodeIfPresent(Double.self, forKey: .monthlyLimitUSD)
        dailyResetInSeconds = try container.decodeIfPresent(Double.self, forKey: .dailyResetInSeconds)
        weeklyResetInSeconds = try container.decodeIfPresent(Double.self, forKey: .weeklyResetInSeconds)
        monthlyResetInSeconds = try container.decodeIfPresent(Double.self, forKey: .monthlyResetInSeconds)
        dailyProgress = try container.decodeIfPresent(Double.self, forKey: .dailyProgress)
            ?? Self.ratio(used: dailyUsedUSD, limit: dailyLimitUSD)
        weeklyProgress = try container.decodeIfPresent(Double.self, forKey: .weeklyProgress)
            ?? Self.ratio(used: weeklyUsedUSD, limit: weeklyLimitUSD)
        monthlyProgress = try container.decodeIfPresent(Double.self, forKey: .monthlyProgress)
            ?? Self.ratio(used: monthlyUsedUSD, limit: monthlyLimitUSD)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        daysRemaining = try container.decodeIfPresent(Int.self, forKey: .daysRemaining)
    }

    private static func ratio(used: Double?, limit: Double?) -> Double? {
        guard let used, let limit, limit > 0 else {
            return nil
        }
        return used / limit
    }

    public init(adminSubscription: AdminUserSubscription, referenceDate: Date = Date()) {
        let dailyLimit = adminSubscription.group?.dailyLimitUSD
        let weeklyLimit = adminSubscription.group?.weeklyLimitUSD
        let monthlyLimit = adminSubscription.group?.monthlyLimitUSD
        self.init(
            id: adminSubscription.id,
            groupName: adminSubscription.group?.name ?? "Subscription",
            status: adminSubscription.status,
            dailyUsedUSD: adminSubscription.dailyUsageUSD,
            dailyLimitUSD: dailyLimit,
            weeklyUsedUSD: adminSubscription.weeklyUsageUSD,
            weeklyLimitUSD: weeklyLimit,
            monthlyUsedUSD: adminSubscription.monthlyUsageUSD,
            monthlyLimitUSD: monthlyLimit,
            dailyResetInSeconds: nil,
            weeklyResetInSeconds: nil,
            monthlyResetInSeconds: nil,
            dailyProgress: Self.ratio(used: adminSubscription.dailyUsageUSD, limit: dailyLimit),
            weeklyProgress: Self.ratio(used: adminSubscription.weeklyUsageUSD, limit: weeklyLimit),
            monthlyProgress: Self.ratio(used: adminSubscription.monthlyUsageUSD, limit: monthlyLimit),
            expiresAt: adminSubscription.expiresAt,
            daysRemaining: Self.daysRemaining(until: adminSubscription.expiresAt, referenceDate: referenceDate)
        )
    }

    private static func daysRemaining(until rawDate: String?, referenceDate: Date) -> Int? {
        guard let rawDate else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        guard let date = fractional.date(from: rawDate) ?? standard.date(from: rawDate) else {
            return nil
        }
        let seconds = date.timeIntervalSince(referenceDate)
        guard seconds > 0 else {
            return 0
        }
        return Int(seconds / 86_400)
    }
}

public struct UsageProgress: Decodable, Equatable, Sendable {
    public let used: Double?
    public let limit: Double?
    public let percentage: Double?
    public let utilization: Double?
    public let resetsAt: String?
    public let resetInSeconds: Double?

    public var normalizedPercentage: Double {
        if let percentage {
            return percentage > 1 ? percentage / 100 : percentage
        }
        if let utilization {
            return utilization > 1 ? utilization / 100 : utilization
        }
        guard let used, let limit, limit > 0 else {
            return 0
        }
        return used / limit
    }
}

public struct AccountUsageInfo: Decodable, Equatable, Sendable {
    public let source: String?
    public let updatedAt: String?
    public let fiveHour: UsageProgress?
    public let sevenDay: UsageProgress?
    public let sevenDaySonnet: UsageProgress?
    public let error: String?
    public let errorCode: String?
    public let needsReauth: Bool?
    public let needsVerify: Bool?
    public let isBanned: Bool?
}

public enum MonitorSeverity: String, Equatable, Sendable {
    case healthy
    case warning
    case error
}

public struct MenuBarStatusPresentation: Equatable, Sendable {
    public let title: String
    public let cells: [MenuBarStatusCell]
    public let topRow: String
    public let bottomRow: String
    public let hidesHealthyStatusImage: Bool

    public init(
        title: String,
        cells: [MenuBarStatusCell] = [],
        topRow: String = "",
        bottomRow: String = "",
        hidesHealthyStatusImage: Bool
    ) {
        self.title = title
        self.cells = cells
        self.topRow = topRow
        self.bottomRow = bottomRow
        self.hidesHealthyStatusImage = hidesHealthyStatusImage
    }
}

public struct MenuBarStatusCell: Equatable, Sendable {
    public let value: String
    public let label: String
    public let width: Double
    public let valueTone: MenuBarStatusCellTone

    public init(value: String, label: String, width: Double = 48, valueTone: MenuBarStatusCellTone = .primary) {
        self.value = value
        self.label = label
        self.width = width
        self.valueTone = valueTone
    }
}

public enum MenuBarStatusCellTone: String, Equatable, Sendable {
    case primary
    case secondary
}

public struct MonitorSnapshot: Equatable, Sendable {
    public let mode: MonitorMode
    public let connected: Bool
    public let currentUser: CurrentUser?
    public let stats: DashboardStats?
    public let menuBarUsageStats: UsagePeriodStats?
    public let latestUsage: UsageLog?
    public let trend: [TrendDataPoint]?
    public let modelDistribution: [ModelUsageSummary]?
    public let realtime: RealtimeMetrics?
    public let monitoredUser: AdminUserSummary?
    public let realtimeConcurrency: UserRealtimeConcurrency?
    public let adminNormalAccountCount: Int?
    public let adminNormalAccountComposition: NormalAccountComposition?
    public let accountHealth: AccountHealthSummary?
    public let subscriptionSummary: SubscriptionSummary?
    public let codexTaskActivities: [CodexTaskActivity]
    public let lastUpdatedAt: Date?
    public let message: String?
    public let isStale: Bool

    public init(
        mode: MonitorMode,
        connected: Bool,
        currentUser: CurrentUser? = nil,
        stats: DashboardStats?,
        menuBarUsageStats: UsagePeriodStats? = nil,
        latestUsage: UsageLog? = nil,
        trend: [TrendDataPoint]? = nil,
        modelDistribution: [ModelUsageSummary]? = nil,
        realtime: RealtimeMetrics?,
        monitoredUser: AdminUserSummary? = nil,
        realtimeConcurrency: UserRealtimeConcurrency? = nil,
        adminNormalAccountCount: Int? = nil,
        adminNormalAccountComposition: NormalAccountComposition? = nil,
        accountHealth: AccountHealthSummary?,
        subscriptionSummary: SubscriptionSummary?,
        codexTaskActivities: [CodexTaskActivity] = [],
        lastUpdatedAt: Date?,
        message: String?,
        isStale: Bool = false
    ) {
        self.mode = mode
        self.connected = connected
        self.currentUser = currentUser
        self.stats = stats
        self.menuBarUsageStats = menuBarUsageStats
        self.latestUsage = latestUsage
        self.trend = trend
        self.modelDistribution = modelDistribution
        self.realtime = realtime
        self.monitoredUser = monitoredUser
        self.realtimeConcurrency = realtimeConcurrency
        self.adminNormalAccountCount = adminNormalAccountCount
        self.adminNormalAccountComposition = adminNormalAccountComposition
        self.accountHealth = accountHealth
        self.subscriptionSummary = subscriptionSummary
        self.codexTaskActivities = codexTaskActivities
        self.lastUpdatedAt = lastUpdatedAt
        self.message = message
        self.isStale = isStale
    }

    public static func idle(mode: MonitorMode) -> MonitorSnapshot {
        MonitorSnapshot(
            mode: mode,
            connected: false,
            stats: nil,
            realtime: nil,
            monitoredUser: nil,
            realtimeConcurrency: nil,
            accountHealth: nil,
            subscriptionSummary: nil,
            lastUpdatedAt: nil,
            message: "Not connected"
        )
    }

    public func retainingDataAfterRefreshFailure(_ message: String) -> MonitorSnapshot {
        MonitorSnapshot(
            mode: mode,
            connected: connected,
            currentUser: currentUser,
            stats: stats,
            menuBarUsageStats: menuBarUsageStats,
            latestUsage: latestUsage,
            trend: trend,
            modelDistribution: modelDistribution,
            realtime: realtime,
            monitoredUser: monitoredUser,
            realtimeConcurrency: realtimeConcurrency,
            adminNormalAccountCount: adminNormalAccountCount,
            adminNormalAccountComposition: adminNormalAccountComposition,
            accountHealth: accountHealth,
            subscriptionSummary: subscriptionSummary,
            codexTaskActivities: codexTaskActivities,
            lastUpdatedAt: lastUpdatedAt,
            message: message,
            isStale: true
        )
    }

    public func withCodexTaskActivities(_ activities: [CodexTaskActivity]) -> MonitorSnapshot {
        MonitorSnapshot(
            mode: mode,
            connected: connected,
            currentUser: currentUser,
            stats: stats,
            menuBarUsageStats: menuBarUsageStats,
            latestUsage: latestUsage,
            trend: trend,
            modelDistribution: modelDistribution,
            realtime: realtime,
            monitoredUser: monitoredUser,
            realtimeConcurrency: realtimeConcurrency,
            adminNormalAccountCount: adminNormalAccountCount,
            adminNormalAccountComposition: adminNormalAccountComposition,
            accountHealth: accountHealth,
            subscriptionSummary: subscriptionSummary,
            codexTaskActivities: activities,
            lastUpdatedAt: lastUpdatedAt,
            message: message,
            isStale: isStale
        )
    }

    public var severity: MonitorSeverity {
        if !connected {
            return .error
        }

        if isStale {
            return .warning
        }

        if (realtime?.errorRate ?? 0) >= 0.1 {
            return .error
        }

        if let accountHealth, accountHealth.total > 0 {
            let blockedRatio = Double(accountHealth.blocked) / Double(accountHealth.total)
            if blockedRatio >= 0.5 {
                return .error
            }
            if accountHealth.nearQuotaLimit > 0 || blockedRatio > 0 {
                return .warning
            }
        }

        if let subscriptionSummary {
            if subscriptionSummary.highestProgress >= 0.95 {
                return .error
            }
            if subscriptionSummary.highestProgress >= 0.8 || subscriptionSummary.expiringSoonCount > 0 {
                return .warning
            }
        }

        return .healthy
    }

    public var statusLabel: String {
        if !connected {
            return "Disconnected"
        }

        if isStale {
            return "Refresh Failed"
        }

        if let subscriptionSummary {
            if subscriptionSummary.highestProgress >= 0.95 {
                return "Near Limit"
            }
            if subscriptionSummary.highestProgress >= 0.8 {
                return "High Usage"
            }
            if subscriptionSummary.expiringSoonCount > 0 {
                return "Expiring Soon"
            }
        }

        switch severity {
        case .healthy:
            return "OK"
        case .warning:
            return "Warn"
        case .error:
            return "Error"
        }
    }

    public func menuBarValueLabelRows(config: AppConfig) -> (top: String, bottom: String) {
        let cells = menuBarCells(config: config, compact: true)
        return (
            top: cells.map(\.value).joined(separator: " | "),
            bottom: cells.map(\.label).joined(separator: " | ")
        )
    }

    public func menuBarStatusPresentation(config: AppConfig) -> MenuBarStatusPresentation {
        guard config.showsMenuBarText else {
            return MenuBarStatusPresentation(title: "", hidesHealthyStatusImage: false)
        }

        let cells = menuBarCells(config: config, compact: true)
        guard !cells.isEmpty else {
            return MenuBarStatusPresentation(title: "", hidesHealthyStatusImage: false)
        }
        let rows = valueLabelRows(cells: cells)

        return MenuBarStatusPresentation(
            title: " \(rows.top)",
            cells: cells,
            topRow: rows.top,
            bottomRow: rows.bottom,
            hidesHealthyStatusImage: true
        )
    }

    public func menuBarTooltip(statusText: String, config: AppConfig) -> String {
        let title = "Sub2API \(statusText)"

        let rows = menuBarValueLabelRows(config: config)
        guard !rows.top.isEmpty else {
            return title
        }

        return "\(title)\n\(rows.top)\n\(rows.bottom)"
    }

    private static func compactReasoningEffort(_ effort: String) -> String {
        switch normalizedReasoningEffort(effort) {
        case "", "none", "minimal":
            return "no"
        case "low":
            return "lo"
        case "medium":
            return "med"
        case "high":
            return "hi"
        case "xhigh":
            return "xh"
        default:
            return effort
        }
    }

    private static func menuBarModelName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("gpt-") {
            return "GPT-" + trimmed.dropFirst(4)
        }
        return trimmed
    }

    private static func menuBarReasoningEffort(_ effort: String?) -> String {
        guard let effort = nonEmpty(effort) else {
            return "no"
        }
        return effort
    }

    private static func normalizedReasoningEffort(_ effort: String) -> String {
        effort
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private func menuBarCells(config: AppConfig, compact: Bool) -> [MenuBarStatusCell] {
        guard !config.menuBarDisplayItems.isEmpty else {
            return []
        }

        let selectedItems = Set(CapabilityPolicy(isAdminAccount: mode == .admin).visibleMenuBarDisplayItems)
            .intersection(config.menuBarDisplayItems)
        let orderedItems = MenuBarDisplayItem.allCases.filter { selectedItems.contains($0) }
        return orderedItems.map { item in
            menuBarCell(for: item, config: config, compact: compact)
        }
    }

    private func menuBarCell(for item: MenuBarDisplayItem, config: AppConfig, compact: Bool) -> MenuBarStatusCell {
        if item == .codexTasks {
            let taskSummary = CodexMenuBarTaskSummary.make(activities: codexTaskActivities, maxTasks: compact ? 2 : 3)
            return MenuBarStatusCell(
                value: taskSummary.topRow,
                label: taskSummary.bottomRow,
                width: menuBarCellWidth(for: item),
                valueTone: taskSummary.topRow == "0" ? .secondary : .primary
            )
        }
        let value = menuBarCellValue(for: item, config: config, compact: compact)
        return MenuBarStatusCell(
            value: value,
            label: menuBarCellLabel(for: item),
            width: menuBarCellWidth(for: item),
            valueTone: menuBarCellValueTone(for: item, value: value)
        )
    }

    private func menuBarCellValue(for item: MenuBarDisplayItem, config: AppConfig, compact: Bool) -> String {
        switch item {
        case .totalCost:
            guard let cost = selectedTotalActualCost(config: config) else {
                return "$0.00"
            }
            return compact ? StatusFormatters.menuBarCurrency(cost) : StatusFormatters.currency(cost)
        case .totalRequests:
            guard let requests = selectedTotalRequests(config: config) else {
                return "0"
            }
            return compact ? "\(StatusFormatters.menuBarCount(requests))r" : "\(StatusFormatters.menuBarCount(requests)) req"
        case .model:
            guard let model = Self.nonEmpty(latestUsage?.model) else {
                return "No model"
            }
            return compact ? Self.menuBarModelName(model) : model
        case .reasoningEffort:
            let effort = Self.menuBarReasoningEffort(latestUsage?.reasoningEffort)
            return compact ? Self.compactReasoningEffort(effort) : effort
        case .contextLength:
            guard let latestUsage else {
                return "0c"
            }
            let context = StatusFormatters.contextLength(latestUsage.contextLengthTokens)
            return compact ? context.replacingOccurrences(of: " ctx", with: "c") : context
        case .fast:
            return latestUsage?.isFastEnabled == true ? "T" : "F"
        case .inputPrice:
            guard let price = latestUsage?.inputPricePerMillion else {
                return "i$0/M"
            }
            return compact ? "i\(StatusFormatters.menuBarTokenPricePerMillion(price))/M" : "in \(StatusFormatters.tokenPricePerMillion(price))/1M"
        case .outputPrice:
            guard let price = latestUsage?.outputPricePerMillion else {
                return "o$0/M"
            }
            return compact ? "o\(StatusFormatters.menuBarTokenPricePerMillion(price))/M" : "out \(StatusFormatters.tokenPricePerMillion(price))/1M"
        case .rpm:
            let rpm = mode == .admin ? nil : stats?.rpm ?? realtime?.requestsPerMinute
            guard let rpm else {
                return "0rpm"
            }
            return compact ? "\(StatusFormatters.menuBarRate(rpm))rpm" : "\(StatusFormatters.menuBarRate(rpm)) RPM"
        case .realtimeConcurrency:
            guard let concurrency = realtimeConcurrency else {
                return compact ? "0C" : "0 concurrent"
            }
            let current = StatusFormatters.menuBarCount(concurrency.currentInUse)
            return compact ? "\(current)C" : "\(current) concurrent"
        case .normalAccounts:
            guard let normalAccounts = adminNormalAccountCount else {
                return "0N"
            }
            return compact ? "\(StatusFormatters.menuBarCount(Int64(normalAccounts)))N" : "\(StatusFormatters.menuBarCount(Int64(normalAccounts))) normal"
        case .codexTasks:
            return CodexMenuBarTaskSummary.make(activities: codexTaskActivities, maxTasks: compact ? 2 : 3).topRow
        }
    }

    private func menuBarCellWidth(for item: MenuBarDisplayItem) -> Double {
        switch item {
        case .totalCost:
            return 58
        case .totalRequests:
            return 36
        case .model:
            return 56
        case .reasoningEffort:
            return 26
        case .contextLength:
            return 40
        case .fast:
            return 24
        case .inputPrice, .outputPrice:
            return 40
        case .rpm:
            return 36
        case .realtimeConcurrency:
            return 36
        case .normalAccounts:
            return 36
        case .codexTasks:
            return 88
        }
    }

    private func menuBarCellValueTone(for item: MenuBarDisplayItem, value: String) -> MenuBarStatusCellTone {
        switch item {
        case .model where value == "No model":
            return .secondary
        case .realtimeConcurrency where value == "0C" || value == "0 concurrent":
            return .secondary
        default:
            return .primary
        }
    }

    private func valueLabelRows(cells: [MenuBarStatusCell]) -> (top: String, bottom: String) {
        (
            top: cells.map(\.value).joined(separator: " | "),
            bottom: cells.map(\.label).joined(separator: " | ")
        )
    }

    private func menuBarCellLabel(for item: MenuBarDisplayItem) -> String {
        switch item {
        case .totalCost:
            return "Cost"
        case .totalRequests:
            return "Req"
        case .model:
            return "Model"
        case .reasoningEffort:
            return "Eff"
        case .contextLength:
            return "Ctx"
        case .fast:
            return "Fast"
        case .inputPrice:
            return "In"
        case .outputPrice:
            return "Out"
        case .rpm:
            return "RPM"
        case .realtimeConcurrency:
            return "Conc"
        case .normalAccounts:
            return "Acct"
        case .codexTasks:
            return "Task"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func selectedTotalActualCost(config: AppConfig) -> Double? {
        if let menuBarUsageStats {
            return menuBarUsageStats.totalActualCost
        }
        guard let stats else {
            return nil
        }
        switch config.menuBarUsageWindow {
        case .last24Hours:
            return nil
        case .today:
            return stats.todayActualCost
        }
    }

    private func selectedTotalRequests(config: AppConfig) -> Int64? {
        if let menuBarUsageStats {
            return menuBarUsageStats.totalRequests
        }
        guard let stats else {
            return nil
        }
        switch config.menuBarUsageWindow {
        case .last24Hours:
            return nil
        case .today:
            return stats.todayRequests
        }
    }
}
