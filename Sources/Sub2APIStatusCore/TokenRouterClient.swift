import Foundation

public struct TokenRouterClient: Sendable {
    public var config: AppConfig
    public var session: URLSession
    public var retryPolicy: HTTPRetryPolicy

    public init(config: AppConfig, session: URLSession = .shared, retryPolicy: HTTPRetryPolicy = .default) {
        self.config = config
        self.session = session
        self.retryPolicy = retryPolicy
    }

    public func login(email: String, password: String) async throws -> AuthResponse {
        try await post("/auth/login", body: LoginRequest(email: email, password: password))
    }

    public func currentUser() async throws -> CurrentUserResponse {
        try await get("/auth/me")
    }

    public func usageDashboardStats() async throws -> DashboardStats {
        try await get("/usage/dashboard/stats")
    }

    public func usageStats(startDate: String, endDate: String, timezone: String? = nil) async throws -> UsagePeriodStats {
        var query = [
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
        ]
        if let timezone, !timezone.isEmpty {
            query.append(URLQueryItem(name: "timezone", value: timezone))
        }
        return try await get("/usage/stats", query: query)
    }

    public func usageLogs(
        page: Int = 1,
        pageSize: Int = 20,
        sortBy: String = "created_at",
        sortOrder: String = "desc",
        startDate: String? = nil,
        endDate: String? = nil,
        timezone: String? = nil
    ) async throws -> PaginatedResponse<UsageLog> {
        var query = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "sort_order", value: sortOrder),
        ]
        if let startDate, !startDate.isEmpty {
            query.append(URLQueryItem(name: "start_date", value: startDate))
        }
        if let endDate, !endDate.isEmpty {
            query.append(URLQueryItem(name: "end_date", value: endDate))
        }
        if let timezone, !timezone.isEmpty {
            query.append(URLQueryItem(name: "timezone", value: timezone))
        }
        return try await get("/usage", query: query)
    }

    public func usageDashboardSnapshot(
        startDate: String,
        endDate: String,
        granularity: String = "day"
    ) async throws -> TokenRouterDashboardSnapshot {
        try await get("/usage/dashboard/snapshot-v2", query: [
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "granularity", value: granularity),
            URLQueryItem(name: "include_trend", value: "true"),
            URLQueryItem(name: "include_model_stats", value: "true"),
            URLQueryItem(name: "include_group_stats", value: "false"),
        ])
    }

    public func subscriptionSummary() async throws -> SubscriptionSummary {
        try await get("/subscriptions/summary")
    }

    public func adminUsers(page: Int = 1, pageSize: Int = 100, search: String? = nil) async throws -> AdminUsersPage {
        var query = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
        ]
        if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.append(URLQueryItem(name: "search", value: search))
        }
        return try await get("/admin/users", query: query)
    }

    public func adminUser(id: Int64) async throws -> AdminUserSummary {
        try await get("/admin/users/\(id)")
    }

    public func allAdminUsers(pageSize: Int = 1000) async throws -> [AdminUserSummary] {
        var page = 1
        var users: [AdminUserSummary] = []

        while true {
            let response = try await adminUsers(page: page, pageSize: pageSize)
            users.append(contentsOf: response.items)
            guard page < response.pages, !response.items.isEmpty else {
                return users
            }
            page += 1
        }
    }

    public func adminUserConcurrencyStats() async throws -> AdminUserConcurrencyStats {
        try await get("/admin/ops/user-concurrency")
    }

    public func adminNormalAccountComposition(pageSize: Int = 1000) async throws -> NormalAccountComposition {
        let accounts = try await adminAccounts(pageSize: pageSize, status: "active")
            .filter { $0.parentAccountID == nil }
        return NormalAccountComposition(accounts: accounts)
    }

    public func adminOpenAIOAuthAccountQuotas(pageSize: Int = 1000) async throws -> [OpenAIAccountQuota] {
        let accounts = try await adminAccounts(
            pageSize: pageSize,
            platform: "openai",
            type: "oauth"
        ).filter(\.isOpenAIOAuthAccount)

        var quotas: [OpenAIAccountQuota] = []
        for account in accounts {
            let usage: AccountUsageInfo = try await get("/admin/accounts/\(account.id)/usage")
            quotas.append(OpenAIAccountQuota(account: account, usage: usage))
        }
        return quotas
    }

    public func adminUsageStats(
        userID: Int64,
        startDate: String,
        endDate: String,
        timezone: String? = nil
    ) async throws -> UsagePeriodStats {
        var query = [
            URLQueryItem(name: "user_id", value: String(userID)),
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
        ]
        if let timezone, !timezone.isEmpty {
            query.append(URLQueryItem(name: "timezone", value: timezone))
        }
        return try await get("/admin/usage/stats", query: query)
    }

    public func adminUsageLogs(
        userID: Int64,
        page: Int = 1,
        pageSize: Int = 20,
        sortBy: String = "created_at",
        sortOrder: String = "desc",
        startDate: String? = nil,
        endDate: String? = nil,
        timezone: String? = nil
    ) async throws -> PaginatedResponse<UsageLog> {
        var query = [
            URLQueryItem(name: "user_id", value: String(userID)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "sort_order", value: sortOrder),
        ]
        if let startDate, !startDate.isEmpty {
            query.append(URLQueryItem(name: "start_date", value: startDate))
        }
        if let endDate, !endDate.isEmpty {
            query.append(URLQueryItem(name: "end_date", value: endDate))
        }
        if let timezone, !timezone.isEmpty {
            query.append(URLQueryItem(name: "timezone", value: timezone))
        }
        return try await get("/admin/usage", query: query)
    }

    public func adminDashboardSnapshot(
        userID: Int64,
        startDate: String,
        endDate: String,
        granularity: String = "day",
        timezone: String? = nil
    ) async throws -> TokenRouterDashboardSnapshot {
        var query = [
            URLQueryItem(name: "user_id", value: String(userID)),
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "granularity", value: granularity),
            URLQueryItem(name: "include_stats", value: "false"),
            URLQueryItem(name: "include_trend", value: "false"),
            URLQueryItem(name: "include_model_stats", value: "true"),
            URLQueryItem(name: "include_group_stats", value: "false"),
        ]
        if let timezone, !timezone.isEmpty {
            query.append(URLQueryItem(name: "timezone", value: timezone))
        }
        return try await get("/admin/dashboard/snapshot-v2", query: query)
    }

    public func adminUserSubscriptions(userID: Int64) async throws -> [AdminUserSubscription] {
        try await get("/admin/users/\(userID)/subscriptions")
    }

    public func refreshToken(_ refreshToken: String) async throws -> AuthResponse {
        struct RefreshRequest: Encodable, Sendable {
            let refreshToken: String
        }
        return try await post("/auth/refresh", body: RefreshRequest(refreshToken: refreshToken))
    }

    private func adminAccounts(
        pageSize: Int,
        platform: String? = nil,
        type: String? = nil,
        status: String? = nil
    ) async throws -> [AccountSummary] {
        var page = 1
        var accounts: [AccountSummary] = []
        while true {
            var query = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize)),
            ]
            if let platform {
                query.append(URLQueryItem(name: "platform", value: platform))
            }
            if let type {
                query.append(URLQueryItem(name: "type", value: type))
            }
            if let status {
                query.append(URLQueryItem(name: "status", value: status))
            }
            query.append(URLQueryItem(name: "lite", value: "true"))

            let response: AdminAccountsPage = try await get("/admin/accounts", query: query)
            accounts.append(contentsOf: response.items)
            guard page < response.pages, !response.items.isEmpty else {
                return accounts
            }
            page += 1
        }
    }

    public func get<Value: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        var request = try makeRequest(path: path, query: query)
        request.httpMethod = "GET"
        return try await send(request, allowsRetry: true)
    }

    public func post<Body: Encodable & Sendable, Value: Decodable & Sendable>(_ path: String, body: Body) async throws -> Value {
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder.tokenRouter.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, allowsRetry: false)
    }

    private func makeRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let baseURL = config.apiBaseURL else {
            throw TokenRouterError.invalidBaseURL
        }

        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: baseURL.appendingPathComponent(cleanPath), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query

        guard let url = components?.url else {
            throw TokenRouterError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.authToken.isEmpty {
            request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Value: Decodable & Sendable>(_ request: URLRequest, allowsRetry: Bool) async throws -> Value {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                    throw TokenRouterError.badStatus(http.statusCode, message)
                }

                let decoder = JSONDecoder.tokenRouter
                if let envelope = try? decoder.decode(TokenRouterEnvelope<Value>.self, from: data) {
                    return try envelope.value()
                }
                return try decoder.decode(Value.self, from: data)
            } catch {
                guard allowsRetry,
                      retryPolicy.shouldRetry(error: error, attempt: attempt) else {
                    throw error
                }
                let delay = retryPolicy.delayBeforeRetry(attempt: attempt)
                attempt += 1
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }
}

private struct AdminAccountsPage: Decodable, Sendable {
    let items: [AccountSummary]
    let page: Int
    let pageSize: Int
    let pages: Int

    private enum CodingKeys: String, CodingKey {
        case items
        case page
        case pageSize
        case pages
    }
}

public struct HTTPRetryPolicy: Equatable, Sendable {
    public let maxRetries: Int
    public let baseDelaySeconds: Double

    public init(maxRetries: Int, baseDelaySeconds: Double) {
        self.maxRetries = max(maxRetries, 0)
        self.baseDelaySeconds = max(baseDelaySeconds, 0)
    }

    public static let `default` = HTTPRetryPolicy(maxRetries: 2, baseDelaySeconds: 0.25)

    public func shouldRetry(error: Error, attempt: Int) -> Bool {
        guard attempt < maxRetries else {
            return false
        }

        if let apiError = error as? TokenRouterError {
            return apiError.isTransientFailure
        }

        let urlError = error as NSError
        guard urlError.domain == NSURLErrorDomain else {
            return false
        }

        switch urlError.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorCallIsActive,
             NSURLErrorDataNotAllowed:
            return true
        default:
            return false
        }
    }

    public func delayBeforeRetry(attempt: Int) -> Double {
        baseDelaySeconds * Double(1 << max(attempt, 0))
    }
}
