import AFUCore
import CoreBluetooth
import Foundation

@MainActor
final class BluetoothReader: NSObject {
    private let serviceUUID = CBUUID(string: "0000FFB0-0000-1000-8000-00805F9B34FB")
    private let writeUUID = CBUUID(string: "0000FFB1-0000-1000-8000-00805F9B34FB")
    private let notifyUUID = CBUUID(string: "0000FFB2-0000-1000-8000-00805F9B34FB")
    private let handshake = Data([0xFD, 0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x37])

    private let configuration: ReaderConfiguration
    private let measurementStore: MeasurementStore
    private let logger: RotatingFileLogger
    private var sessionTracker: MeasurementSessionTracker
    private var lifecycle = BluetoothLifecycle()
    private var central: CBCentralManager?
    private var activePeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var setupTimeoutTimer: Timer?
    private var retryTimer: Timer?
    private var flushTimer: Timer?
    private var persistenceRetryTimer: Timer?
    private var markdownReconciliationTimer: Timer?
    private var persistenceQueue: [StableMeasurement] = []
    private var handshakeFallbackAttempted = false
    private var shouldRun = false

    init(configuration: ReaderConfiguration, logger: RotatingFileLogger) {
        self.configuration = configuration
        self.logger = logger
        measurementStore = MeasurementStore(configuration: configuration)
        sessionTracker = MeasurementSessionTracker(settleInterval: configuration.settleInterval)
        super.init()
    }

    func start() {
        guard central == nil else { return }
        shouldRun = true
        info("Reader started")
        log("Output file path: \(configuration.outputFileURL.path)")
        reconcileMarkdownOutput()
        scheduleMarkdownReconciliation()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() {
        shouldRun = false
        setupTimeoutTimer?.invalidate()
        retryTimer?.invalidate()
        flushTimer?.invalidate()
        persistenceRetryTimer?.invalidate()
        markdownReconciliationTimer?.invalidate()
        if let activePeripheral {
            central?.cancelPeripheralConnection(activePeripheral)
        }
        central?.stopScan()
    }

    private func startScan() {
        guard shouldRun, let central, central.state == .poweredOn else { return }
        guard lifecycle.shouldScan, activePeripheral == nil, !central.isScanning else { return }
        retryTimer?.invalidate()
        log("Scanning for AFU scale advertisements")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func matchesScale(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> Bool {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        return AFUDeviceMatcher.matches(
            peripheralName: peripheral.name,
            advertisedName: advertisedName,
            requiredPrefix: configuration.deviceNamePrefix
        )
    }

    private func connect(to peripheral: CBPeripheral, name: String) {
        guard let central, activePeripheral == nil else { return }
        central.stopScan()
        activePeripheral = peripheral
        lifecycle.connectionStarted()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        handshakeFallbackAttempted = false
        peripheral.delegate = self
        log("Connecting to matched scale named \(name)")
        central.connect(peripheral, options: nil)
        scheduleSetupTimeout(for: peripheral.identifier)
    }

    private func scheduleSetupTimeout(for identifier: UUID) {
        setupTimeoutTimer?.invalidate()
        setupTimeoutTimer = Timer.scheduledTimer(
            timeInterval: configuration.connectionTimeout,
            target: self,
            selector: #selector(setupTimeoutFired(_:)),
            userInfo: identifier,
            repeats: false
        )
    }

    @objc private func setupTimeoutFired(_ timer: Timer) {
        guard let expectedIdentifier = timer.userInfo as? UUID,
              let activePeripheral,
              activePeripheral.identifier == expectedIdentifier
        else {
            return
        }
        log("Connection/setup timed out for the active peripheral")
        central?.cancelPeripheralConnection(activePeripheral)
    }

    private func scheduleScanRetry() {
        guard shouldRun else { return }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(
            timeInterval: configuration.retryDelay,
            target: self,
            selector: #selector(retryTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func retryTimerFired(_: Timer) {
        startScan()
    }

    private func schedulePendingFlush() {
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(
            timeInterval: configuration.settleInterval,
            target: self,
            selector: #selector(flushTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func flushTimerFired(_: Timer) {
        if let measurement = sessionTracker.flushIfDue(at: Date()) {
            enqueueForPersistence(measurement)
        }
    }

    private func sendHandshake(to peripheral: CBPeripheral) {
        guard let writeCharacteristic else {
            log("FFB1 write characteristic is missing; notifications remain enabled")
            return
        }

        if writeCharacteristic.properties.contains(.write) {
            log("Sending AFU handshake to FFB1 with response")
            peripheral.writeValue(handshake, for: writeCharacteristic, type: .withResponse)
        } else if writeCharacteristic.properties.contains(.writeWithoutResponse) {
            log("Sending AFU handshake to FFB1 without response")
            peripheral.writeValue(handshake, for: writeCharacteristic, type: .withoutResponse)
        } else {
            log("FFB1 does not advertise a supported write property")
        }
    }

    private func handle(_ data: Data, deviceName: String) {
        let receivedAt = Date()
        do {
            let packet = try AFUPacket(data: data)

            if packet.kind == .finalResult || packet.kind == .history {
                flushTimer?.invalidate()
                if packet.kind == .history {
                    info("Historical measurement result received")
                    log(
                        "History result detail remaining_count="
                            + (packet.remainingHistoryCount.map(String.init) ?? "unknown")
                    )
                } else {
                    info("Final measurement result received")
                }
                if let measurement = sessionTracker.receiveFinalResult(
                    packet,
                    at: receivedAt,
                    deviceName: deviceName
                ) {
                    enqueueForPersistence(measurement)
                }
                return
            }

            log(
                String(
                    format: "Packet detail weight_kg=%.2f stable=%@ impedance_raw=%@",
                    packet.weightKilograms,
                    packet.isStable ? "yes" : "no",
                    packet.impedanceRawCode.map(String.init) ?? "none"
                )
            )

            if let measurement = sessionTracker.receive(
                packet,
                at: receivedAt,
                deviceName: deviceName
            ) {
                flushTimer?.invalidate()
                enqueueForPersistence(measurement)
            } else if packet.isStable, packet.impedanceRawCode == nil {
                schedulePendingFlush()
            } else if packet.weightKilograms < 1 {
                flushTimer?.invalidate()
            }
        } catch {
            let hex = data.map { String(format: "%02X", $0) }.joined()
            log("Unsupported notification raw_hex=\(hex); detail=\(error.localizedDescription)")
        }
    }

    private func enqueueForPersistence(_ measurement: StableMeasurement) {
        persistenceQueue.append(measurement)
        drainPersistenceQueue()
    }

    private func drainPersistenceQueue() {
        persistenceRetryTimer?.invalidate()

        while let measurement = persistenceQueue.first {
            let composition: BodyComposition
            do {
                composition = try BodyCompositionCalculator.calculate(
                    weightKilograms: measurement.weightKilograms,
                    impedanceRawCode: measurement.impedanceRawCode,
                    profile: configuration.profile,
                    measuredAt: measurement.measuredAt
                )
            } catch {
                errorEvent("Measurement calculation failed; record dropped")
                log("Measurement calculation detail: \(error.localizedDescription)")
                persistenceQueue.removeFirst()
                continue
            }

            do {
                let appended = try measurementStore.append(
                    MeasurementRecord(measurement: measurement, composition: composition)
                )
                persistenceQueue.removeFirst()
                if appended {
                    info("Stable measurement saved")
                    log(String(format: "Persisted detail weight_kg=%.2f", measurement.weightKilograms))
                } else {
                    info("Duplicate measurement suppressed")
                    log(String(format: "Duplicate detail weight_kg=%.2f", measurement.weightKilograms))
                }
            } catch {
                errorEvent("Measurement write failed; retry scheduled")
                log("Measurement write detail: \(error.localizedDescription)")
                schedulePersistenceRetry()
                return
            }
        }
    }

    private func schedulePersistenceRetry() {
        persistenceRetryTimer?.invalidate()
        persistenceRetryTimer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(persistenceRetryTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func persistenceRetryTimerFired(_: Timer) {
        drainPersistenceQueue()
    }

    private func scheduleMarkdownReconciliation() {
        markdownReconciliationTimer?.invalidate()
        markdownReconciliationTimer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(markdownReconciliationTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func markdownReconciliationTimerFired(_: Timer) {
        reconcileMarkdownOutput()
    }

    private func reconcileMarkdownOutput() {
        do {
            if try measurementStore.restoreOutputFromCanonicalIfNeeded() {
                info("Managed output restored from private mirror")
            }
        } catch {
            errorEvent("Managed output recovery failed; retry scheduled")
            log("Managed output recovery detail: \(error.localizedDescription)")
        }
    }

    private func resetConnectionState() {
        setupTimeoutTimer?.invalidate()
        setupTimeoutTimer = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        activePeripheral = nil
        handshakeFallbackAttempted = false
        lifecycle.connectionEnded()
    }

    private func prepareForUnavailableBluetooth() {
        let hadActivePeripheral = activePeripheral != nil
        retryTimer?.invalidate()
        flushTimer?.invalidate()
        central?.stopScan()
        if let measurement = sessionTracker.disconnect(at: Date()) {
            enqueueForPersistence(measurement)
        }
        lifecycle.bluetoothAvailabilityChanged(to: false)
        resetConnectionState()
        if hadActivePeripheral {
            log("Cleared stale BLE connection state while Bluetooth was unavailable")
        }
    }

    private func info(_ message: String) {
        try? logger.info(message)
    }

    private func errorEvent(_ message: String) {
        try? logger.error(message)
    }

    private func log(_ message: String) {
        try? logger.debug(message)
    }
}

extension BluetoothReader: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            lifecycle.bluetoothAvailabilityChanged(to: true)
            info("Bluetooth is available")
            if lifecycle.consumeCentralRecreationRequest() {
                log("Recreating Bluetooth manager after availability recovery")
                central.stopScan()
                central.delegate = nil
                self.central = CBCentralManager(delegate: self, queue: .main)
                return
            }
            startScan()
        case .poweredOff:
            info("Bluetooth is unavailable")
            prepareForUnavailableBluetooth()
        case .unauthorized:
            errorEvent("Bluetooth permission denied; enable access in System Settings")
            prepareForUnavailableBluetooth()
        case .unsupported:
            errorEvent("Bluetooth Low Energy is unsupported on this Mac")
            prepareForUnavailableBluetooth()
        case .resetting:
            log("Bluetooth is resetting")
            prepareForUnavailableBluetooth()
        case .unknown:
            log("Bluetooth state is not ready")
            prepareForUnavailableBluetooth()
        @unknown default:
            log("Bluetooth entered an unknown state")
            prepareForUnavailableBluetooth()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard matchesScale(peripheral: peripheral, advertisementData: advertisementData) else {
            return
        }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? "AFU scale"
        log("Matched \(name), RSSI=\(RSSI)")
        connect(to: peripheral, name: name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        log("Connected; discovering FFB0 service")
        scheduleSetupTimeout(for: peripheral.identifier)
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        log("Connection failed: \(error?.localizedDescription ?? "unknown error")")
        resetConnectionState()
        scheduleScanRetry()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard activePeripheral?.identifier == peripheral.identifier else { return }
        if let measurement = sessionTracker.disconnect(at: Date()) {
            enqueueForPersistence(measurement)
        }
        flushTimer?.invalidate()
        log("Disconnected: \(error?.localizedDescription ?? "scale is idle")")
        resetConnectionState()
        scheduleScanRetry()
    }
}

extension BluetoothReader: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Service discovery failed: \(error.localizedDescription)")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            log("FFB0 service not found")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            log("Characteristic discovery failed: \(error.localizedDescription)")
            central?.cancelPeripheralConnection(peripheral)
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == writeUUID {
                writeCharacteristic = characteristic
            } else if characteristic.uuid == notifyUUID {
                notifyCharacteristic = characteristic
            }
        }

        guard let notifyCharacteristic else {
            log("FFB2 notification characteristic not found")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        log("Enabling FFB2 notifications")
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == notifyUUID else { return }
        if let error {
            log("FFB2 notification subscription failed: \(error.localizedDescription)")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        guard characteristic.isNotifying else {
            log("FFB2 notifications were disabled")
            return
        }
        setupTimeoutTimer?.invalidate()
        log("FFB2 notifications enabled")
        sendHandshake(to: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == writeUUID else { return }
        guard let error else {
            log("AFU handshake acknowledged")
            return
        }

        if characteristic.properties.contains(.writeWithoutResponse), !handshakeFallbackAttempted {
            handshakeFallbackAttempted = true
            log("Handshake with response failed; retrying without response: \(error.localizedDescription)")
            peripheral.writeValue(handshake, for: characteristic, type: .withoutResponse)
        } else {
            log("AFU handshake failed: \(error.localizedDescription)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == notifyUUID else { return }
        if let error {
            log("FFB2 notification error: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else {
            log("FFB2 notification was empty")
            return
        }
        handle(data, deviceName: peripheral.name ?? "AFU-WL-TZ-A1")
    }
}
