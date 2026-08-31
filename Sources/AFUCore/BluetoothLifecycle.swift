import Foundation

public struct BluetoothLifecycle: Equatable, Sendable {
    public private(set) var isBluetoothAvailable: Bool
    public private(set) var hasActiveConnection: Bool
    private var needsCentralRecreation = false
    private var reconnectAllowedAt: Date?

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

    public func shouldConnectToAdvertisement(at date: Date) -> Bool {
        shouldScan && (reconnectAllowedAt.map { date >= $0 } ?? true)
    }

    public mutating func bluetoothAvailabilityChanged(to isAvailable: Bool) {
        let wasAvailable = isBluetoothAvailable
        isBluetoothAvailable = isAvailable
        if !isAvailable {
            hasActiveConnection = false
            reconnectAllowedAt = nil
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
        reconnectAllowedAt = nil
    }

    public mutating func connectionEnded(reconnectAt: Date? = nil) {
        hasActiveConnection = false
        reconnectAllowedAt = reconnectAt
    }
}
