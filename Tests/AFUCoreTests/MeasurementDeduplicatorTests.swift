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

    func testEachSyntheticD6ResultEmitsDuringOneConnection() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 3_700)

        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start,
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(0.15),
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(0.3),
            deviceName: "AFU-WL-TZ-A1"
        ))

        let expected: [(weight: Double, impedance: Int)] = [
            (70.1, 710),
            (70.2, 720),
            (70.3, 730),
        ]
        let emitted = try expected.enumerated().compactMap { index, item in
            tracker.receiveFinalResult(
                try finalPacket(weight: item.weight, impedance: item.impedance),
                at: start.addingTimeInterval(1 + Double(index)),
                deviceName: "AFU-WL-TZ-A1"
            )
        }

        XCTAssertEqual(emitted.map(\.weightKilograms), expected.map(\.weight))
        XCTAssertEqual(emitted.map(\.impedanceRawCode), expected.map { Optional($0.impedance) })
    }

    func testD5WaitsForDelayedFinalResultBeyondSettleInterval() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 3_750)

        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start,
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(0.15),
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(0.3),
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(2.1),
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.flushIfDue(at: start.addingTimeInterval(6)))

        let final = tracker.receiveFinalResult(
            try finalPacket(weight: 70, impedance: 700),
            at: start.addingTimeInterval(6.1),
            deviceName: "AFU-WL-TZ-A1"
        )

        XCTAssertEqual(final?.weightKilograms, 70)
        XCTAssertEqual(final?.impedanceRawCode, 700)
    }

    func testD5FallsBackOnDisconnectWhenFinalResultNeverArrives() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 3_775)

        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start,
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(0.15),
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(0.3),
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.flushIfDue(at: start.addingTimeInterval(10)))

        let fallback = tracker.disconnect(at: start.addingTimeInterval(10.1))

        XCTAssertEqual(fallback?.weightKilograms, 70)
        XCTAssertNil(fallback?.impedanceRawCode)
    }

    func testD5SurvivesTransientDisconnectUntilFinalResultAfterReconnect() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 3_780)

        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start,
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(0.15),
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(0.3),
            deviceName: "AFU-WL-TZ-A1"
        ))

        XCTAssertNil(tracker.connectionInterrupted(at: start.addingTimeInterval(0.4)))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(2.4),
            deviceName: "AFU-WL-TZ-A1"
        ))

        let final = tracker.receiveFinalResult(
            try finalPacket(weight: 70, impedance: 700),
            at: start.addingTimeInterval(4.5),
            deviceName: "AFU-WL-TZ-A1"
        )

        XCTAssertEqual(final?.weightKilograms, 70)
        XCTAssertEqual(final?.impedanceRawCode, 700)
        XCTAssertNil(tracker.disconnect(at: start.addingTimeInterval(5)))
    }

    func testInterruptedD5FallsBackWhenReconnectGraceEnds() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 3_785)

        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start,
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(0.15),
            deviceName: "AFU-WL-TZ-A1"
        ))
        XCTAssertNil(tracker.receive(
            try livePacket(weight: 70, stable: true),
            at: start.addingTimeInterval(0.3),
            deviceName: "AFU-WL-TZ-A1"
        ))

        XCTAssertNil(tracker.connectionInterrupted(at: start.addingTimeInterval(0.4)))
        let fallback = tracker.disconnect(at: start.addingTimeInterval(9.4))

        XCTAssertEqual(fallback?.weightKilograms, 70)
        XCTAssertNil(fallback?.impedanceRawCode)
    }

    func testLegacyPacketFallsBackImmediatelyOnConnectionInterrupted() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let start = Date(timeIntervalSince1970: 3_790)

        XCTAssertNil(try converge(
            tracker: &tracker,
            weight: 65,
            impedance: 0,
            start: start
        ))

        let fallback = tracker.connectionInterrupted(at: start.addingTimeInterval(1))

        XCTAssertEqual(fallback?.weightKilograms, 65)
        XCTAssertNil(fallback?.impedanceRawCode)
    }

    func testRepeatedSyntheticD6IsLeftForStoreDeduplication() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let deduplicator = MeasurementDeduplicator(window: 120)
        let start = Date(timeIntervalSince1970: 3_800)
        let packet = try finalPacket(weight: 70, impedance: 700)

        let first = try XCTUnwrap(tracker.receiveFinalResult(
            packet,
            at: start,
            deviceName: "AFU-WL-TZ-A1"
        ))
        let repeated = try XCTUnwrap(tracker.receiveFinalResult(
            packet,
            at: start.addingTimeInterval(1),
            deviceName: "AFU-WL-TZ-A1"
        ))

        XCTAssertTrue(deduplicator.isDuplicate(repeated.signature, comparedWith: first.signature))
    }

    func testSyntheticD8ResultsUseDeviceTimeForDeduplication() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let deduplicator = MeasurementDeduplicator(window: 120)
        let firstTimestamp: UInt32 = 1_600_000_000
        let secondTimestamp = firstTimestamp + 60

        let first = try XCTUnwrap(tracker.receiveFinalResult(
            try historyPacket(weight: 70, impedance: 700, timestamp: firstTimestamp),
            at: Date(timeIntervalSince1970: 4_000),
            deviceName: "AFU-WL-TZ-A1"
        ))
        let second = try XCTUnwrap(tracker.receiveFinalResult(
            try historyPacket(weight: 70, impedance: 700, timestamp: secondTimestamp),
            at: Date(timeIntervalSince1970: 4_001),
            deviceName: "AFU-WL-TZ-A1"
        ))

        XCTAssertEqual(first.measuredAt, Date(timeIntervalSince1970: TimeInterval(firstTimestamp)))
        XCTAssertEqual(second.measuredAt, Date(timeIntervalSince1970: TimeInterval(secondTimestamp)))
        XCTAssertEqual(first.timeSource, .device)
        XCTAssertEqual(second.timeSource, .device)
        XCTAssertFalse(deduplicator.isDuplicate(second.signature, comparedWith: first.signature))
    }

    func testRepeatedSyntheticD8WithSameDeviceTimeIsDuplicate() throws {
        var tracker = MeasurementSessionTracker(settleInterval: 2)
        let deduplicator = MeasurementDeduplicator(window: 120)
        let timestamp: UInt32 = 1_600_000_000
        let packet = try historyPacket(weight: 70, impedance: 700, timestamp: timestamp)

        let first = try XCTUnwrap(tracker.receiveFinalResult(
            packet,
            at: Date(timeIntervalSince1970: 4_000),
            deviceName: "AFU-WL-TZ-A1"
        ))
        let repeated = try XCTUnwrap(tracker.receiveFinalResult(
            packet,
            at: Date(timeIntervalSince1970: 4_001),
            deviceName: "AFU-WL-TZ-A1"
        ))

        XCTAssertTrue(deduplicator.isDuplicate(repeated.signature, comparedWith: first.signature))
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

    private func livePacket(weight: Double, stable: Bool) throws -> AFUPacket {
        var data = framedPacket(type: 0xD5)
        encodeWeight(weight, state: stable, into: &data, stateIndex: 2, weightIndex: 3)
        finishChecksum(&data)
        return try AFUPacket(data: Data(data))
    }

    private func finalPacket(weight: Double, impedance: Int) throws -> AFUPacket {
        var data = framedPacket(type: 0xD6)
        data[2] = 0x02
        encodeUInt16(impedance, into: &data, at: 4)
        encodeUInt16(max(impedance - 30, 1), into: &data, at: 6)
        data[8] = 0x01
        encodeWeight(weight, state: true, into: &data, stateIndex: 9, weightIndex: 10)
        finishChecksum(&data)
        return try AFUPacket(data: Data(data))
    }

    private func historyPacket(
        weight: Double,
        impedance: Int,
        timestamp: UInt32
    ) throws -> AFUPacket {
        var data = framedPacket(type: 0xD8)
        data[2] = 0x02
        encodeUInt32(timestamp, into: &data, at: 3)
        encodeWeight(weight, state: true, into: &data, stateIndex: 7, weightIndex: 8)
        data[11] = 0x00
        data[12] = 0x01
        encodeUInt16(impedance, into: &data, at: 13)
        finishChecksum(&data)
        return try AFUPacket(data: Data(data))
    }

    private func framedPacket(type: UInt8) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 20)
        data[0] = 0xAC
        data[1] = 0x29
        data[17] = 0x29
        data[18] = type
        return data
    }

    private func encodeWeight(
        _ weight: Double,
        state: Bool,
        into data: inout [UInt8],
        stateIndex: Int,
        weightIndex: Int
    ) {
        let rawWeight = Int((weight * 1_000).rounded())
        data[stateIndex] = state ? 0x80 : 0x00
        data[weightIndex] = UInt8(rawWeight / 65_536 + 0x68)
        let remainder = rawWeight % 65_536
        data[weightIndex + 1] = UInt8(remainder / 256)
        data[weightIndex + 2] = UInt8(remainder % 256)
    }

    private func encodeUInt16(_ value: Int, into data: inout [UInt8], at index: Int) {
        data[index] = UInt8(value / 256)
        data[index + 1] = UInt8(value % 256)
    }

    private func encodeUInt32(_ value: UInt32, into data: inout [UInt8], at index: Int) {
        data[index] = UInt8((value >> 24) & 0xFF)
        data[index + 1] = UInt8((value >> 16) & 0xFF)
        data[index + 2] = UInt8((value >> 8) & 0xFF)
        data[index + 3] = UInt8(value & 0xFF)
    }

    private func finishChecksum(_ data: inout [UInt8]) {
        data[19] = UInt8(data[2 ... 18].reduce(0) { $0 + Int($1) } & 0x1F)
    }
}
