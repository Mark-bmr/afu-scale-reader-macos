public struct BluetoothLifecycle: Equatable, Sendable {
    public private(set) var isBluetoothAvailable: Bool
    public private(set) var hasActiveConnection: Bool
    private var needsCentralRecreation = false

    public init(
        isBluetoothAvailable: Bool = false,
        hasActiveConnection: Bool = false
    ) {
        self.isBluetoothAvailable = isBluetoothAvailable
        self.hasActiveConnection = isBluetoothAvailable && hasActiveConnection
    }

    public var shouldScan: Bool {
        isBluetoothAvailable && !hasActiveConnection
    }

    public mutating func bluetoothAvailabilityChanged(to isAvailable: Bool) {
        let wasAvailable = isBluetoothAvailable
        isBluetoothAvailable = isAvailable
        if !isAvailable {
            hasActiveConnection = false
            if wasAvailable {
                needsCentralRecreation = true
            }
        }
    }

    public mutating func consumeCentralRecreationRequest() -> Bool {
        guard isBluetoothAvailable, needsCentralRecreation else { return false }
        needsCentralRecreation = false
        return true
    }

    public mutating func connectionStarted() {
        guard isBluetoothAvailable else { return }
        hasActiveConnection = true
    }

    public mutating func connectionEnded() {
        hasActiveConnection = false
    }
}
