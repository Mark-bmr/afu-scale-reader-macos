import Foundation
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

    func testCompletedSessionWaitsForReconnectCooldown() {
        let disconnectedAt = Date(timeIntervalSince1970: 1_000)
        let reconnectAt = disconnectedAt.addingTimeInterval(5)
        var lifecycle = BluetoothLifecycle(isBluetoothAvailable: true)
        lifecycle.connectionStarted()

        lifecycle.connectionEnded(reconnectAt: reconnectAt)

        XCTAssertTrue(lifecycle.shouldScan)
        XCTAssertFalse(lifecycle.shouldConnectToAdvertisement(at: disconnectedAt))
        XCTAssertFalse(lifecycle.shouldConnectToAdvertisement(
            at: reconnectAt.addingTimeInterval(-0.001)
        ))
        XCTAssertTrue(lifecycle.shouldConnectToAdvertisement(at: reconnectAt))
    }

    func testRepeatedAdvertisementsDoNotExtendReconnectCooldown() {
        let disconnectedAt = Date(timeIntervalSince1970: 1_000)
        let reconnectAt = disconnectedAt.addingTimeInterval(5)
        var lifecycle = BluetoothLifecycle(isBluetoothAvailable: true)
        lifecycle.connectionStarted()
        lifecycle.connectionEnded(reconnectAt: reconnectAt)

        XCTAssertFalse(lifecycle.shouldConnectToAdvertisement(
            at: disconnectedAt.addingTimeInterval(1)
        ))
        XCTAssertFalse(lifecycle.shouldConnectToAdvertisement(
            at: disconnectedAt.addingTimeInterval(4.9)
        ))
        XCTAssertTrue(lifecycle.shouldConnectToAdvertisement(at: reconnectAt))
    }

    func testInterruptedFinalResultCanReconnectImmediately() {
        let now = Date(timeIntervalSince1970: 1_000)
        var lifecycle = BluetoothLifecycle(isBluetoothAvailable: true)
        lifecycle.connectionStarted()

        lifecycle.connectionEnded()

        XCTAssertTrue(lifecycle.shouldConnectToAdvertisement(at: now))
    }

    func testBluetoothUnavailableClearsReconnectCooldown() {
        let now = Date(timeIntervalSince1970: 1_000)
        var lifecycle = BluetoothLifecycle(isBluetoothAvailable: true)
        lifecycle.connectionStarted()
        lifecycle.connectionEnded(reconnectAt: now.addingTimeInterval(5))

        lifecycle.bluetoothAvailabilityChanged(to: false)
        lifecycle.bluetoothAvailabilityChanged(to: true)

        XCTAssertTrue(lifecycle.shouldConnectToAdvertisement(at: now))
    }
}
