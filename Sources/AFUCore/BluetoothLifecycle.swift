public struct BluetoothLifecycle: Equatable, Sendable {
    public private(set) var isBluetoothAvailable: Bool
    public private(set) var hasActiveConnection: Bool
    private var needsCentralRecreation = false
    private var requiresAdvertisementQuietPeriod = false

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

    public var shouldConnectToAdvertisement: Bool {
        shouldScan && !requiresAdvertisementQuietPeriod
    }

    public mutating func bluetoothAvailabilityChanged(to isAvailable: Bool) {
        let wasAvailable = isBluetoothAvailable
        isBluetoothAvailable = isAvailable
        if !isAvailable {
            hasActiveConnection = false
            requiresAdvertisementQuietPeriod = false
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
        requiresAdvertisementQuietPeriod = false
    }

    public mutating func connectionEnded(waitForFreshAdvertisement: Bool = false) {
        hasActiveConnection = false
        requiresAdvertisementQuietPeriod = waitForFreshAdvertisement
    }

    public mutating func advertisementQuietPeriodElapsed() {
        requiresAdvertisementQuietPeriod = false
    }
}
