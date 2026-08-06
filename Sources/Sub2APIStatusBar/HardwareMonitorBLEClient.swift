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
    case unavailable(detail: String)
    case failed(detail: String)
}

final class HardwareMonitorBLEClient: NSObject {
    var onStateChange: ((HardwareMonitorBLEConnectionState) -> Void)?

    private enum WriteKind: Equatable {
        case hello
        case heartbeat(HardwareMonitorPage)
        case page(HardwareMonitorPage)
    }

    private struct PendingWrite {
        let kind: WriteKind
        let data: Data
    }

    private let serviceUUID = CBUUID(string: HardwareMonitorBLEProtocol.serviceUUIDString)
    private let commandCharacteristicUUID = CBUUID(string: HardwareMonitorBLEProtocol.commandCharacteristicUUIDString)
    private let statusCharacteristicUUID = CBUUID(string: HardwareMonitorBLEProtocol.statusCharacteristicUUIDString)
    private let networkMonitorQueue = DispatchQueue(
        label: "sub2api-statusbar.hardware-monitor-network",
        qos: .utility
    )

    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var reconnectWorkItem: DispatchWorkItem?
    private var syncTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var isRunning = false
    private var securityProbeStarted = false
    private var notificationRequested = false
    private var helloWriteStarted = false
    private var isHandshakeReady = false
    private var state: HardwareMonitorBLEConnectionState = .disabled
    private var networkAvailable = false
    private var latestSnapshot: MonitorSnapshot?
    private var syncSettings = HardwareMonitorSyncSettings()
    private var payloads: HardwareMonitorBLEPayloadSet?
    private var currentPage = HardwareMonitorPage.overview
    private var lastPageSentAt: [HardwareMonitorPage: Date] = [:]
    private var lastSignalSentAt: Date?
    private var pendingWrites: [PendingWrite] = []
    private var writeInFlight: PendingWrite?

    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
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
        publish(.disabled)
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

    private func performSync(now: Date = Date()) {
        guard isRunning, isHandshakeReady, let payloads else {
            return
        }

        let pageInterval = syncSettings.interval(for: currentPage)
        let isPageDue = lastPageSentAt[currentPage].map {
            now.timeIntervalSince($0) >= pageInterval
        } ?? true
        if isPageDue, let pagePayload = payloads.pages[currentPage] {
            enqueue(PendingWrite(kind: .page(currentPage), data: pagePayload))
            return
        }

        guard let offlineCheckInterval = syncSettings.offlineCheckIntervalSeconds else {
            return
        }
        let isHeartbeatDue = lastSignalSentAt.map {
            now.timeIntervalSince($0) >= offlineCheckInterval
        } ?? true
        if isHeartbeatDue, let heartbeat = payloads.heartbeats[currentPage] {
            enqueue(PendingWrite(kind: .heartbeat(currentPage), data: heartbeat))
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
            enqueue(PendingWrite(kind: .page(currentPage), data: pagePayload))
        } else if heartbeatWhenFresh, let heartbeat = payloads.heartbeats[currentPage] {
            enqueue(PendingWrite(kind: .heartbeat(currentPage), data: heartbeat))
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
              peripheral.state == .connected,
              let commandCharacteristic else {
            return
        }
        let write = pendingWrites.removeFirst()
        writeInFlight = write
        peripheral.writeValue(write.data, for: commandCharacteristic, type: .withResponse)
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
        securityProbeStarted = false
        notificationRequested = false
        helloWriteStarted = false
        isHandshakeReady = false
        pendingWrites.removeAll()
        writeInFlight = nil
        lastPageSentAt.removeAll()
        lastSignalSentAt = nil
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
        fail(detail, disconnect: false)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else {
            return
        }
        resetPeripheral()
        guard isRunning else {
            return
        }
        if let error {
            publish(.failed(detail: error.localizedDescription))
        }
        beginScan(after: 1)
    }
}

extension HardwareMonitorBLEClient: CBPeripheralDelegate {
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
            [commandCharacteristicUUID, statusCharacteristicUUID],
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
              characteristic.uuid == commandCharacteristicUUID,
              let completedWrite = writeInFlight else {
            return
        }
        writeInFlight = nil
        if let error {
            fail("Secure hardware monitor write failed: \(error.localizedDescription)")
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
            let pageChanged = currentPage != status.currentPage
            currentPage = status.currentPage
            let name = deviceName(for: peripheral)
            if status.isLinkConnected, status.isHandshakeReady {
                guard status.isLinkEncrypted, status.isBonded else {
                    fail("Hardware monitor did not establish the required bonded and encrypted link.")
                    return
                }
                isHandshakeReady = true
                publish(.ready(deviceName: name, firmwareVersion: status.firmwareVersion))
                if pageChanged {
                    enqueueCurrentPageState(heartbeatWhenFresh: true)
                }
                performSync()
            } else {
                isHandshakeReady = false
                publish(.connected(deviceName: name))
                if status.isLinkConnected,
                   status.isLinkEncrypted,
                   status.isBonded,
                   let statusCharacteristic {
                    if statusCharacteristic.isNotifying {
                        if !helloWriteStarted {
                            helloWriteStarted = true
                            enqueue(PendingWrite(
                                kind: .hello,
                                data: HardwareMonitorBLEProtocol.helloPayload
                            ))
                        }
                    } else if !notificationRequested {
                        notificationRequested = true
                        peripheral.setNotifyValue(true, for: statusCharacteristic)
                    }
                }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }
}
