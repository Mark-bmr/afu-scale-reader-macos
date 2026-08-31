import AFUCore
import CoreBluetooth
import Foundation

@MainActor
final class BluetoothReader: NSObject {
    private let serviceUUID = CBUUID(string: "0000FFB0-0000-1000-8000-00805F9B34FB")
    private let writeUUID = CBUUID(string: "0000FFB1-0000-1000-8000-00805F9B34FB")
    private let notifyUUID = CBUUID(string: "0000FFB2-0000-1000-8000-00805F9B34FB")

    private let configuration: ReaderConfiguration
    private let measurementStore: MeasurementStore
    private let logger: RotatingFileLogger
    private let sessionMode: AFUSessionMode
    private var sessionTracker: MeasurementSessionTracker
    private var historyTracker: MeasurementSessionTracker
    private var lifecycle = BluetoothLifecycle()
    private var central: CBCentralManager?
    private var activePeripheral: CBPeripheral?
    private var activeProtocolMetadata: AFUAdvertisementProtocolMetadata?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var pendingSessionInitializationPackets: [Data] = []
    private var inFlightSessionCommand: UInt8?
    private var previousHistoryPayload: Data?
    private var previousHistoryMeasuredAt: Date?
    private var setupTimeoutTimer: Timer?
    private var retryTimer: Timer?
    private var advertisementQuietTimer: Timer?
    private var flushTimer: Timer?
    private var interruptedSessionTimer: Timer?
    private var persistenceRetryTimer: Timer?
    private var markdownReconciliationTimer: Timer?
    private var persistenceQueue: [StableMeasurement] = []
    private var sessionInitializationAttempted = false
    private var shouldRun = false

    init(
        configuration: ReaderConfiguration,
        logger: RotatingFileLogger,
        sessionMode: AFUSessionMode
    ) {
        self.configuration = configuration
        self.logger = logger
        self.sessionMode = sessionMode
        measurementStore = MeasurementStore(configuration: configuration)
        sessionTracker = MeasurementSessionTracker(settleInterval: configuration.settleInterval)
        historyTracker = MeasurementSessionTracker(settleInterval: configuration.settleInterval)
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
        advertisementQuietTimer?.invalidate()
        flushTimer?.invalidate()
        interruptedSessionTimer?.invalidate()
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

    private func protocolMetadata(
        from advertisementData: [String: Any]
    ) -> AFUAdvertisementProtocolMetadata? {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            log("Matched scale advertisement has no manufacturer data")
            return nil
        }

        do {
            return try AFUAdvertisementProtocolMetadata(manufacturerData: manufacturerData)
        } catch let error as AFUSessionProfileError {
            switch error {
            case let .advertisementTooShort(actual):
                log("Matched scale manufacturer data is too short: bytes=\(actual)")
            case .invalidManufacturerMagic:
                log("Matched scale manufacturer data has an unexpected identifier")
            case let .unsupportedScale(category, subtype):
                log("Matched scale protocol is not recognized: category=\(category) subtype=\(subtype)")
            default:
                log("Matched scale protocol metadata could not be decoded")
            }
            return nil
        } catch {
            log("Matched scale protocol metadata could not be decoded")
            return nil
        }
    }

    private func connect(
        to peripheral: CBPeripheral,
        name: String,
        protocolMetadata: AFUAdvertisementProtocolMetadata?
    ) {
        guard let central, activePeripheral == nil else { return }
        central.stopScan()
        activePeripheral = peripheral
        activeProtocolMetadata = protocolMetadata
        lifecycle.connectionStarted()
        advertisementQuietTimer?.invalidate()
        advertisementQuietTimer = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        sessionInitializationAttempted = false
        previousHistoryPayload = nil
        previousHistoryMeasuredAt = nil
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

    private func restartAdvertisementQuietTimer() {
        guard shouldRun else { return }
        advertisementQuietTimer?.invalidate()
        advertisementQuietTimer = Timer.scheduledTimer(
            timeInterval: configuration.advertisementQuietInterval,
            target: self,
            selector: #selector(advertisementQuietTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func advertisementQuietTimerFired(_: Timer) {
        advertisementQuietTimer = nil
        lifecycle.advertisementQuietPeriodElapsed()
        log("Scale advertisement burst ended; waiting for the next wake")
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

    private func scheduleInterruptedSessionFlush() {
        interruptedSessionTimer?.invalidate()
        interruptedSessionTimer = Timer.scheduledTimer(
            timeInterval: configuration.connectionTimeout + configuration.retryDelay,
            target: self,
            selector: #selector(interruptedSessionTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
    }

    private func cancelInterruptedSessionFlush() {
        interruptedSessionTimer?.invalidate()
        interruptedSessionTimer = nil
    }

    @objc private func interruptedSessionTimerFired(_: Timer) {
        interruptedSessionTimer = nil
        if let measurement = sessionTracker.disconnect(at: Date()) {
            enqueueForPersistence(measurement)
        }
    }

    private func sendSessionInitialization(to peripheral: CBPeripheral) {
        guard let writeCharacteristic else {
            log("AFU session initialization skipped because FFB1 is missing")
            return
        }
        if activeProtocolMetadata == nil {
            log("Using AFU subtype 7 compatibility session initialization")
        }
        let deviceType = AFUSessionDeviceType.resolved(from: activeProtocolMetadata)
        let fallbackWeightKilograms = 60.0
        let currentWeightKilograms: Double
        do {
            currentWeightKilograms = try measurementStore.latestWeightKilograms()
                ?? fallbackWeightKilograms
        } catch {
            currentWeightKilograms = fallbackWeightKilograms
            log("AFU session user weight unavailable; using local fallback")
        }

        do {
            pendingSessionInitializationPackets = try AFUSessionInitializationPackets.encode(
                mode: sessionMode,
                deviceType: deviceType,
                profile: configuration.profile,
                currentWeightKilograms: currentWeightKilograms
            )
        } catch {
            errorEvent("AFU session initialization could not be encoded")
            return
        }
        inFlightSessionCommand = nil
        info("AFU session initialization started")
        sendNextSessionInitializationPacket(to: peripheral, characteristic: writeCharacteristic)
    }

    private func sendNextSessionInitializationPacket(
        to peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        guard !pendingSessionInitializationPackets.isEmpty else {
            inFlightSessionCommand = nil
            info("AFU session initialization completed")
            return
        }

        let prefersWriteWithoutResponse = sessionMode == .live
            && characteristic.properties.contains(.writeWithoutResponse)
        if !prefersWriteWithoutResponse, characteristic.properties.contains(.write) {
            guard inFlightSessionCommand == nil else { return }
            let packet = pendingSessionInitializationPackets.removeFirst()
            inFlightSessionCommand = packet[18]
            sessionInitializationAttempted = true
            log("Sending AFU session command=\(sessionCommandLabel(packet[18])) with response")
            peripheral.writeValue(packet, for: characteristic, type: .withResponse)
            return
        }

        guard characteristic.properties.contains(.writeWithoutResponse) else {
            pendingSessionInitializationPackets.removeAll()
            log("AFU session initialization skipped because FFB1 is not writable")
            return
        }

        while !pendingSessionInitializationPackets.isEmpty {
            let packet = pendingSessionInitializationPackets.removeFirst()
            sessionInitializationAttempted = true
            peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
            info("AFU session command sent command=\(sessionCommandLabel(packet[18]))")
        }
        info("AFU session initialization completed")
    }

    private func sessionCommandLabel(_ command: UInt8) -> String {
        switch command {
        case 0xD0: "D0"
        case 0xD1: "D1"
        default: "unknown"
        }
    }

    private func handle(_ data: Data, deviceName: String) {
        let receivedAt = Date()
        do {
            let packet = try AFUPacket(data: data)
            if packet.kind == .finalResult {
                flushTimer?.invalidate()
                cancelInterruptedSessionFlush()
                info("Final measurement result received")
                if let measurement = sessionTracker.receiveFinalResult(
                    packet,
                    at: receivedAt,
                    deviceName: deviceName
                ) {
                    enqueueForPersistence(measurement)
                }
                if sessionMode == .live {
                    log("Live measurement completed; keeping the scale connection open")
                }
                return
            }

            if packet.kind == .history {
                guard sessionMode.persistsHistoricalMeasurements else {
                    log("Ignoring historical measurement result in live mode")
                    return
                }
                info("Historical measurement result received")
                let hasPreviousHistory = previousHistoryPayload != nil
                let repeatedPayload = previousHistoryPayload.map { $0 == data } ?? false
                let repeatedDeviceTime: Bool
                if let previousHistoryMeasuredAt, let measuredAt = packet.measuredAt {
                    repeatedDeviceTime = previousHistoryMeasuredAt == measuredAt
                } else {
                    repeatedDeviceTime = false
                }
                log(
                    "History result detail type="
                        + (packet.historyType.map(String.init) ?? "unknown")
                        + " remaining_count="
                        + (packet.remainingHistoryCount.map(String.init) ?? "unknown")
                        + " repeated_payload="
                        + (hasPreviousHistory ? (repeatedPayload ? "yes" : "no") : "first")
                        + " repeated_device_time="
                        + (hasPreviousHistory ? (repeatedDeviceTime ? "yes" : "no") : "first")
                )
                previousHistoryPayload = data
                previousHistoryMeasuredAt = packet.measuredAt
                if let measurement = historyTracker.receiveFinalResult(
                    packet,
                    at: receivedAt,
                    deviceName: deviceName
                ) {
                    enqueueForPersistence(measurement)
                }
                return
            }

            let wasWaitingForReconnect = interruptedSessionTimer != nil
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

            if wasWaitingForReconnect {
                if sessionTracker.isAwaitingFinalResult {
                    scheduleInterruptedSessionFlush()
                } else {
                    cancelInterruptedSessionFlush()
                }
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

    private func resetConnectionState(waitForFreshAdvertisement: Bool = false) {
        setupTimeoutTimer?.invalidate()
        setupTimeoutTimer = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        pendingSessionInitializationPackets.removeAll()
        inFlightSessionCommand = nil
        previousHistoryPayload = nil
        previousHistoryMeasuredAt = nil
        activePeripheral = nil
        activeProtocolMetadata = nil
        sessionInitializationAttempted = false
        lifecycle.connectionEnded(waitForFreshAdvertisement: waitForFreshAdvertisement)
    }

    private func prepareForUnavailableBluetooth() {
        let hadActivePeripheral = activePeripheral != nil
        retryTimer?.invalidate()
        advertisementQuietTimer?.invalidate()
        advertisementQuietTimer = nil
        flushTimer?.invalidate()
        cancelInterruptedSessionFlush()
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
        guard lifecycle.shouldConnectToAdvertisement else {
            if lifecycle.shouldScan {
                restartAdvertisementQuietTimer()
            }
            return
        }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? "AFU scale"
        let metadata = protocolMetadata(from: advertisementData)
        if metadata == nil {
            log("Matched scale lacks supported AFU protocol metadata")
        }
        log("Matched \(name), RSSI=\(RSSI)")
        connect(to: peripheral, name: name, protocolMetadata: metadata)
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
        if let measurement = sessionTracker.connectionInterrupted(at: Date()) {
            enqueueForPersistence(measurement)
        }
        if sessionTracker.isAwaitingFinalResult {
            scheduleInterruptedSessionFlush()
        } else {
            cancelInterruptedSessionFlush()
        }
        flushTimer?.invalidate()
        log("Disconnected: \(error?.localizedDescription ?? "scale is idle")")
        let waitForFreshAdvertisement = sessionInitializationAttempted
            && !sessionTracker.isAwaitingFinalResult
        resetConnectionState(waitForFreshAdvertisement: waitForFreshAdvertisement)
        if waitForFreshAdvertisement {
            restartAdvertisementQuietTimer()
        }
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
        sendSessionInitialization(to: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == writeUUID else { return }
        let command = inFlightSessionCommand
        inFlightSessionCommand = nil
        guard let error else {
            info("AFU session command acknowledged command=\(sessionCommandLabel(command ?? 0))")
            if let writeCharacteristic {
                sendNextSessionInitializationPacket(
                    to: peripheral,
                    characteristic: writeCharacteristic
                )
            }
            return
        }
        pendingSessionInitializationPackets.removeAll()
        log(
            "AFU session command write failed command="
                + sessionCommandLabel(command ?? 0)
                + ": \(error.localizedDescription)"
        )
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
