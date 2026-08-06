import Foundation

public enum HardwareMonitorPage: UInt8, CaseIterable, Codable, Hashable, Sendable {
    case overview = 0
    case tasks = 1
    case quota = 2
    case device = 3
}

public struct HardwareMonitorSyncSettings: Codable, Equatable, Sendable {
    public static let pageIntervalRange: ClosedRange<Double> = 5...86_400
    public static let offlineCheckIntervalRange: ClosedRange<Double> = 5...300

    public var overviewIntervalSeconds: Double
    public var tasksIntervalSeconds: Double
    public var quotaIntervalSeconds: Double
    public var deviceIntervalSeconds: Double
    public var offlineCheckIntervalSeconds: Double?

    public init(
        overviewIntervalSeconds: Double = 300,
        tasksIntervalSeconds: Double = 300,
        quotaIntervalSeconds: Double = 1_800,
        deviceIntervalSeconds: Double = 900,
        offlineCheckIntervalSeconds: Double? = 30
    ) {
        self.overviewIntervalSeconds = overviewIntervalSeconds
        self.tasksIntervalSeconds = tasksIntervalSeconds
        self.quotaIntervalSeconds = quotaIntervalSeconds
        self.deviceIntervalSeconds = deviceIntervalSeconds
        self.offlineCheckIntervalSeconds = offlineCheckIntervalSeconds
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case overviewIntervalSeconds
        case tasksIntervalSeconds
        case quotaIntervalSeconds
        case deviceIntervalSeconds
        case offlineCheckIntervalSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overviewIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .overviewIntervalSeconds) ?? 300
        tasksIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .tasksIntervalSeconds) ?? 300
        quotaIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .quotaIntervalSeconds) ?? 1_800
        deviceIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .deviceIntervalSeconds) ?? 900
        if container.contains(.offlineCheckIntervalSeconds) {
            offlineCheckIntervalSeconds = try container.decodeIfPresent(
                Double.self,
                forKey: .offlineCheckIntervalSeconds
            )
        } else {
            offlineCheckIntervalSeconds = 30
        }
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(overviewIntervalSeconds, forKey: .overviewIntervalSeconds)
        try container.encode(tasksIntervalSeconds, forKey: .tasksIntervalSeconds)
        try container.encode(quotaIntervalSeconds, forKey: .quotaIntervalSeconds)
        try container.encode(deviceIntervalSeconds, forKey: .deviceIntervalSeconds)
        if let offlineCheckIntervalSeconds {
            try container.encode(offlineCheckIntervalSeconds, forKey: .offlineCheckIntervalSeconds)
        } else {
            try container.encodeNil(forKey: .offlineCheckIntervalSeconds)
        }
    }

    public mutating func normalize() {
        overviewIntervalSeconds = Self.clampPageInterval(overviewIntervalSeconds)
        tasksIntervalSeconds = Self.clampPageInterval(tasksIntervalSeconds)
        quotaIntervalSeconds = Self.clampPageInterval(quotaIntervalSeconds)
        deviceIntervalSeconds = Self.clampPageInterval(deviceIntervalSeconds)
        if let offlineCheckIntervalSeconds {
            self.offlineCheckIntervalSeconds = min(
                max(offlineCheckIntervalSeconds, Self.offlineCheckIntervalRange.lowerBound),
                Self.offlineCheckIntervalRange.upperBound
            )
        }
    }

    public func interval(for page: HardwareMonitorPage) -> TimeInterval {
        switch page {
        case .overview:
            return overviewIntervalSeconds
        case .tasks:
            return tasksIntervalSeconds
        case .quota:
            return quotaIntervalSeconds
        case .device:
            return deviceIntervalSeconds
        }
    }

    public func offlineTimeoutSeconds(for page: HardwareMonitorPage) -> UInt32 {
        let signalInterval = offlineCheckIntervalSeconds ?? interval(for: page)
        let timeout = max(15, signalInterval * 3)
        return UInt32(min(timeout.rounded(.up), Double(UInt32.max)))
    }

    private static func clampPageInterval(_ value: Double) -> Double {
        min(max(value, pageIntervalRange.lowerBound), pageIntervalRange.upperBound)
    }
}

public struct HardwareMonitorBLEPayloadSet: Equatable, Sendable {
    public let heartbeats: [HardwareMonitorPage: Data]
    public let pages: [HardwareMonitorPage: Data]

    public init(heartbeats: [HardwareMonitorPage: Data], pages: [HardwareMonitorPage: Data]) {
        self.heartbeats = heartbeats
        self.pages = pages
    }
}

public enum HardwareMonitorBLEProtocol {
    public static let serviceUUIDString = "BFB75D90-76B2-4BBF-803D-3A8DDE689207"
    public static let commandCharacteristicUUIDString = "EC17F230-4F00-4BFD-903D-66B5EFBB92F0"
    public static let statusCharacteristicUUIDString = "FEE4D514-9AFD-4FBA-9737-D2FD6BDCBF2F"
    public static let protocolVersion: UInt8 = 2
    public static let statusPayloadLength = 9

    public enum MessageType: UInt8, Sendable {
        case hello = 0x01
        case heartbeat = 0x02
        case overview = 0x10
        case tasks = 0x11
        case quota = 0x12
        case device = 0x13
    }

    private static let magic: [UInt8] = [0x54, 0x52, 0x4D]

    public static var helloPayload: Data {
        Data(magic + [protocolVersion, MessageType.hello.rawValue])
    }

    public static func payloads(
        snapshot: MonitorSnapshot,
        networkAvailable: Bool,
        syncSettings: HardwareMonitorSyncSettings
    ) -> HardwareMonitorBLEPayloadSet {
        let flags = commonFlags(snapshot: snapshot, networkAvailable: networkAvailable)
        let common: (HardwareMonitorPage) -> [UInt8] = { page in
            commonPacketPrefix(
                flags: flags,
                timeoutSeconds: syncSettings.offlineTimeoutSeconds(for: page)
            )
        }
        let taskCounts = Dictionary(grouping: snapshot.codexTaskActivities, by: \.status)
            .mapValues(\.count)

        var overview = packetHeader(type: .overview) + common(.overview)
        let stats = snapshot.stats
        overview.append(stats == nil ? 0 : 1)
        appendUInt64(microDollars(stats?.todayActualCost ?? 0), to: &overview)
        appendUInt64(nonnegativeUInt64(stats?.todayRequests ?? 0), to: &overview)
        appendUInt64(nonnegativeUInt64(stats?.todayTokens ?? 0), to: &overview)

        var tasks = packetHeader(type: .tasks) + common(.tasks)
        let recentResultCount = (taskCounts[.done] ?? 0)
            + (taskCounts[.error] ?? 0)
            + (taskCounts[.stale] ?? 0)
        appendUInt16(clampedUInt16(recentResultCount), to: &tasks)
        appendUInt16(clampedUInt16(taskCounts[.done] ?? 0), to: &tasks)
        appendUInt16(clampedUInt16(taskCounts[.error] ?? 0), to: &tasks)
        appendUInt16(clampedUInt16(taskCounts[.stale] ?? 0), to: &tasks)

        let quotaSnapshot = snapshot.openAIQuota
        let quotaSummary = quotaSnapshot?.summary
        let hasFiveHour = quotaSnapshot?.accounts.contains {
            $0.isSchedulable && $0.usage.fiveHour != nil
        } == true
        let hasSevenDay = quotaSnapshot?.accounts.contains {
            $0.isSchedulable && $0.usage.sevenDay != nil
        } == true
        let fiveHourEquivalent = quotaSummary?.capacities.reduce(0) { $0 + $1.fiveHourRemaining } ?? 0
        let sevenDayEquivalent = quotaSummary?.capacities.reduce(0) { $0 + $1.sevenDayRemaining } ?? 0
        var quotaAvailability: UInt8 = 0
        if hasFiveHour { quotaAvailability |= 0x01 }
        if hasSevenDay { quotaAvailability |= 0x02 }
        if snapshot.adminNormalAccountCount != nil { quotaAvailability |= 0x04 }

        var quota = packetHeader(type: .quota) + common(.quota)
        quota.append(quotaAvailability)
        appendUInt32(capacityBasisPoints(fiveHourEquivalent), to: &quota)
        appendUInt32(capacityBasisPoints(sevenDayEquivalent), to: &quota)
        appendUInt32(clampedUInt32(snapshot.adminNormalAccountCount ?? 0), to: &quota)

        let device = Data(packetHeader(type: .device) + common(.device))
        return HardwareMonitorBLEPayloadSet(
            heartbeats: Dictionary(uniqueKeysWithValues: HardwareMonitorPage.allCases.map { page in
                (page, Data(packetHeader(type: .heartbeat) + common(page)))
            }),
            pages: [
                .overview: Data(overview),
                .tasks: Data(tasks),
                .quota: Data(quota),
                .device: device,
            ]
        )
    }

    public static func isPageDataAvailable(
        in snapshot: MonitorSnapshot,
        for page: HardwareMonitorPage
    ) -> Bool {
        switch page {
        case .overview:
            return snapshot.stats != nil
        case .tasks:
            return snapshot.codexTaskActivities.contains {
                $0.status == .done || $0.status == .error || $0.status == .stale
            }
        case .device:
            return true
        case .quota:
            let hasQuotaWindow = snapshot.openAIQuota?.accounts.contains {
                $0.isSchedulable && ($0.usage.fiveHour != nil || $0.usage.sevenDay != nil)
            } == true
            return hasQuotaWindow || snapshot.adminNormalAccountCount != nil
        }
    }

    public static func decodeStatus(_ data: Data) throws -> HardwareMonitorBLEDeviceStatus {
        let bytes = [UInt8](data)
        guard bytes.count == statusPayloadLength else {
            throw HardwareMonitorBLEProtocolError.invalidStatusLength(bytes.count)
        }
        guard Array(bytes.prefix(magic.count)) == magic else {
            throw HardwareMonitorBLEProtocolError.invalidMagic
        }
        guard bytes[3] == protocolVersion else {
            throw HardwareMonitorBLEProtocolError.unsupportedProtocolVersion(bytes[3])
        }
        guard let currentPage = HardwareMonitorPage(rawValue: bytes[8]) else {
            throw HardwareMonitorBLEProtocolError.unsupportedPage(bytes[8])
        }

        return HardwareMonitorBLEDeviceStatus(
            protocolVersion: bytes[3],
            firmwareMajor: bytes[4],
            firmwareMinor: bytes[5],
            firmwarePatch: bytes[6],
            isLinkConnected: bytes[7] & 0x01 != 0,
            isHandshakeReady: bytes[7] & 0x02 != 0,
            isLinkEncrypted: bytes[7] & 0x04 != 0,
            isBonded: bytes[7] & 0x08 != 0,
            isPairingWindowOpen: bytes[7] & 0x10 != 0,
            currentPage: currentPage
        )
    }

    private static func packetHeader(type: MessageType) -> [UInt8] {
        magic + [protocolVersion, type.rawValue]
    }

    private static func commonPacketPrefix(flags: UInt8, timeoutSeconds: UInt32) -> [UInt8] {
        var bytes = [flags]
        appendUInt32(timeoutSeconds, to: &bytes)
        return bytes
    }

    private static func commonFlags(snapshot: MonitorSnapshot, networkAvailable: Bool) -> UInt8 {
        var flags: UInt8 = 0
        if networkAvailable { flags |= 0x01 }
        if snapshot.connected { flags |= 0x02 }
        if snapshot.isStale { flags |= 0x04 }
        if snapshot.mode == .admin { flags |= 0x08 }
        return flags
    }

    private static func microDollars(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else {
            return 0
        }
        let scaled = value * 1_000_000
        guard scaled.isFinite else {
            return UInt64.max
        }
        let rounded = scaled.rounded()
        guard rounded < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(rounded)
    }

    private static func capacityBasisPoints(_ equivalent: Double) -> UInt32 {
        guard equivalent.isFinite, equivalent > 0 else {
            return 0
        }
        let scaled = equivalent * 10_000
        guard scaled.isFinite else {
            return UInt32.max
        }
        return UInt32(min(scaled.rounded(), Double(UInt32.max)))
    }

    private static func nonnegativeUInt64(_ value: Int64) -> UInt64 {
        value > 0 ? UInt64(value) : 0
    }

    private static func clampedUInt16(_ value: Int) -> UInt16 {
        UInt16(min(max(value, 0), Int(UInt16.max)))
    }

    private static func clampedUInt32<T: BinaryInteger>(_ value: T) -> UInt32 {
        guard value > 0 else {
            return 0
        }
        return UInt32(clamping: value)
    }

    private static func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private static func appendUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

public struct HardwareMonitorBLEDeviceStatus: Equatable, Sendable {
    public let protocolVersion: UInt8
    public let firmwareMajor: UInt8
    public let firmwareMinor: UInt8
    public let firmwarePatch: UInt8
    public let isLinkConnected: Bool
    public let isHandshakeReady: Bool
    public let isLinkEncrypted: Bool
    public let isBonded: Bool
    public let isPairingWindowOpen: Bool
    public let currentPage: HardwareMonitorPage

    public var firmwareVersion: String {
        "\(firmwareMajor).\(firmwareMinor).\(firmwarePatch)"
    }
}

public enum HardwareMonitorBLEProtocolError: Error, Equatable, LocalizedError {
    case invalidStatusLength(Int)
    case invalidMagic
    case unsupportedProtocolVersion(UInt8)
    case unsupportedPage(UInt8)

    public var errorDescription: String? {
        switch self {
        case let .invalidStatusLength(length):
            return "Hardware monitor returned an invalid BLE status length: \(length)."
        case .invalidMagic:
            return "Hardware monitor returned an invalid BLE status header."
        case let .unsupportedProtocolVersion(version):
            return "Hardware monitor uses unsupported BLE protocol version \(version)."
        case let .unsupportedPage(page):
            return "Hardware monitor returned unsupported page \(page)."
        }
    }
}
