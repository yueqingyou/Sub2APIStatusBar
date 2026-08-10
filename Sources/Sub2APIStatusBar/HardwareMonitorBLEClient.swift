import CoreBluetooth
import Foundation
import Network
import Sub2APIStatusCore

enum HardwareMonitorBLEConnectionState: Equatable {
    case disabled
    case waitingForBluetooth
    case scanning
    case scheduledSleep(wakeMinute: Int)
    case connecting(deviceName: String)
    case connected(deviceName: String)
    case ready(deviceName: String, firmwareVersion: String)
    case firmwareUpdateOnly(deviceName: String, firmwareVersion: String, protocolVersion: UInt8)
    case unavailable(detail: String)
    case failed(detail: String)
}

enum HardwareFirmwareUpdateState: Equatable {
    case unavailable(detail: String)
    case waitingForDevice(targetVersion: String)
    case available(currentVersion: String, targetVersion: String)
    case upToDate(version: String)
    case preparing(targetVersion: String)
    case transferring(targetVersion: String, progressPercent: Int)
    case verifying(targetVersion: String)
    case restarting(targetVersion: String)
    case completed(version: String)
    case failed(detail: String)

    var isInProgress: Bool {
        switch self {
        case .preparing, .transferring, .verifying, .restarting:
            return true
        default:
            return false
        }
    }
}

final class HardwareMonitorBLEClient: NSObject {
    var onStateChange: ((HardwareMonitorBLEConnectionState) -> Void)?
    var onFirmwareUpdateStateChange: ((HardwareFirmwareUpdateState) -> Void)?

    private enum WriteKind: Equatable {
        case hello
        case powerSchedule
        case heartbeat(HardwareMonitorPage)
        case page(HardwareMonitorPage)
        case firmwareStart
        case firmwareChunk(endOffset: Int)
        case firmwareFinish
    }

    private enum WriteDestination: Equatable {
        case command
        case firmwareData
    }

    private struct PendingWrite {
        let kind: WriteKind
        let data: Data
        let destination: WriteDestination
    }

    private struct DeviceNightSleepState {
        let enabled: Bool
        let clockSynchronized: Bool
        let manualOverride: Bool
        let startMinute: Int
        let endMinute: Int

        func isWindowActive(at date: Date) -> Bool {
            guard clockSynchronized, !manualOverride else {
                return false
            }
            return HardwareMonitorSyncSettings(
                nightSleepEnabled: enabled,
                nightSleepStartMinute: startMinute,
                nightSleepEndMinute: endMinute
            ).isNightSleepWindowActive(at: date)
        }
    }

    private let serviceUUID = CBUUID(string: HardwareMonitorBLEProtocol.serviceUUIDString)
    private let commandCharacteristicUUID = CBUUID(string: HardwareMonitorBLEProtocol.commandCharacteristicUUIDString)
    private let statusCharacteristicUUID = CBUUID(string: HardwareMonitorBLEProtocol.statusCharacteristicUUIDString)
    private let firmwareDataCharacteristicUUID = CBUUID(
        string: HardwareFirmwareUpdateProtocol.dataCharacteristicUUIDString
    )
    private let networkMonitorQueue = DispatchQueue(
        label: "sub2api-statusbar.hardware-monitor-network",
        qos: .utility
    )
    private let powerScheduleResyncInterval: TimeInterval = 3_600

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var firmwareDataCharacteristic: CBCharacteristic?
    private var reconnectWorkItem: DispatchWorkItem?
    private var firmwareUpdateTimeoutWorkItem: DispatchWorkItem?
    private var syncTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var isRunning = false
    private var securityProbeStarted = false
    private var notificationRequested = false
    private var helloWriteStarted = false
    private var isHandshakeReady = false
    private var state: HardwareMonitorBLEConnectionState = .disabled
    private var firmwareUpdateState: HardwareFirmwareUpdateState = .unavailable(
        detail: "The bundled hardware firmware has not been loaded."
    )
    private var networkAvailable = false
    private var latestSnapshot: MonitorSnapshot?
    private var syncSettings = HardwareMonitorSyncSettings()
    private var payloads: HardwareMonitorBLEPayloadSet?
    private var currentPage = HardwareMonitorPage.overview
    private var lastPageSentAt: [HardwareMonitorPage: Date] = [:]
    private var lastSignalSentAt: Date?
    private var lastPowerScheduleSentAt: Date?
    private var pendingWrites: [PendingWrite] = []
    private var writeInFlight: PendingWrite?
    private var firmwarePackage: HardwareFirmwarePackage?
    private var firmwarePackageLoadAttempted = false
    private var latestDeviceStatus: HardwareMonitorBLEDeviceStatus?
    private var activeFirmwarePackage: HardwareFirmwarePackage?
    private var firmwareBytesSent = 0
    private var lastFirmwareProgress = -1
    private var awaitingFirmwareRestart = false
    private var firmwareRestartDisconnectObserved = false
    private var lastKnownDeviceNightSleepState: DeviceNightSleepState?

    func start() {
        guard !isRunning else {
            return
        }
        trace("client_start")
        isRunning = true
        loadFirmwarePackageIfNeeded()
        publish(.waitingForBluetooth)
        startNetworkMonitor()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.performSync()
        }
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func stop() {
        trace("client_stop")
        isRunning = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        firmwareUpdateTimeoutWorkItem?.cancel()
        firmwareUpdateTimeoutWorkItem = nil
        syncTimer?.invalidate()
        syncTimer = nil
        networkMonitor?.cancel()
        networkMonitor = nil
        centralManager?.stopScan()
        if let peripheral {
            peripheral.delegate = nil
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        centralManager?.delegate = nil
        centralManager = nil
        resetPeripheral()
        activeFirmwarePackage = nil
        awaitingFirmwareRestart = false
        firmwareRestartDisconnectObserved = false
        publish(.disabled)
        if let firmwarePackage {
            publishFirmwareUpdate(.waitingForDevice(targetVersion: firmwarePackage.version.description))
        }
    }

    func update(snapshot: MonitorSnapshot, syncSettings: HardwareMonitorSyncSettings) {
        let pagesThatBecameAvailable = HardwareMonitorPage.allCases.filter { page in
            guard let latestSnapshot else {
                return false
            }
            return !HardwareMonitorBLEProtocol.isPageDataAvailable(in: latestSnapshot, for: page)
                && HardwareMonitorBLEProtocol.isPageDataAvailable(in: snapshot, for: page)
        }
        latestSnapshot = snapshot
        var normalizedSettings = syncSettings
        normalizedSettings.normalize()
        let settingsChanged = self.syncSettings != normalizedSettings
        self.syncSettings = normalizedSettings
        for page in pagesThatBecameAvailable {
            lastPageSentAt.removeValue(forKey: page)
        }
        rebuildPayloads()
        if settingsChanged, isHandshakeReady {
            lastPowerScheduleSentAt = nil
        }
        performSync()
    }

    func installBundledFirmware() {
        guard isRunning else {
            publishFirmwareUpdate(.failed(detail: "Enable the hardware monitor before updating firmware."))
            return
        }
        guard !firmwareUpdateState.isInProgress else {
            return
        }
        guard let firmwarePackage else {
            publishFirmwareUpdate(.failed(detail: "The bundled hardware firmware is unavailable."))
            return
        }
        guard let status = latestDeviceStatus,
              status.isLinkConnected,
              status.isLinkEncrypted,
              status.isBonded else {
            publishFirmwareUpdate(.failed(detail: "Connect the bonded hardware monitor before updating firmware."))
            return
        }
        guard status.supportsFirmwareUpdate, firmwareDataCharacteristic != nil else {
            publishFirmwareUpdate(.failed(detail: "This device requires the one-time USB firmware setup."))
            return
        }
        guard status.parsedFirmwareVersion <= firmwarePackage.version else {
            publishFirmwareUpdate(.failed(detail: "The bundled firmware is older than the device firmware."))
            return
        }

        activeFirmwarePackage = firmwarePackage
        firmwareBytesSent = 0
        lastFirmwareProgress = -1
        awaitingFirmwareRestart = false
        firmwareRestartDisconnectObserved = false
        pendingWrites.removeAll()
        publishFirmwareUpdate(.preparing(targetVersion: firmwarePackage.version.description))
        enqueue(PendingWrite(
            kind: .firmwareStart,
            data: HardwareFirmwareUpdateProtocol.startPayload(for: firmwarePackage),
            destination: .command
        ))
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning else {
                    return
                }
                let available = path.status == .satisfied
                guard available != self.networkAvailable else {
                    return
                }
                self.networkAvailable = available
                self.rebuildPayloads()
                self.lastSignalSentAt = nil
                self.performSync()
            }
        }
        networkMonitor = monitor
        monitor.start(queue: networkMonitorQueue)
    }

    private func rebuildPayloads() {
        guard let latestSnapshot else {
            payloads = nil
            return
        }
        payloads = HardwareMonitorBLEProtocol.payloads(
            snapshot: latestSnapshot,
            networkAvailable: networkAvailable,
            syncSettings: syncSettings
        )
    }

    private func loadFirmwarePackageIfNeeded() {
        guard !firmwarePackageLoadAttempted else {
            return
        }
        firmwarePackageLoadAttempted = true
        do {
            let package = try HardwareFirmwarePackageLoader().loadBundled()
            firmwarePackage = package
            publishFirmwareUpdate(.waitingForDevice(targetVersion: package.version.description))
        } catch {
            publishFirmwareUpdate(.unavailable(detail: error.localizedDescription))
        }
    }

    private func performSync(now: Date = Date()) {
        refreshScheduledSleepPresentation(at: now)
        guard isRunning,
              isHandshakeReady,
              !firmwareUpdateState.isInProgress else {
            return
        }

        let isPowerScheduleDue = lastPowerScheduleSentAt.map {
            now.timeIntervalSince($0) >= powerScheduleResyncInterval
        } ?? true
        if isPowerScheduleDue {
            enqueuePowerSchedule(at: now)
            return
        }

        guard let payloads else {
            return
        }
        let pageInterval = syncSettings.interval(for: currentPage)
        let isPageDue = lastPageSentAt[currentPage].map {
            now.timeIntervalSince($0) >= pageInterval
        } ?? true
        if isPageDue, let pagePayload = payloads.pages[currentPage] {
            enqueue(PendingWrite(kind: .page(currentPage), data: pagePayload, destination: .command))
            return
        }

        guard let offlineCheckInterval = syncSettings.offlineCheckIntervalSeconds else {
            return
        }
        let isHeartbeatDue = lastSignalSentAt.map {
            now.timeIntervalSince($0) >= offlineCheckInterval
        } ?? true
        if isHeartbeatDue, let heartbeat = payloads.heartbeats[currentPage] {
            enqueue(PendingWrite(kind: .heartbeat(currentPage), data: heartbeat, destination: .command))
        }
    }

    private func enqueuePowerSchedule(at date: Date) {
        // 入队即开始节流，避免连续状态通知重复排队同一份计划。
        lastPowerScheduleSentAt = date
        enqueue(PendingWrite(
            kind: .powerSchedule,
            data: HardwareMonitorBLEProtocol.powerSchedulePayload(
                syncSettings: syncSettings,
                at: date
            ),
            destination: .command
        ))
    }

    private func enqueueCurrentPageState(now: Date = Date(), heartbeatWhenFresh: Bool) {
        guard let payloads else {
            return
        }
        let pageInterval = syncSettings.interval(for: currentPage)
        let isPageDue = lastPageSentAt[currentPage].map {
            now.timeIntervalSince($0) >= pageInterval
        } ?? true
        if isPageDue, let pagePayload = payloads.pages[currentPage] {
            enqueue(PendingWrite(kind: .page(currentPage), data: pagePayload, destination: .command))
        } else if heartbeatWhenFresh, let heartbeat = payloads.heartbeats[currentPage] {
            enqueue(PendingWrite(kind: .heartbeat(currentPage), data: heartbeat, destination: .command))
        }
    }

    private func enqueue(_ write: PendingWrite) {
        if let pendingIndex = pendingWrites.firstIndex(where: { $0.kind == write.kind }) {
            pendingWrites[pendingIndex] = write
            return
        }
        if writeInFlight?.kind == write.kind,
           writeInFlight?.data == write.data {
            return
        }
        pendingWrites.append(write)
        sendNextWriteIfPossible()
    }

    private func sendNextWriteIfPossible() {
        guard isRunning,
              writeInFlight == nil,
              !pendingWrites.isEmpty,
              let peripheral,
              peripheral.state == .connected else {
            return
        }
        let write = pendingWrites[0]
        let characteristic: CBCharacteristic?
        switch write.destination {
        case .command:
            characteristic = commandCharacteristic
        case .firmwareData:
            characteristic = firmwareDataCharacteristic
        }
        guard let characteristic else {
            return
        }
        pendingWrites.removeFirst()
        writeInFlight = write
        if isFirmwareWrite(write.kind) {
            scheduleFirmwareUpdateTimeout(seconds: 20)
        }
        peripheral.writeValue(write.data, for: characteristic, type: .withResponse)
    }

    private func enqueueNextFirmwareChunk() {
        guard let package = activeFirmwarePackage,
              let peripheral else {
            failFirmwareUpdate("The firmware update session is unavailable.")
            return
        }
        guard firmwareBytesSent < package.image.count else {
            publishFirmwareUpdate(.verifying(targetVersion: package.version.description))
            enqueue(PendingWrite(
                kind: .firmwareFinish,
                data: HardwareFirmwareUpdateProtocol.finishPayload,
                destination: .command
            ))
            return
        }

        let maximumLength = peripheral.maximumWriteValueLength(for: .withResponse)
        let chunkLength = min(240, max(20, maximumLength))
        let endOffset = min(package.image.count, firmwareBytesSent + chunkLength)
        enqueue(PendingWrite(
            kind: .firmwareChunk(endOffset: endOffset),
            data: package.image.subdata(in: firmwareBytesSent..<endOffset),
            destination: .firmwareData
        ))
    }

    private func isFirmwareWrite(_ kind: WriteKind) -> Bool {
        switch kind {
        case .firmwareStart, .firmwareChunk, .firmwareFinish:
            return true
        case .hello, .powerSchedule, .heartbeat, .page:
            return false
        }
    }

    private func scheduleFirmwareUpdateTimeout(seconds: TimeInterval) {
        firmwareUpdateTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.failFirmwareUpdate("The Bluetooth firmware update timed out.")
        }
        firmwareUpdateTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    private func failFirmwareUpdate(_ detail: String, disconnect: Bool = true) {
        firmwareUpdateTimeoutWorkItem?.cancel()
        firmwareUpdateTimeoutWorkItem = nil
        pendingWrites.removeAll { isFirmwareWrite($0.kind) }
        if let writeInFlight, isFirmwareWrite(writeInFlight.kind) {
            self.writeInFlight = nil
        }
        activeFirmwarePackage = nil
        awaitingFirmwareRestart = false
        firmwareRestartDisconnectObserved = false
        publishFirmwareUpdate(.failed(detail: detail))
        if disconnect, let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }

    private func beginScan(after delay: TimeInterval = 0) {
        reconnectWorkItem?.cancel()
        trace("scan_scheduled", "delay_seconds=\(delay)")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isRunning,
                  self.centralManager?.state == .poweredOn else {
                return
            }
            self.resetPeripheral()
            self.publishScanState(at: Date())
            self.trace("scan_started")
            self.centralManager?.scanForPeripherals(
                withServices: [self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func resetPeripheral() {
        peripheral?.delegate = nil
        peripheral = nil
        commandCharacteristic = nil
        statusCharacteristic = nil
        firmwareDataCharacteristic = nil
        securityProbeStarted = false
        notificationRequested = false
        helloWriteStarted = false
        isHandshakeReady = false
        pendingWrites.removeAll()
        writeInFlight = nil
        lastPageSentAt.removeAll()
        lastSignalSentAt = nil
        lastPowerScheduleSentAt = nil
        latestDeviceStatus = nil
    }

    private func deviceName(for peripheral: CBPeripheral) -> String {
        let trimmed = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "TokenRouter Monitor" : trimmed
    }

    private func fail(_ detail: String, disconnect: Bool = true) {
        trace("client_failure", "disconnect=\(disconnect) detail=\(detail)")
        publish(.failed(detail: detail))
        if disconnect, let peripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        } else {
            beginScan(after: 2)
        }
    }

    private func startSecurityProbeIfReady() {
        guard isRunning,
              !securityProbeStarted,
              let peripheral,
              let statusCharacteristic else {
            return
        }
        securityProbeStarted = true
        publish(.connected(deviceName: deviceName(for: peripheral)))
        peripheral.readValue(for: statusCharacteristic)
    }

    private func publish(_ next: HardwareMonitorBLEConnectionState) {
        guard next != state else {
            return
        }
        state = next
        trace("connection_state", String(describing: next))
        onStateChange?(next)
    }

    private func trace(_ event: String, _ detail: String = "") {
        guard let path = ProcessInfo.processInfo.environment["SUB2API_HARDWARE_BLE_TRACE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return
        }
        let sanitize: (String) -> String = { value in
            value.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
        let suffix = detail.isEmpty ? "" : "\t\(sanitize(detail))"
        guard let data = "\(timestamp)\t\(sanitize(event))\(suffix)\n".data(using: .utf8) else {
            return
        }
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: path) {
                try data.write(to: url, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            fputs("Hardware monitor BLE trace failed: \(error)\n", stderr)
        }
    }

    private func publishScanState(at date: Date) {
        if let lastKnownDeviceNightSleepState {
            if lastKnownDeviceNightSleepState.isWindowActive(at: date) {
                publish(.scheduledSleep(wakeMinute: lastKnownDeviceNightSleepState.endMinute))
            } else {
                publish(.scanning)
            }
        } else if syncSettings.isNightSleepWindowActive(at: date) {
            publish(.scheduledSleep(wakeMinute: syncSettings.nightSleepEndMinute))
        } else {
            publish(.scanning)
        }
    }

    private func rememberDeviceNightSleepState(_ status: HardwareMonitorBLEDeviceStatus) {
        guard let enabled = status.nightSleepEnabled,
              let clockSynchronized = status.nightSleepClockSynchronized,
              let manualOverride = status.nightSleepManualOverride,
              let startMinute = status.nightSleepStartMinute,
              let endMinute = status.nightSleepEndMinute else {
            return
        }
        let validatedStartMinute = Int(startMinute)
        let validatedEndMinute = Int(endMinute)
        guard HardwareMonitorSyncSettings.nightSleepMinuteRange.contains(validatedStartMinute),
              HardwareMonitorSyncSettings.nightSleepMinuteRange.contains(validatedEndMinute),
              validatedStartMinute != validatedEndMinute else {
            return
        }
        lastKnownDeviceNightSleepState = DeviceNightSleepState(
            enabled: enabled,
            clockSynchronized: clockSynchronized,
            manualOverride: manualOverride,
            startMinute: validatedStartMinute,
            endMinute: validatedEndMinute
        )
    }

    private func refreshScheduledSleepPresentation(at date: Date) {
        switch state {
        case .scanning, .scheduledSleep:
            publishScanState(at: date)
        default:
            break
        }
    }

    private func publishFirmwareUpdate(_ next: HardwareFirmwareUpdateState) {
        guard next != firmwareUpdateState else {
            return
        }
        firmwareUpdateState = next
        trace("firmware_update_state", String(describing: next))
        onFirmwareUpdateStateChange?(next)
    }

    private func refreshFirmwareUpdateState(for status: HardwareMonitorBLEDeviceStatus) {
        if let activeFirmwarePackage, awaitingFirmwareRestart {
            guard firmwareRestartDisconnectObserved else {
                return
            }
            firmwareUpdateTimeoutWorkItem?.cancel()
            firmwareUpdateTimeoutWorkItem = nil
            self.activeFirmwarePackage = nil
            awaitingFirmwareRestart = false
            firmwareRestartDisconnectObserved = false
            if status.parsedFirmwareVersion == activeFirmwarePackage.version {
                publishFirmwareUpdate(.completed(version: status.firmwareVersion))
            } else {
                publishFirmwareUpdate(.failed(
                    detail: "The device restarted with firmware \(status.firmwareVersion); the update was rolled back."
                ))
            }
            return
        }

        if activeFirmwarePackage != nil {
            if status.firmwareUpdateState == .failed {
                failFirmwareUpdate(
                    "The device rejected the firmware update (error \(status.firmwareUpdateErrorCode ?? 0)).",
                    disconnect: false
                )
            }
            return
        }

        guard let firmwarePackage else {
            return
        }
        if case let .completed(version) = firmwareUpdateState,
           version == status.firmwareVersion {
            return
        }
        if case .failed = firmwareUpdateState {
            return
        }
        guard status.supportsFirmwareUpdate, firmwareDataCharacteristic != nil else {
            publishFirmwareUpdate(.unavailable(
                detail: "This device requires the one-time USB firmware setup."
            ))
            return
        }
        if firmwarePackage.version > status.parsedFirmwareVersion {
            publishFirmwareUpdate(.available(
                currentVersion: status.firmwareVersion,
                targetVersion: firmwarePackage.version.description
            ))
        } else {
            publishFirmwareUpdate(.upToDate(version: status.firmwareVersion))
        }
    }
}

extension HardwareMonitorBLEClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isRunning else {
            return
        }
        trace("central_state", "raw_value=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            beginScan()
        case .poweredOff:
            publish(.unavailable(detail: "Bluetooth is turned off."))
        case .unauthorized:
            publish(.unavailable(detail: "Bluetooth permission was not granted."))
        case .unsupported:
            publish(.unavailable(detail: "Bluetooth Low Energy is not supported on this Mac."))
        case .resetting:
            publish(.waitingForBluetooth)
        case .unknown:
            publish(.waitingForBluetooth)
        @unknown default:
            publish(.unavailable(detail: "Bluetooth is unavailable."))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isRunning, self.peripheral == nil else {
            return
        }
        trace("device_discovered", "rssi=\(RSSI)")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = advertisedName?.isEmpty == false ? advertisedName! : deviceName(for: peripheral)
        publish(.connecting(deviceName: name))
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isRunning, peripheral === self.peripheral else {
            return
        }
        trace("device_connected")
        publish(.connected(deviceName: deviceName(for: peripheral)))
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else {
            return
        }
        let detail = error?.localizedDescription ?? "Could not connect to the hardware monitor."
        trace("device_connect_failed", detail)
        resetPeripheral()
        if awaitingFirmwareRestart {
            beginScan(after: 1)
            return
        }
        fail(detail, disconnect: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else {
            return
        }
        let updateWasInProgress = firmwareUpdateState.isInProgress
        let wasAwaitingFirmwareRestart = awaitingFirmwareRestart
        trace(
            "device_disconnected",
            "update_in_progress=\(updateWasInProgress) awaiting_restart=\(wasAwaitingFirmwareRestart) error=\(error?.localizedDescription ?? "none")"
        )
        resetPeripheral()
        guard isRunning else {
            return
        }
        if wasAwaitingFirmwareRestart {
            firmwareRestartDisconnectObserved = true
            beginScan(after: 1)
            return
        }
        if updateWasInProgress {
            failFirmwareUpdate("The Bluetooth connection was lost during the firmware update.", disconnect: false)
        }
        if let error {
            publish(.failed(detail: error.localizedDescription))
        }
        beginScan(after: 1)
    }
}

extension HardwareMonitorBLEClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard isRunning,
              peripheral === self.peripheral,
              invalidatedServices.contains(where: { $0.uuid == serviceUUID }) else {
            return
        }
        guard !firmwareUpdateState.isInProgress else {
            failFirmwareUpdate("The hardware monitor service changed during the firmware update.")
            return
        }
        trace("service_invalidated")
        commandCharacteristic = nil
        statusCharacteristic = nil
        firmwareDataCharacteristic = nil
        securityProbeStarted = false
        notificationRequested = false
        helloWriteStarted = false
        isHandshakeReady = false
        pendingWrites.removeAll()
        writeInFlight = nil
        latestDeviceStatus = nil
        publish(.connected(deviceName: deviceName(for: peripheral)))
        peripheral.discoverServices([serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isRunning, peripheral === self.peripheral else {
            return
        }
        if let error {
            fail("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            fail("Hardware monitor BLE service was not found.")
            return
        }
        trace("service_discovered")
        peripheral.discoverCharacteristics(
            [commandCharacteristicUUID, statusCharacteristicUUID, firmwareDataCharacteristicUUID],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isRunning, peripheral === self.peripheral else {
            return
        }
        if let error {
            fail("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        commandCharacteristic = service.characteristics?.first(where: { $0.uuid == commandCharacteristicUUID })
        statusCharacteristic = service.characteristics?.first(where: { $0.uuid == statusCharacteristicUUID })
        firmwareDataCharacteristic = service.characteristics?.first(where: {
            $0.uuid == firmwareDataCharacteristicUUID
        })
        guard commandCharacteristic != nil, statusCharacteristic != nil else {
            fail("Hardware monitor BLE characteristics were not found.")
            return
        }
        trace(
            "characteristics_discovered",
            "firmware_data=\(firmwareDataCharacteristic != nil)"
        )
        startSecurityProbeIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isRunning,
              peripheral === self.peripheral,
              characteristic.uuid == statusCharacteristicUUID else {
            return
        }
        if let error {
            fail("Notification subscription failed: \(error.localizedDescription)")
            return
        }
        notificationRequested = false
        trace("notification_state", "enabled=\(characteristic.isNotifying)")
        if characteristic.isNotifying {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isRunning,
              peripheral === self.peripheral,
              let completedWrite = writeInFlight else {
            return
        }
        let expectedUUID = completedWrite.destination == .command
            ? commandCharacteristicUUID
            : firmwareDataCharacteristicUUID
        guard characteristic.uuid == expectedUUID else {
            return
        }
        writeInFlight = nil
        if isFirmwareWrite(completedWrite.kind) {
            firmwareUpdateTimeoutWorkItem?.cancel()
            firmwareUpdateTimeoutWorkItem = nil
        }
        if let error {
            trace("write_failed", "kind=\(String(describing: completedWrite.kind)) detail=\(error.localizedDescription)")
            if isFirmwareWrite(completedWrite.kind) {
                failFirmwareUpdate("Firmware transfer failed: \(error.localizedDescription)")
            } else {
                fail("Secure hardware monitor write failed: \(error.localizedDescription)")
            }
            return
        }

        switch completedWrite.kind {
        case .hello, .powerSchedule, .firmwareStart, .firmwareFinish:
            trace("write_completed", "kind=\(String(describing: completedWrite.kind))")
        case .firmwareChunk, .heartbeat, .page:
            break
        }

        let completedAt = Date()
        switch completedWrite.kind {
        case .hello:
            if let statusCharacteristic {
                peripheral.readValue(for: statusCharacteristic)
            }
        case .powerSchedule:
            lastPowerScheduleSentAt = completedAt
            if let statusCharacteristic {
                peripheral.readValue(for: statusCharacteristic)
            }
            enqueueCurrentPageState(heartbeatWhenFresh: true)
        case .heartbeat:
            lastSignalSentAt = completedAt
        case let .page(page):
            if payloads?.pages[page] == completedWrite.data {
                lastPageSentAt[page] = completedAt
            } else {
                lastPageSentAt.removeValue(forKey: page)
            }
            lastSignalSentAt = completedAt
        case .firmwareStart:
            guard let activeFirmwarePackage else {
                failFirmwareUpdate("The firmware update session ended unexpectedly.")
                return
            }
            publishFirmwareUpdate(.transferring(
                targetVersion: activeFirmwarePackage.version.description,
                progressPercent: 0
            ))
            enqueueNextFirmwareChunk()
        case let .firmwareChunk(endOffset):
            guard let activeFirmwarePackage else {
                failFirmwareUpdate("The firmware update session ended unexpectedly.")
                return
            }
            firmwareBytesSent = endOffset
            let progress = min(100, firmwareBytesSent * 100 / activeFirmwarePackage.image.count)
            if progress != lastFirmwareProgress {
                lastFirmwareProgress = progress
                publishFirmwareUpdate(.transferring(
                    targetVersion: activeFirmwarePackage.version.description,
                    progressPercent: progress
                ))
            }
            enqueueNextFirmwareChunk()
        case .firmwareFinish:
            guard let activeFirmwarePackage else {
                failFirmwareUpdate("The firmware update session ended unexpectedly.")
                return
            }
            awaitingFirmwareRestart = true
            firmwareRestartDisconnectObserved = false
            publishFirmwareUpdate(.restarting(targetVersion: activeFirmwarePackage.version.description))
            scheduleFirmwareUpdateTimeout(seconds: 45)
        }
        sendNextWriteIfPossible()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isRunning,
              peripheral === self.peripheral,
              characteristic.uuid == statusCharacteristicUUID else {
            return
        }
        if let error {
            fail("Secure status read failed: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else {
            fail("Hardware monitor returned an empty BLE status.")
            return
        }
        do {
            let status = try HardwareMonitorBLEProtocol.decodeStatus(data)
            trace(
                "device_status",
                "firmware=\(status.firmwareVersion) protocol=\(status.protocolVersion) link=\(status.isLinkConnected) encrypted=\(status.isLinkEncrypted) bonded=\(status.isBonded) handshake=\(status.isHandshakeReady) wake=\(status.nightSleepLastWakeReason.map(String.init(describing:)) ?? "unavailable") rtc_fallback=\(status.nightSleepRTCFallbackActive.map(String.init(describing:)) ?? "unavailable") boot_parity=\(status.nightSleepBootSequenceParity.map(String.init(describing:)) ?? "unavailable")"
            )
            latestDeviceStatus = status
            rememberDeviceNightSleepState(status)
            let pageChanged = currentPage != status.currentPage
            currentPage = status.currentPage
            let name = deviceName(for: peripheral)
            guard status.isLinkConnected else {
                isHandshakeReady = false
                publish(.connected(deviceName: name))
                return
            }
            guard status.isLinkEncrypted, status.isBonded else {
                isHandshakeReady = false
                publish(.connected(deviceName: name))
                return
            }

            refreshFirmwareUpdateState(for: status)

            guard let statusCharacteristic else {
                fail("Hardware monitor status characteristic is unavailable.")
                return
            }
            if !statusCharacteristic.isNotifying {
                if !notificationRequested {
                    notificationRequested = true
                    peripheral.setNotifyValue(true, for: statusCharacteristic)
                }
                return
            }

            guard status.isMonitorProtocolCompatible else {
                isHandshakeReady = false
                publish(.firmwareUpdateOnly(
                    deviceName: name,
                    firmwareVersion: status.firmwareVersion,
                    protocolVersion: status.protocolVersion
                ))
                return
            }

            if status.isHandshakeReady {
                isHandshakeReady = true
                publish(.ready(deviceName: name, firmwareVersion: status.firmwareVersion))
                if pageChanged, lastPowerScheduleSentAt != nil {
                    enqueueCurrentPageState(heartbeatWhenFresh: true)
                }
                performSync()
            } else {
                isHandshakeReady = false
                publish(.connected(deviceName: name))
                if !helloWriteStarted {
                    helloWriteStarted = true
                    enqueue(PendingWrite(
                        kind: .hello,
                        data: HardwareMonitorBLEProtocol.helloPayload,
                        destination: .command
                    ))
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }
}
