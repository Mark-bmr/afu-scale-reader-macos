import Foundation
import XCTest
@testable import AFUCore

// All device names, timestamps, weights, impedance values, and packets in this file are synthetic.
final class MeasurementDeduplicatorTests: XCTestCase {
    func testUsesConvergedWeightFromSyntheticFluctuatingSequence() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 900)
        let syntheticWeights = [68.4, 71.2, 69.7, 70.1, 70.0, 70.0, 70.0]
        var emitted: [StableMeasurement] = []

        for (index, weight) in syntheticWeights.enumerated() {
            if let measurement = tracker.receive(
                try packet(weight: weight, stable: true, impedance: 800),
                at: start.addingTimeInterval(Double(index) * 0.15),
                deviceName: "AFU-WL-TZ-A1"
            ) {
                emitted.append(measurement)
            }
        }

        XCTAssertEqual(emitted.count, 1)
        let measurement = try XCTUnwrap(emitted.first)
        XCTAssertEqual(measurement.weightKilograms, 70, accuracy: 0.000_1)
        XCTAssertEqual(measurement.impedanceRawCode, 800)
    }

    func testDisconnectDropsCandidateWithOnlyTwoMatchingSamples() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 950)

        XCTAssertNil(tracker.receive(
            try packet(weight: 65, stable: true, impedance: 700),
            at: start,
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try packet(weight: 65, stable: true, impedance: 700),
            at: start.addingTimeInterval(0.15),
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.disconnect(at: start.addingTimeInterval(0.3)))
    }

    func testEmitsOnlyFirstConvergedWeightInSession() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(tracker.receive(try packet(weight: 50, stable: false, impedance: 600), at: start, deviceName: "AFU-WL-TZ-A1"))
        XCTAssertNil(tracker.receive(try packet(weight: 50, stable: true, impedance: 600), at: start.addingTimeInterval(1), deviceName: "AFU-WL-TZ-A1"))
        XCTAssertNil(tracker.receive(try packet(weight: 50, stable: true, impedance: 600), at: start.addingTimeInterval(1.15), deviceName: "AFU-WL-TZ-A1"))
        let converged = tracker.receive(try packet(weight: 50, stable: true, impedance: 600), at: start.addingTimeInterval(1.3), deviceName: "AFU-WL-TZ-A1")
        let repeated = tracker.receive(try packet(weight: 50, stable: true, impedance: 600), at: start.addingTimeInterval(1.45), deviceName: "AFU-WL-TZ-A1")

        XCTAssertEqual(converged?.weightKilograms, 50)
        XCTAssertEqual(converged?.impedanceRawCode, 600)
        XCTAssertNil(repeated)
    }

    func testPositiveDynamicPacketDoesNotReopenEmittedSession() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 2_000)

        XCTAssertNotNil(try converge(
            tracker: &tracker,
            weight: 60,
            impedance: 700,
            start: start
        ))
        XCTAssertNil(tracker.receive(try packet(weight: 59.8, stable: false, impedance: 700), at: start.addingTimeInterval(1), deviceName: "AFU-WL-TZ-A1"))
        XCTAssertNil(tracker.receive(try packet(weight: 60, stable: true, impedance: 700), at: start.addingTimeInterval(2), deviceName: "AFU-WL-TZ-A1"))
    }

    func testZeroWeightStartsNextSession() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 3_000)

        XCTAssertNotNil(try converge(
            tracker: &tracker,
            weight: 60,
            impedance: 700,
            start: start
        ))
        XCTAssertNil(tracker.receive(try packet(weight: 0, stable: false, impedance: 0), at: start.addingTimeInterval(1), deviceName: "AFU-WL-TZ-A1"))
        XCTAssertNotNil(try converge(
            tracker: &tracker,
            weight: 61,
            impedance: 710,
            start: start.addingTimeInterval(2)
        ))
    }

    func testMeasurementCompletionAllowsNextWeighing() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 3_500)

        XCTAssertNotNil(try converge(
            tracker: &tracker,
            weight: 70,
            impedance: 800,
            start: start
        ))
        XCTAssertNil(tracker.measurementCompleted(at: start.addingTimeInterval(1)))
        XCTAssertNotNil(try converge(
            tracker: &tracker,
            weight: 70.2,
            impedance: 810,
            start: start.addingTimeInterval(2)
        ))
    }

    func testWaitsForMissingImpedanceThenFlushesWeight() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 4_000)

        XCTAssertNil(try converge(
            tracker: &tracker,
            weight: 65,
            impedance: 0,
            start: start
        ))
        XCTAssertNil(tracker.flushIfDue(at: start.addingTimeInterval(1.9)))
        let flushed = tracker.flushIfDue(at: start.addingTimeInterval(2))

        XCTAssertEqual(flushed?.weightKilograms, 65)
        XCTAssertNil(flushed?.impedanceRawCode)
        XCTAssertNil(tracker.flushIfDue(at: start.addingTimeInterval(3)))
    }

    func testLaterStablePacketCanCompletePendingWeightWithImpedance() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 5_000)

        XCTAssertNil(tracker.receive(try packet(weight: 65, stable: true, impedance: 0), at: start, deviceName: "AFU-WL-TZ-A1"))
        XCTAssertNil(tracker.receive(try packet(weight: 65, stable: true, impedance: 0), at: start.addingTimeInterval(0.15), deviceName: "AFU-WL-TZ-A1"))
        let completed = tracker.receive(try packet(weight: 65, stable: true, impedance: 720), at: start.addingTimeInterval(0.3), deviceName: "AFU-WL-TZ-A1")

        XCTAssertEqual(completed?.impedanceRawCode, 720)
        XCTAssertEqual(completed?.measuredAt, start)
    }

    func testDisconnectFlushesPendingWeightAndResetsSession() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 6_000)

        XCTAssertNil(try converge(
            tracker: &tracker,
            weight: 65,
            impedance: 0,
            start: start
        ))
        let flushed = tracker.disconnect(at: start.addingTimeInterval(1))
        let next = try converge(
            tracker: &tracker,
            weight: 66,
            impedance: 730,
            start: start.addingTimeInterval(2)
        )

        XCTAssertEqual(flushed?.weightKilograms, 65)
        XCTAssertNotNil(next)
    }

    func testStepOffPacketFlushesPendingWeightWithoutImpedance() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 7_000)

        XCTAssertNil(try converge(
            tracker: &tracker,
            weight: 65,
            impedance: 0,
            start: start
        ))
        let flushed = tracker.receive(try packet(weight: 0, stable: false, impedance: 0), at: start.addingTimeInterval(1), deviceName: "AFU-WL-TZ-A1")
        let next = try converge(
            tracker: &tracker,
            weight: 66,
            impedance: 730,
            start: start.addingTimeInterval(2)
        )

        XCTAssertEqual(flushed?.weightKilograms, 65)
        XCTAssertNil(flushed?.impedanceRawCode)
        XCTAssertNotNil(next)
    }

    func testDeduplicatesSameMeasurementInsideWindow() {
        let deduplicator = MeasurementDeduplicator(window: 120)
        let earlier = MeasurementSignature(
            measuredAt: Date(timeIntervalSince1970: 10_000),
            weightKilograms: 65,
            impedanceRawCode: 700,
            deviceName: "AFU-WL-TZ-A1"
        )
        let repeated = MeasurementSignature(
            measuredAt: Date(timeIntervalSince1970: 10_100),
            weightKilograms: 65.003,
            impedanceRawCode: 700,
            deviceName: "AFU-WL-TZ-A1"
        )

        XCTAssertTrue(deduplicator.isDuplicate(repeated, comparedWith: earlier))
    }

    func testAllowsSameWeightOutsideWindow() {
        let deduplicator = MeasurementDeduplicator(window: 120)
        let earlier = MeasurementSignature(
            measuredAt: Date(timeIntervalSince1970: 10_000),
            weightKilograms: 65,
            impedanceRawCode: 700,
            deviceName: "AFU-WL-TZ-A1"
        )
        let later = MeasurementSignature(
            measuredAt: Date(timeIntervalSince1970: 10_121),
            weightKilograms: 65,
            impedanceRawCode: 700,
            deviceName: "AFU-WL-TZ-A1"
        )

        XCTAssertFalse(deduplicator.isDuplicate(later, comparedWith: earlier))
    }

    func testDeduplicationDoesNotRequirePersistedDeviceIdentifier() {
        let deduplicator = MeasurementDeduplicator(window: 120)
        let persisted = MeasurementSignature(
            measuredAt: Date(timeIntervalSince1970: 20_000),
            weightKilograms: 70,
            impedanceRawCode: 800,
            deviceName: ""
        )
        let candidate = MeasurementSignature(
            measuredAt: Date(timeIntervalSince1970: 20_060),
            weightKilograms: 70,
            impedanceRawCode: 800,
            deviceName: "Synthetic Scale"
        )

        XCTAssertTrue(deduplicator.isDuplicate(candidate, comparedWith: persisted))
    }

    private func converge(
        tracker: inout MeasurementSessionTracker,
        weight: Double,
        impedance: Int,
        start: Date
    ) throws -> StableMeasurement? {
        XCTAssertNil(tracker.receive(
            try packet(weight: weight, stable: true, impedance: impedance),
            at: start,
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try packet(weight: weight, stable: true, impedance: impedance),
            at: start.addingTimeInterval(0.15),
            deviceName: "AFU-WL-TZ-A1"
        ))
        return tracker.receive(
            try packet(weight: weight, stable: true, impedance: impedance),
            at: start.addingTimeInterval(0.3),
            deviceName: "AFU-WL-TZ-A1"
        )
    }

    private func packet(weight: Double, stable: Bool, impedance: Int) throws -> AFUPacket {
        let rawWeight = Int((weight * 1_000).rounded())
        let high = UInt8(rawWeight / 65_536 + 0x68)
        let remainder = rawWeight % 65_536
        return try AFUPacket(data: Data([
            0xAC,
            0x00,
            0x00,
            high,
            UInt8(remainder / 256),
            UInt8(remainder % 256),
            stable ? 0x02 : 0x00,
            0x00,
            UInt8(impedance / 256),
            UInt8(impedance % 256)
        ]))
    }
}
