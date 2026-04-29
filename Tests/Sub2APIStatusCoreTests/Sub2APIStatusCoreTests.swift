import Foundation
import XCTest
@testable import Sub2APIStatusCore

final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    var tokens = StoredAuthTokens()
    var saves: [StoredAuthTokens] = []

    func loadTokens() -> StoredAuthTokens {
        tokens
    }

    func saveTokens(_ tokens: StoredAuthTokens) throws {
        self.tokens = tokens
        saves.append(tokens)
    }
}

final class Sub2APIStatusCoreTests: XCTestCase {

func testAppConfigNormalizesBaseURLAndRefreshInterval() {
    var config = AppConfig(baseURL: " http://127.0.0.1:8080/api/v1/// ", authToken: " token ", refreshIntervalSeconds: 1, language: .zhHans, monitorMode: .user)

    config.normalize()

    XCTAssert(config.baseURL == "http://127.0.0.1:8080")
    XCTAssert(config.authToken == "token")
    XCTAssert(config.refreshIntervalSeconds == 5)
    XCTAssert(config.monitorMode == .user)
    XCTAssert(config.showsMenuBarText == false)
}

func testAppConfigPersistsMenuBarTextPreference() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = ConfigStore(configURL: configURL)
    let config = AppConfig(baseURL: "http://127.0.0.1:8080", showsMenuBarText: true)

    try store.save(config)
    let loaded = store.load()

    XCTAssert(loaded.baseURL == "http://127.0.0.1:8080")
    XCTAssert(loaded.showsMenuBarText == true)
}

func testConfigStoreSavesTokensOutsideConfigJSON() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let tokenStore = MemoryTokenStore()
    let store = ConfigStore(configURL: configURL, tokenStore: tokenStore)
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        authToken: "access-token",
        refreshToken: "refresh-token",
        showsMenuBarText: true
    )

    try store.save(config)

    let rawJSON = try String(contentsOf: configURL, encoding: .utf8)
    XCTAssert(!rawJSON.contains("access-token"))
    XCTAssert(!rawJSON.contains("refresh-token"))
    XCTAssert(!rawJSON.contains("authToken"))
    XCTAssert(!rawJSON.contains("refreshToken"))
    XCTAssert(tokenStore.tokens.authToken == "access-token")
    XCTAssert(tokenStore.tokens.refreshToken == "refresh-token")
    XCTAssert(store.load().authToken == "access-token")
}

func testConfigStoreMigratesLegacyJSONTokensOutOfConfigFile() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "baseURL" : "http://127.0.0.1:8080",
      "authToken" : "legacy-access",
      "refreshToken" : "legacy-refresh",
      "refreshIntervalSeconds" : 15,
      "language" : "auto",
      "monitorMode" : "user",
      "showsMenuBarText" : true
    }
    """.write(to: configURL, atomically: true, encoding: .utf8)
    let tokenStore = MemoryTokenStore()
    let store = ConfigStore(configURL: configURL, tokenStore: tokenStore)

    let loaded = store.load()

    XCTAssert(loaded.authToken == "legacy-access")
    XCTAssert(loaded.refreshToken == "legacy-refresh")
    XCTAssert(tokenStore.tokens.authToken == "legacy-access")
    XCTAssert(tokenStore.tokens.refreshToken == "legacy-refresh")

    let migratedJSON = try String(contentsOf: configURL, encoding: .utf8)
    XCTAssert(!migratedJSON.contains("legacy-access"))
    XCTAssert(!migratedJSON.contains("legacy-refresh"))
    XCTAssert(!migratedJSON.contains("authToken"))
    XCTAssert(!migratedJSON.contains("refreshToken"))
}

func testAppConfigDefaultsToUserMode() {
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssert(config.monitorMode == .user)
}

func testAppConfigDecodesLegacyAdminModeAsUserMode() throws {
    let data = """
    {
      "baseURL": "http://127.0.0.1:8080",
      "monitorMode": "admin"
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder.sub2api.decode(AppConfig.self, from: data)

    XCTAssert(config.monitorMode == .user)
}

func testAppConfigClearsAuthTokens() {
    var config = AppConfig(baseURL: "http://127.0.0.1:8080", authToken: "access", refreshToken: "refresh")

    config.clearAuthTokens()

    XCTAssert(config.authToken.isEmpty)
    XCTAssert(config.refreshToken.isEmpty)
}

func testApiEnvelopeDecodesWrappedData() throws {
    let json = """
    {
      "code": 0,
      "message": "ok",
      "data": {
        "active_requests": 2,
        "requests_per_minute": 13.5,
        "average_response_time": 840,
        "error_rate": 0.025
      }
    }
    """.data(using: .utf8)!

    let metrics = try JSONDecoder.sub2api.decode(Sub2APIEnvelope<RealtimeMetrics>.self, from: json).value()

    XCTAssert(metrics.activeRequests == 2)
    XCTAssert(metrics.requestsPerMinute == 13.5)
    XCTAssert(metrics.averageResponseTime == 840)
    XCTAssert(metrics.errorRate == 0.025)
}

func testSub2APIErrorIdentifiesUnauthorizedResponses() {
    XCTAssert(Sub2APIError.badStatus(401, "expired").isUnauthorized == true)
    XCTAssert(Sub2APIError.badStatus(403, "forbidden").isUnauthorized == false)
    XCTAssert(Sub2APIError.invalidBaseURL.isUnauthorized == false)
}

func testAppVersionComparesSemanticVersions() {
    XCTAssert(AppVersion("v0.1.10") > AppVersion("0.1.2"))
    XCTAssert(AppVersion("1.0") == AppVersion("1.0.0"))
    XCTAssert(AppVersion("v2.0.0-beta") > AppVersion("1.9.9"))
}

func testGithubReleaseDecodesLatestReleasePayload() throws {
    let json = """
    {
      "tag_name": "v0.1.3",
      "name": "Sub2API Status Bar v0.1.3",
      "html_url": "https://github.com/GeekyWizKid/Sub2APIStatusBar/releases/tag/v0.1.3",
      "draft": false,
      "prerelease": false
    }
    """.data(using: .utf8)!

    let release = try JSONDecoder().decode(GitHubRelease.self, from: json)

    XCTAssert(release.tagName == "v0.1.3")
    XCTAssert(release.version == AppVersion("0.1.3"))
    XCTAssert(release.releaseURL.absoluteString.hasSuffix("/v0.1.3"))
}

func testUpdateInfoDetectsAvailableRelease() {
    let release = GitHubRelease(
        tagName: "v0.1.3",
        name: "Sub2API Status Bar v0.1.3",
        releaseURL: URL(string: "https://github.com/GeekyWizKid/Sub2APIStatusBar/releases/tag/v0.1.3")!,
        draft: false,
        prerelease: false
    )

    let available = UpdateInfo(currentVersion: AppVersion("0.1.2"), release: release)
    let current = UpdateInfo(currentVersion: AppVersion("0.1.3"), release: release)

    XCTAssert(available.isUpdateAvailable == true)
    XCTAssert(available.statusText == "Version 0.1.3 is available.")
    XCTAssert(current.isUpdateAvailable == false)
    XCTAssert(current.statusText == "You are up to date.")
}

func testCurrentUserResponseDecodesDirectUserPayload() throws {
    let json = """
    {
      "id": 7,
      "email": "user@example.com",
      "username": "das",
      "role": "user",
      "balance": 12.34,
      "status": "active"
    }
    """.data(using: .utf8)!

    let response = try JSONDecoder.sub2api.decode(CurrentUserResponse.self, from: json)

    XCTAssert(response.user?.balance == 12.34)
    XCTAssert(response.user?.username == "das")
}

func testDashboardSnapshotDecodesTokenBreakdownAndModelDistribution() throws {
    let json = """
    {
      "generated_at": "2026-04-28T13:00:00Z",
      "stats": {
        "today_requests": 1119,
        "today_tokens": 121800000,
        "today_input_tokens": 7400000,
        "today_output_tokens": 513900,
        "total_tokens": 594300000,
        "total_input_tokens": 40200000,
        "total_output_tokens": 3500000,
        "today_actual_cost": 113.3052,
        "rpm": 3,
        "tpm": 12200,
        "average_duration_ms": 14570
      },
      "model_distribution": [
        {
          "model": "gpt-5.5",
          "requests": 2116,
          "total_tokens": 244400000,
          "input_tokens": 200000000,
          "output_tokens": 44400000,
          "actual_cost": 218.2116,
          "standard_cost": 218.2116
        }
      ]
    }
    """.data(using: .utf8)!

    let snapshot = try JSONDecoder.sub2api.decode(DashboardSnapshot.self, from: json)

    XCTAssert(snapshot.stats?.todayInputTokens == 7_400_000)
    XCTAssert(snapshot.stats?.todayOutputTokens == 513_900)
    XCTAssert(snapshot.stats?.totalInputTokens == 40_200_000)
    XCTAssert(snapshot.stats?.totalOutputTokens == 3_500_000)
    XCTAssert(snapshot.modelDistribution?.first?.model == "gpt-5.5")
    XCTAssert(snapshot.modelDistribution?.first?.requests == 2116)
    XCTAssert(snapshot.modelDistribution?.first?.actualCost == 218.2116)
}

func testUsageDashboardDecodesUserStatsTrendAndModels() throws {
    let statsJSON = """
    {
      "total_api_keys": 2,
      "active_api_keys": 2,
      "total_requests": 5476,
      "total_input_tokens": 40529619,
      "total_output_tokens": 3499464,
      "total_cache_creation_tokens": 0,
      "total_cache_read_tokens": 554867072,
      "total_tokens": 598896155,
      "total_cost": 498.69043735,
      "total_actual_cost": 498.69043735,
      "today_requests": 1186,
      "today_input_tokens": 7657045,
      "today_output_tokens": 536098,
      "today_cache_creation_tokens": 0,
      "today_cache_read_tokens": 118193024,
      "today_tokens": 126386167,
      "today_cost": 117.56682985,
      "today_actual_cost": 117.56682985,
      "average_duration_ms": 14514.6375,
      "rpm": 1,
      "tpm": 10752
    }
    """.data(using: .utf8)!
    let trendJSON = """
    {
      "trend": [
        {
          "date": "2026-04-28",
          "requests": 1187,
          "input_tokens": 7672001,
          "output_tokens": 536486,
          "cache_creation_tokens": 0,
          "cache_read_tokens": 118310656,
          "total_tokens": 126519143,
          "cost": 117.71206585,
          "actual_cost": 117.71206585
        }
      ]
    }
    """.data(using: .utf8)!
    let modelsJSON = """
    {
      "models": [
        {
          "model": "gpt-5.5",
          "requests": 2184,
          "input_tokens": 14103149,
          "output_tokens": 1004490,
          "cache_creation_tokens": 0,
          "cache_read_tokens": 234003712,
          "total_tokens": 249111351,
          "cost": 222.61852,
          "actual_cost": 222.61852,
          "account_cost": 222.61852
        }
      ]
    }
    """.data(using: .utf8)!

    let stats = try JSONDecoder.sub2api.decode(DashboardStats.self, from: statsJSON)
    let trend = try JSONDecoder.sub2api.decode(DashboardTrendResponse.self, from: trendJSON)
    let models = try JSONDecoder.sub2api.decode(DashboardModelsResponse.self, from: modelsJSON)

    XCTAssert(stats.todayCacheReadTokens == 118_193_024)
    XCTAssert(stats.todayCost == 117.56682985)
    XCTAssert(trend.trend.first?.inputTokens == 7_672_001)
    XCTAssert(trend.trend.first?.cacheReadTokens == 118_310_656)
    XCTAssert(models.models.first?.accountCost == 222.61852)
    XCTAssert(models.models.first?.standardCost == 222.61852)
}

func testAccountHealthSummaryCountsRuntimeStates() {
    let accounts = [
        AccountSummary(id: 1, name: "ok", platform: "openai", type: "oauth", status: "active", schedulable: true, quotaLimit: 100, quotaUsed: 30, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "", rateLimitResetAt: nil),
        AccountSummary(id: 2, name: "blocked", platform: "openai", type: "oauth", status: "active", schedulable: false, quotaLimit: 100, quotaUsed: 91, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "", rateLimitResetAt: nil),
        AccountSummary(id: 3, name: "bad", platform: "anthropic", type: "setup_token", status: "disabled", schedulable: false, quotaLimit: nil, quotaUsed: nil, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "expired", rateLimitResetAt: nil),
    ]

    let summary = AccountHealthSummary(accounts: accounts)

    XCTAssert(summary.total == 3)
    XCTAssert(summary.active == 2)
    XCTAssert(summary.schedulable == 1)
    XCTAssert(summary.blocked == 2)
    XCTAssert(summary.nearQuotaLimit == 1)
}

func testSubscriptionProgressFindsHighestUsageRatio() {
    let subscriptions = [
        SubscriptionSummaryItem(id: 1, groupName: "Claude", status: "active", dailyProgress: 0.25, weeklyProgress: nil, monthlyProgress: 0.6, expiresAt: nil, daysRemaining: 12),
        SubscriptionSummaryItem(id: 2, groupName: "OpenAI", status: "active", dailyProgress: 0.82, weeklyProgress: 0.71, monthlyProgress: nil, expiresAt: nil, daysRemaining: 2),
    ]

    let summary = SubscriptionSummary(activeCount: 2, subscriptions: subscriptions)

    XCTAssert(summary.highestProgress == 0.82)
    XCTAssert(summary.expiringSoonCount == 1)
}

func testSubscriptionSummaryDecodesUsdUsageIntoProgress() throws {
    let json = """
    {
      "active_count": 1,
      "total_used_usd": 498.38329835,
      "subscriptions": [
        {
          "id": 2,
          "group_name": "codex",
          "status": "active",
          "daily_used_usd": 117.25969085,
          "daily_limit_usd": 124.97,
          "weekly_used_usd": 153.11513095,
          "weekly_limit_usd": 500,
          "monthly_used_usd": 498.38329835,
          "monthly_limit_usd": 2000,
          "daily_reset_in_seconds": 6960,
          "weekly_reset_in_seconds": 435660,
          "monthly_reset_in_seconds": 1821660,
          "days_remaining": 22,
          "expires_at": "2026-05-20T16:29:44+08:00"
        }
      ]
    }
    """.data(using: .utf8)!

    let summary = try JSONDecoder.sub2api.decode(SubscriptionSummary.self, from: json)

    XCTAssert(summary.totalUsedUSD == 498.38329835)
    XCTAssert(summary.subscriptions.first?.dailyProgress ?? 0 > 0.93)
    XCTAssert(summary.subscriptions.first?.monthlyProgress ?? 0 > 0.24)
    XCTAssert(summary.subscriptions.first?.dailyResetInSeconds == 6960)
    XCTAssert(summary.subscriptions.first?.daysRemaining == 22)
}

func testMonitorSnapshotEscalatesSeverityFromSignals() {
    let healthy = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 20, todayActualCost: 1.2, rpm: 4),
        realtime: RealtimeMetrics(errorRate: 0.01),
        accountHealth: AccountHealthSummary(accounts: []),
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )

    let warned = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 20, todayActualCost: 1.2, rpm: 4),
        realtime: RealtimeMetrics(errorRate: 0.01),
        accountHealth: AccountHealthSummary(accounts: [
            AccountSummary(id: 1, name: "quota", platform: "openai", type: "oauth", status: "active", schedulable: true, quotaLimit: 10, quotaUsed: 9.1, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "", rateLimitResetAt: nil),
        ]),
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )

    let failed = MonitorSnapshot(
        mode: .user,
        connected: false,
        stats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: "offline"
    )

    XCTAssert(healthy.severity == .healthy)
    XCTAssert(warned.severity == .warning)
    XCTAssert(failed.severity == .error)
}

func testMonitorSnapshotLabelsNearLimitSeparatelyFromConnectionFailure() {
    let nearLimit = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: SubscriptionSummary(activeCount: 1, subscriptions: [
            SubscriptionSummaryItem(id: 1, groupName: "codex", status: "active", dailyProgress: 0.966, weeklyProgress: nil, monthlyProgress: nil, expiresAt: nil, daysRemaining: 20),
        ]),
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let disconnected = MonitorSnapshot(
        mode: .user,
        connected: false,
        stats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: "offline"
    )

    XCTAssert(nearLimit.statusLabel == "Near Limit")
    XCTAssert(disconnected.statusLabel == "Disconnected")
}

func testMonitorSnapshotBuildsMenuBarSummaryFromDashboardStats() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 1119, todayActualCost: 113.3052, rpm: 3),
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )

    XCTAssert(snapshot.menuBarSummary == "$113.31 · 1119 req · 3 RPM")
}

func testLoginFormStateRequiresURLAccountAndPassword() {
    XCTAssert(LoginFormState(baseURL: "", email: "a@example.com", password: "secret").canSubmit == false)
    XCTAssert(LoginFormState(baseURL: "http://127.0.0.1:8080", email: "", password: "secret").canSubmit == false)
    XCTAssert(LoginFormState(baseURL: "http://127.0.0.1:8080", email: "a@example.com", password: "").canSubmit == false)
    XCTAssert(LoginFormState(baseURL: "http://127.0.0.1:8080", email: "a@example.com", password: "secret").canSubmit == true)
}

}
