import XCTest
@testable import AFUCore

// All lifecycle states and identifiers in this file are synthetic.
final class BluetoothLifecycleTests: XCTestCase {
    func testInitialBluetoothAvailabilityDoesNotRequestFreshManager() {
        var lifecycle = BluetoothLifecycle()

        lifecycle.bluetoothAvailabilityChanged(to: true)

        XCTAssertFalse(lifecycle.consumeCentralRecreationRequest())
    }

    func testBluetoothRecoveryRequestsFreshManagerExactlyOnce() {
        var lifecycle = BluetoothLifecycle()
        lifecycle.bluetoothAvailabilityChanged(to: true)
        lifecycle.bluetoothAvailabilityChanged(to: false)

        XCTAssertFalse(lifecycle.consumeCentralRecreationRequest())

        lifecycle.bluetoothAvailabilityChanged(to: true)

        XCTAssertTrue(lifecycle.consumeCentralRecreationRequest())
        XCTAssertFalse(lifecycle.consumeCentralRecreationRequest())
    }

    func testBluetoothUnavailableClearsStaleConnectionAndAllowsScanAfterRecovery() {
        var lifecycle = BluetoothLifecycle()

        lifecycle.bluetoothAvailabilityChanged(to: true)
        lifecycle.connectionStarted()

        XCTAssertFalse(lifecycle.shouldScan)
        XCTAssertTrue(lifecycle.hasActiveConnection)

        lifecycle.bluetoothAvailabilityChanged(to: false)

        XCTAssertFalse(lifecycle.shouldScan)
        XCTAssertFalse(lifecycle.hasActiveConnection)

        lifecycle.bluetoothAvailabilityChanged(to: true)

        XCTAssertTrue(lifecycle.shouldScan)
    }

    func testActiveConnectionPreventsDuplicateScanWhileBluetoothRemainsAvailable() {
        var lifecycle = BluetoothLifecycle()

        lifecycle.bluetoothAvailabilityChanged(to: true)
        lifecycle.connectionStarted()
        lifecycle.bluetoothAvailabilityChanged(to: true)

        XCTAssertFalse(lifecycle.shouldScan)
        XCTAssertTrue(lifecycle.hasActiveConnection)
    }

    func testConnectionEndAllowsScanWhenBluetoothIsAvailable() {
        var lifecycle = BluetoothLifecycle()

        lifecycle.bluetoothAvailabilityChanged(to: true)
        lifecycle.connectionStarted()
        lifecycle.connectionEnded()

        XCTAssertTrue(lifecycle.shouldScan)
        XCTAssertFalse(lifecycle.hasActiveConnection)
    }

    func testCompletedSessionWaitsForFreshAdvertisementBurst() {
        var lifecycle = BluetoothLifecycle(isBluetoothAvailable: true)
        lifecycle.connectionStarted()

        lifecycle.connectionEnded(waitForFreshAdvertisement: true)

        XCTAssertTrue(lifecycle.shouldScan)
        XCTAssertFalse(lifecycle.shouldConnectToAdvertisement)

        lifecycle.advertisementQuietPeriodElapsed()

        XCTAssertTrue(lifecycle.shouldConnectToAdvertisement)
    }

    func testInterruptedFinalResultCanReconnectImmediately() {
        var lifecycle = BluetoothLifecycle(isBluetoothAvailable: true)
        lifecycle.connectionStarted()

        lifecycle.connectionEnded(waitForFreshAdvertisement: false)

        XCTAssertTrue(lifecycle.shouldConnectToAdvertisement)
    }

    func testBluetoothUnavailableClearsAdvertisementGate() {
        var lifecycle = BluetoothLifecycle(isBluetoothAvailable: true)
        lifecycle.connectionStarted()
        lifecycle.connectionEnded(waitForFreshAdvertisement: true)

        lifecycle.bluetoothAvailabilityChanged(to: false)
        lifecycle.bluetoothAvailabilityChanged(to: true)

        XCTAssertTrue(lifecycle.shouldConnectToAdvertisement)
    }
}
