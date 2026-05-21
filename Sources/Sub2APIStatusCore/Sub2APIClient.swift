import Foundation

public struct Sub2APIClient: Sendable {
    public var config: AppConfig
    public var session: URLSession

    public init(config: AppConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
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

    public func usageDashboardTrend(startDate: String, endDate: String, granularity: String = "day") async throws -> DashboardTrendResponse {
        try await get("/usage/dashboard/trend", query: [
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
            URLQueryItem(name: "granularity", value: granularity),
        ])
    }

    public func usageDashboardModels(startDate: String, endDate: String) async throws -> DashboardModelsResponse {
        try await get("/usage/dashboard/models", query: [
            URLQueryItem(name: "start_date", value: startDate),
            URLQueryItem(name: "end_date", value: endDate),
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

    public func adminDashboardStats() async throws -> AdminDashboardStats {
        try await get("/admin/dashboard/stats")
    }

    public func refreshToken(_ refreshToken: String) async throws -> AuthResponse {
        struct RefreshRequest: Encodable, Sendable {
            let refreshToken: String
        }
        return try await post("/auth/refresh", body: RefreshRequest(refreshToken: refreshToken))
    }

    public func get<Value: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> Value {
        var request = try makeRequest(path: path, query: query)
        request.httpMethod = "GET"
        return try await send(request)
    }

    public func post<Body: Encodable & Sendable, Value: Decodable & Sendable>(_ path: String, body: Body) async throws -> Value {
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder.sub2api.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    private func makeRequest(path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let baseURL = config.apiBaseURL else {
            throw Sub2APIError.invalidBaseURL
        }

        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: baseURL.appendingPathComponent(cleanPath), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query

        guard let url = components?.url else {
            throw Sub2APIError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.authToken.isEmpty {
            request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Value: Decodable & Sendable>(_ request: URLRequest) async throws -> Value {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw Sub2APIError.badStatus(http.statusCode, message)
        }

        let decoder = JSONDecoder.sub2api
        if let envelope = try? decoder.decode(Sub2APIEnvelope<Value>.self, from: data) {
            return try envelope.value()
        }
        return try decoder.decode(Value.self, from: data)
    }
}
