import CoreBluetooth
import Foundation
import Network
import Sub2APIStatusCore

enum HardwareMonitorBLEConnectionState: Equatable {
    case disabled
    case waitingForBluetooth
    case scanning
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

    func start() {
        guard !isRunning else {
            return
        }
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
            enqueueCurrentPageState(heartbeatWhenFresh: true)
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
        guard isRunning,
              isHandshakeReady,
              !firmwareUpdateState.isInProgress,
              let payloads else {
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
        case .hello, .heartbeat, .page:
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
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isRunning,
                  self.centralManager?.state == .poweredOn else {
                return
            }
            self.resetPeripheral()
            self.publish(.scanning)
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
        latestDeviceStatus = nil
    }

    private func deviceName(for peripheral: CBPeripheral) -> String {
        let trimmed = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "TokenRouter Monitor" : trimmed
    }

    private func fail(_ detail: String, disconnect: Bool = true) {
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
        onStateChange?(next)
    }

    private func publishFirmwareUpdate(_ next: HardwareFirmwareUpdateState) {
        guard next != firmwareUpdateState else {
            return
        }
        firmwareUpdateState = next
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
        publish(.connected(deviceName: deviceName(for: peripheral)))
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else {
            return
        }
        let detail = error?.localizedDescription ?? "Could not connect to the hardware monitor."
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
            if isFirmwareWrite(completedWrite.kind) {
                failFirmwareUpdate("Firmware transfer failed: \(error.localizedDescription)")
            } else {
                fail("Secure hardware monitor write failed: \(error.localizedDescription)")
            }
            return
        }

        let completedAt = Date()
        switch completedWrite.kind {
        case .hello:
            if let statusCharacteristic {
                peripheral.readValue(for: statusCharacteristic)
            }
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
            latestDeviceStatus = status
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
                if pageChanged {
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
