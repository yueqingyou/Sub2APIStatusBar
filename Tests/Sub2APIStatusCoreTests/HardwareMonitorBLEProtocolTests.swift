import Foundation
import XCTest
@testable import Sub2APIStatusCore

final class HardwareMonitorBLEProtocolTests: XCTestCase {
    func testHelloPayloadContainsMagicVersionAndMessageType() {
        XCTAssertEqual(
            HardwareMonitorBLEProtocol.helloPayload,
            Data([0x54, 0x52, 0x4D, 0x06, 0x01])
        )
    }

    func testDecodesReadyDeviceStatusAndCurrentPage() throws {
        let status = try HardwareMonitorBLEProtocol.decodeStatus(
            Data([
                0x54, 0x52, 0x4D, 0x06, 0x00, 0x09, 0x00, 0x0F, 0x02,
                0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0xD3, 0x82, 0x15, 0x0E,
            ])
        )

        XCTAssertEqual(status.protocolVersion, 6)
        XCTAssertEqual(status.firmwareVersion, "0.9.0")
        XCTAssertEqual(status.currentPage, .quota)
        XCTAssertTrue(status.isLinkConnected)
        XCTAssertTrue(status.isHandshakeReady)
        XCTAssertTrue(status.isLinkEncrypted)
        XCTAssertTrue(status.isBonded)
        XCTAssertFalse(status.isPairingWindowOpen)
        XCTAssertTrue(status.isMonitorProtocolCompatible)
        XCTAssertTrue(status.supportsFirmwareUpdate)
        XCTAssertEqual(status.firmwareUpdateState, .idle)
        XCTAssertEqual(status.firmwareUpdateErrorCode, 0)
        XCTAssertEqual(status.firmwareUpdateReceivedBytes, 0)
        XCTAssertEqual(status.nightSleepEnabled, true)
        XCTAssertEqual(status.nightSleepClockSynchronized, true)
        XCTAssertEqual(status.nightSleepManualOverride, false)
        XCTAssertEqual(status.nightSleepLastWakeReason, .rtcInterrupt)
        XCTAssertEqual(status.nightSleepRTCFallbackActive, true)
        XCTAssertEqual(status.nightSleepBootSequenceParity, true)
        XCTAssertEqual(status.nightSleepStartMinute, 1_410)
        XCTAssertEqual(status.nightSleepEndMinute, 450)
    }

    func testDecodesOlderMonitorStatusForFirmwareUpdateCompatibility() throws {
        let status = try HardwareMonitorBLEProtocol.decodeStatus(
            Data([
                0x54, 0x52, 0x4D, 0x03, 0x00, 0x06, 0x00, 0x0D, 0x00,
                0x01, 0x01, 0x00, 0xF0, 0x00, 0x00, 0x00,
            ])
        )

        XCTAssertFalse(status.isMonitorProtocolCompatible)
        XCTAssertTrue(status.supportsFirmwareUpdate)
        XCTAssertEqual(status.firmwareVersion, "0.6.0")
        XCTAssertEqual(status.firmwareUpdateState, .receiving)
        XCTAssertEqual(status.firmwareUpdateReceivedBytes, 240)
        XCTAssertNil(status.nightSleepEnabled)
        XCTAssertNil(status.nightSleepClockSynchronized)
        XCTAssertNil(status.nightSleepManualOverride)
        XCTAssertNil(status.nightSleepLastWakeReason)
        XCTAssertNil(status.nightSleepRTCFallbackActive)
        XCTAssertNil(status.nightSleepBootSequenceParity)
    }

    func testRejectsTruncatedCurrentProtocolStatus() {
        XCTAssertThrowsError(try HardwareMonitorBLEProtocol.decodeStatus(Data([
            0x54, 0x52, 0x4D, 0x06, 0x00, 0x09, 0x00, 0x0F, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]))) { error in
            XCTAssertEqual(
                error as? HardwareMonitorBLEProtocolError,
                .invalidStatusLength(16)
            )
        }
    }

    func testEncodesBeijingClockAndNightSleepSchedule() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-10T15:31:42Z"))
        let settings = HardwareMonitorSyncSettings(
            nightSleepEnabled: true,
            nightSleepStartMinute: 1_410,
            nightSleepEndMinute: 450
        )

        XCTAssertEqual(
            HardwareMonitorBLEProtocol.powerSchedulePayload(
                syncSettings: settings,
                at: date
            ).bytes,
            [
                0x54, 0x52, 0x4D, 0x06, 0x03,
                0x01, 0x82, 0x05, 0xC2, 0x01,
                0xEA, 0x07, 0x08, 0x0A, 0x01, 0x17, 0x1F, 0x2A,
            ]
        )
    }

    func testBeijingNightSleepWindowCrossesMidnight() throws {
        let settings = HardwareMonitorSyncSettings()
        let formatter = ISO8601DateFormatter()

        XCTAssertTrue(settings.isNightSleepWindowActive(
            at: try XCTUnwrap(formatter.date(from: "2026-08-10T15:30:00Z"))
        ))
        XCTAssertTrue(settings.isNightSleepWindowActive(
            at: try XCTUnwrap(formatter.date(from: "2026-08-10T23:29:59Z"))
        ))
        XCTAssertFalse(settings.isNightSleepWindowActive(
            at: try XCTUnwrap(formatter.date(from: "2026-08-10T23:30:00Z"))
        ))
        XCTAssertFalse(settings.isNightSleepWindowActive(
            at: try XCTUnwrap(formatter.date(from: "2026-08-10T04:00:00Z"))
        ))

        var disabled = settings
        disabled.nightSleepEnabled = false
        XCTAssertFalse(disabled.isNightSleepWindowActive(
            at: try XCTUnwrap(formatter.date(from: "2026-08-10T15:30:00Z"))
        ))
    }

    func testBuildsSanitizedOverviewAndTaskPayloadsWithoutRealtimeCounts() throws {
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = MonitorSnapshot(
            mode: .user,
            connected: true,
            stats: DashboardStats(
                todayRequests: 42,
                todayTokens: 123_456,
                todayActualCost: 1.25
            ),
            realtime: nil,
            accountHealth: nil,
            subscriptionSummary: nil,
            codexTaskActivities: [
                task(status: .running, id: "running", now: now),
                task(status: .waiting, id: "waiting", now: now),
                task(status: .done, id: "done", now: now),
            ],
            lastUpdatedAt: now,
            message: nil
        )

        let payloads = HardwareMonitorBLEProtocol.payloads(
            snapshot: snapshot,
            networkAvailable: true,
            syncSettings: HardwareMonitorSyncSettings(offlineCheckIntervalSeconds: 30)
        )
        let overview = try XCTUnwrap(payloads.pages[.overview]).bytes
        let tasks = try XCTUnwrap(payloads.pages[.tasks]).bytes

        XCTAssertEqual(
            payloads.heartbeats[.overview]?.bytes,
            [0x54, 0x52, 0x4D, 0x06, 0x02, 0x03, 90, 0, 0, 0, 0x84, 0x03, 0, 0]
        )
        XCTAssertEqual(
            Array(overview.prefix(15)),
            [0x54, 0x52, 0x4D, 0x06, 0x10, 0x03, 90, 0, 0, 0, 0x84, 0x03, 0, 0, 1]
        )
        XCTAssertEqual(readUInt64(overview, at: 15), 1_250_000)
        XCTAssertEqual(readUInt64(overview, at: 23), 42)
        XCTAssertEqual(readUInt64(overview, at: 31), 123_456)
        XCTAssertEqual(overview.count, 39)

        XCTAssertEqual(
            Array(tasks.prefix(14)),
            [0x54, 0x52, 0x4D, 0x06, 0x11, 0x03, 90, 0, 0, 0, 0x84, 0x03, 0, 0]
        )
        XCTAssertEqual(readUInt16(tasks, at: 14), 1)
        XCTAssertEqual(readUInt16(tasks, at: 16), 1)
        XCTAssertEqual(readUInt16(tasks, at: 18), 0)
        XCTAssertEqual(readUInt16(tasks, at: 20), 0)
        XCTAssertEqual(tasks.count, 22)
    }

    func testEncodesBatterySampleIntervalInEveryMonitorPayload() throws {
        let payloads = HardwareMonitorBLEProtocol.payloads(
            snapshot: .idle(mode: .user),
            networkAvailable: false,
            syncSettings: HardwareMonitorSyncSettings(
                batterySampleIntervalSeconds: 3_600
            )
        )

        for page in HardwareMonitorPage.allCases {
            let heartbeat = try XCTUnwrap(payloads.heartbeats[page]).bytes
            let pagePayload = try XCTUnwrap(payloads.pages[page]).bytes
            XCTAssertEqual(Array(heartbeat[10..<14]), [0x10, 0x0E, 0x00, 0x00])
            XCTAssertEqual(Array(pagePayload[10..<14]), [0x10, 0x0E, 0x00, 0x00])
        }
    }

    func testBuildsAdminQuotaPayloadWithCapacityAboveOneHundredPercentWithoutRealtimeFields() throws {
        let account = AccountSummary(
            id: 1,
            name: "test",
            platform: "openai",
            type: "oauth",
            status: "active",
            schedulable: true,
            credentials: ["plan_type": "pro"],
            quotaLimit: nil,
            quotaUsed: nil,
            quotaDailyLimit: nil,
            quotaDailyUsed: nil,
            quotaWeeklyLimit: nil,
            quotaWeeklyUsed: nil,
            errorMessage: "",
            rateLimitResetAt: nil
        )
        let quotaAccount = OpenAIAccountQuota(
            account: account,
            usage: AccountUsageInfo(
                updatedAt: nil,
                fiveHour: UsageProgress(
                    utilization: 20,
                    resetsAt: nil,
                    remainingSeconds: 1_000,
                    windowStats: nil
                ),
                sevenDay: UsageProgress(
                    utilization: 50,
                    resetsAt: nil,
                    remainingSeconds: 2_000,
                    windowStats: nil
                ),
                quotaAutoPaused: false
            )
        )
        let snapshot = MonitorSnapshot(
            mode: .admin,
            connected: true,
            stats: nil,
            realtime: nil,
            realtimeConcurrency: UserRealtimeConcurrency(
                userID: 7,
                userEmail: "",
                username: "",
                currentInUse: 3,
                maxCapacity: 10,
                loadPercentage: 30,
                waitingInQueue: 2
            ),
            adminNormalAccountCount: 8,
            openAIQuota: OpenAIAccountQuotaSnapshot(
                accounts: [
                    quotaAccount,
                    quotaAccountWithID(
                        2,
                        basedOn: quotaAccount,
                        fiveHourRemainingSeconds: 500,
                        sevenDayRemainingSeconds: 3_000
                    ),
                ],
                history: OpenAIQuotaHistory()
            ),
            accountHealth: nil,
            subscriptionSummary: nil,
            lastUpdatedAt: Date(),
            message: nil,
            isStale: true
        )

        XCTAssertTrue(HardwareMonitorBLEProtocol.isPageDataAvailable(in: snapshot, for: .quota))

        let quota = try XCTUnwrap(HardwareMonitorBLEProtocol.payloads(
            snapshot: snapshot,
            networkAvailable: true,
            syncSettings: HardwareMonitorSyncSettings(offlineCheckIntervalSeconds: nil)
        ).pages[.quota]).bytes

        XCTAssertEqual(
            Array(quota.prefix(15)),
            [0x54, 0x52, 0x4D, 0x06, 0x12, 0x0F, 0x18, 0x15, 0x00, 0x00, 0x84, 0x03, 0, 0, 0x0F]
        )
        XCTAssertEqual(readUInt32(quota, at: 15), 16_000)
        XCTAssertEqual(readUInt32(quota, at: 19), 10_000)
        XCTAssertEqual(readUInt32(quota, at: 23), 500)
        XCTAssertEqual(readUInt32(quota, at: 27), 2_000)
        XCTAssertEqual(quota.count, 31)
    }

    func testOverviewPayloadClampsExtremeFiniteCostWithoutOverflowing() throws {
        let snapshot = MonitorSnapshot(
            mode: .user,
            connected: true,
            stats: DashboardStats(
                todayRequests: 1,
                todayTokens: 1,
                todayActualCost: Double.greatestFiniteMagnitude
            ),
            realtime: nil,
            accountHealth: nil,
            subscriptionSummary: nil,
            lastUpdatedAt: Date(),
            message: nil
        )

        let overview = try XCTUnwrap(HardwareMonitorBLEProtocol.payloads(
            snapshot: snapshot,
            networkAvailable: true,
            syncSettings: HardwareMonitorSyncSettings()
        ).pages[.overview]).bytes

        XCTAssertEqual(readUInt64(overview, at: 15), UInt64.max)
    }

    func testPageDataAvailabilityDetectsFirstUsableOverviewAndQuotaValues() {
        let idle = MonitorSnapshot.idle(mode: .admin)
        let overview = MonitorSnapshot(
            mode: .admin,
            connected: true,
            stats: DashboardStats(todayRequests: 1, todayTokens: 2, todayActualCost: 0.5),
            realtime: nil,
            adminNormalAccountCount: 0,
            accountHealth: nil,
            subscriptionSummary: nil,
            lastUpdatedAt: Date(),
            message: nil
        )

        XCTAssertFalse(HardwareMonitorBLEProtocol.isPageDataAvailable(in: idle, for: .overview))
        XCTAssertFalse(HardwareMonitorBLEProtocol.isPageDataAvailable(in: idle, for: .quota))
        XCTAssertFalse(HardwareMonitorBLEProtocol.isPageDataAvailable(in: idle, for: .tasks))
        XCTAssertTrue(HardwareMonitorBLEProtocol.isPageDataAvailable(in: idle, for: .device))
        XCTAssertTrue(HardwareMonitorBLEProtocol.isPageDataAvailable(in: overview, for: .overview))
        XCTAssertFalse(HardwareMonitorBLEProtocol.isPageDataAvailable(in: overview, for: .quota))

        let completedTaskSnapshot = idle.withCodexTaskActivities([
            task(status: .done, id: "done", now: Date()),
        ])
        XCTAssertTrue(HardwareMonitorBLEProtocol.isPageDataAvailable(in: completedTaskSnapshot, for: .tasks))
    }

    func testSyncSettingsNormalizeAndSelectIndependentPageIntervals() {
        var settings = HardwareMonitorSyncSettings(
            overviewIntervalSeconds: 1,
            tasksIntervalSeconds: 15,
            quotaIntervalSeconds: 200_000,
            deviceIntervalSeconds: 300,
            batterySampleIntervalSeconds: 1,
            offlineCheckIntervalSeconds: 2,
            nightSleepStartMinute: -1,
            nightSleepEndMinute: 2_000
        )

        XCTAssertEqual(settings.interval(for: .overview), 5)
        XCTAssertEqual(settings.interval(for: .tasks), 15)
        XCTAssertEqual(settings.interval(for: .quota), 86_400)
        XCTAssertEqual(settings.interval(for: .device), 300)
        XCTAssertEqual(settings.batterySampleIntervalSeconds, 300)
        XCTAssertEqual(settings.batterySampleIntervalWholeSeconds, 300)
        XCTAssertEqual(settings.offlineCheckIntervalSeconds, 5)
        XCTAssertEqual(settings.offlineTimeoutSeconds(for: .overview), 15)
        XCTAssertEqual(settings.nightSleepStartMinute, 0)
        XCTAssertEqual(settings.nightSleepEndMinute, 1_439)

        settings.nightSleepStartMinute = 600
        settings.nightSleepEndMinute = 600
        settings.normalize()
        XCTAssertEqual(settings.nightSleepStartMinute, 1_410)
        XCTAssertEqual(settings.nightSleepEndMinute, 450)

        settings.batterySampleIntervalSeconds = 200_000
        settings.normalize()
        XCTAssertEqual(settings.batterySampleIntervalSeconds, 86_400)
        XCTAssertEqual(settings.batterySampleIntervalWholeSeconds, 86_400)

        settings.offlineCheckIntervalSeconds = nil
        settings.normalize()
        XCTAssertEqual(settings.offlineTimeoutSeconds(for: .overview), 15)
        XCTAssertEqual(settings.offlineTimeoutSeconds(for: .tasks), 45)
        XCTAssertEqual(settings.offlineTimeoutSeconds(for: .quota), 259_200)
    }

    func testSyncSettingsDecodeMissingOfflineIntervalAsDefaultAndNullAsDisabled() throws {
        let defaults = HardwareMonitorSyncSettings()
        let missing = try JSONDecoder().decode(
            HardwareMonitorSyncSettings.self,
            from: Data(#"{"overviewIntervalSeconds":30}"#.utf8)
        )
        let disabled = try JSONDecoder().decode(
            HardwareMonitorSyncSettings.self,
            from: Data(#"{"offlineCheckIntervalSeconds":null}"#.utf8)
        )

        XCTAssertEqual(defaults.overviewIntervalSeconds, 300)
        XCTAssertEqual(defaults.tasksIntervalSeconds, 300)
        XCTAssertEqual(defaults.quotaIntervalSeconds, 1_800)
        XCTAssertEqual(defaults.deviceIntervalSeconds, 900)
        XCTAssertEqual(defaults.batterySampleIntervalSeconds, 900)
        XCTAssertEqual(defaults.offlineCheckIntervalSeconds, 30)
        XCTAssertTrue(defaults.nightSleepEnabled)
        XCTAssertEqual(defaults.nightSleepStartMinute, 1_410)
        XCTAssertEqual(defaults.nightSleepEndMinute, 450)
        XCTAssertEqual(missing.offlineCheckIntervalSeconds, 30)
        XCTAssertEqual(missing.overviewIntervalSeconds, 30)
        XCTAssertEqual(missing.tasksIntervalSeconds, 300)
        XCTAssertEqual(missing.quotaIntervalSeconds, 1_800)
        XCTAssertEqual(missing.deviceIntervalSeconds, 900)
        XCTAssertEqual(missing.batterySampleIntervalSeconds, 900)
        XCTAssertTrue(missing.nightSleepEnabled)
        XCTAssertEqual(missing.nightSleepStartMinute, 1_410)
        XCTAssertEqual(missing.nightSleepEndMinute, 450)
        XCTAssertNil(disabled.offlineCheckIntervalSeconds)
    }

    func testRejectsWrongStatusLengthMagicAndPage() {
        XCTAssertThrowsError(try HardwareMonitorBLEProtocol.decodeStatus(Data([0x54]))) { error in
            XCTAssertEqual(error as? HardwareMonitorBLEProtocolError, .invalidStatusLength(1))
        }
        XCTAssertThrowsError(
            try HardwareMonitorBLEProtocol.decodeStatus(
                Data([0x00, 0x52, 0x4D, 0x04, 0x00, 0x07, 0x00, 0x0F, 0x00])
            )
        ) { error in
            XCTAssertEqual(error as? HardwareMonitorBLEProtocolError, .invalidMagic)
        }
        XCTAssertThrowsError(
            try HardwareMonitorBLEProtocol.decodeStatus(
                Data([0x54, 0x52, 0x4D, 0x04, 0x00, 0x07, 0x00, 0x0F, 0xFF])
            )
        ) { error in
            XCTAssertEqual(error as? HardwareMonitorBLEProtocolError, .unsupportedPage(0xFF))
        }
    }

    func testLegacyConfigKeepsHardwareMonitorDisabledWithDefaultSyncSettings() throws {
        let data = Data(#"{"baseURL":"http://127.0.0.1:8080"}"#.utf8)

        let config = try JSONDecoder.tokenRouter.decode(AppConfig.self, from: data)

        XCTAssertFalse(config.hardwareMonitorEnabled)
        XCTAssertEqual(config.hardwareMonitorSyncSettings, HardwareMonitorSyncSettings())
    }

    func testConfigStorePersistsHardwareMonitorPreferences() throws {
        let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
        let store = ConfigStore(configURL: configURL, tokenStore: HardwareMonitorMemoryTokenStore())
        let syncSettings = HardwareMonitorSyncSettings(
            overviewIntervalSeconds: 30,
            tasksIntervalSeconds: 5,
            quotaIntervalSeconds: 3_600,
            deviceIntervalSeconds: 600,
            batterySampleIntervalSeconds: 21_600,
            offlineCheckIntervalSeconds: nil,
            nightSleepEnabled: true,
            nightSleepStartMinute: 1_320,
            nightSleepEndMinute: 480
        )

        try store.save(AppConfig(
            baseURL: "http://127.0.0.1:8080",
            hardwareMonitorEnabled: true,
            hardwareMonitorSyncSettings: syncSettings
        ))

        XCTAssertTrue(store.load().hardwareMonitorEnabled)
        XCTAssertEqual(store.load().hardwareMonitorSyncSettings, syncSettings)
    }

    private func task(status: CodexTaskActivity.Status, id: String, now: Date) -> CodexTaskActivity {
        CodexTaskActivity(
            nodeID: "local",
            sessionID: id,
            turnID: id,
            badge: id,
            cwd: nil,
            model: nil,
            status: status,
            phase: .prompt,
            toolName: nil,
            startedAt: now,
            updatedAt: now,
            completedAt: status == .done ? now : nil,
            timeline: []
        )
    }

    private func quotaAccountWithID(
        _ id: Int64,
        basedOn source: OpenAIAccountQuota,
        fiveHourRemainingSeconds: Int? = nil,
        sevenDayRemainingSeconds: Int? = nil
    ) -> OpenAIAccountQuota {
        OpenAIAccountQuota(
            account: AccountSummary(
                id: id,
                name: source.account.name,
                platform: source.account.platform,
                type: source.account.type,
                status: source.account.status,
                schedulable: source.account.schedulable,
                credentials: source.account.credentials,
                quotaLimit: nil,
                quotaUsed: nil,
                quotaDailyLimit: nil,
                quotaDailyUsed: nil,
                quotaWeeklyLimit: nil,
                quotaWeeklyUsed: nil,
                errorMessage: "",
                rateLimitResetAt: nil
            ),
            usage: AccountUsageInfo(
                updatedAt: source.usage.updatedAt,
                fiveHour: source.usage.fiveHour.map { progress in
                    UsageProgress(
                        utilization: progress.utilization,
                        resetsAt: progress.resetsAt,
                        remainingSeconds: fiveHourRemainingSeconds ?? progress.remainingSeconds,
                        windowStats: progress.windowStats
                    )
                },
                sevenDay: source.usage.sevenDay.map { progress in
                    UsageProgress(
                        utilization: progress.utilization,
                        resetsAt: progress.resetsAt,
                        remainingSeconds: sevenDayRemainingSeconds ?? progress.remainingSeconds,
                        windowStats: progress.windowStats
                    )
                },
                quotaAutoPaused: source.usage.quotaAutoPaused
            )
        )
    }

    private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { value, byteOffset in
            value | (UInt32(bytes[offset + byteOffset]) << UInt32(byteOffset * 8))
        }
    }

    private func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { value, byteOffset in
            value | (UInt64(bytes[offset + byteOffset]) << UInt64(byteOffset * 8))
        }
    }
}

private extension Data {
    var bytes: [UInt8] { Array(self) }
}

private final class HardwareMonitorMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var tokens = StoredAuthTokens()

    func loadTokens() -> StoredAuthTokens {
        tokens
    }

    func saveTokens(_ tokens: StoredAuthTokens) throws {
        self.tokens = tokens
    }
}
