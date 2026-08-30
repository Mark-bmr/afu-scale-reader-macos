import Foundation
import XCTest
@testable import AFUCore

// All packets, timestamps, weights, and impedance values in this file are synthetic.
final class AFUPacketTests: XCTestCase {
    func testParsesSyntheticD5AsLiveWeightWithoutFalseImpedance() throws {
        var data = framedPacket(type: 0xD5)
        encodeWeight(70, state: true, into: &data, stateIndex: 2, weightIndex: 3)
        data[6] = 0x00
        data[8] = 0x05
        data[9] = 0x40
        finishChecksum(&data)

        let packet = try AFUPacket(data: Data(data))

        XCTAssertEqual(packet.kind, .liveWeight)
        XCTAssertEqual(packet.weightKilograms, 70, accuracy: 0.000_1)
        XCTAssertTrue(packet.isStable)
        XCTAssertNil(packet.impedanceRawCode)
        XCTAssertNil(packet.measuredAt)
        XCTAssertNil(packet.remainingHistoryCount)
        XCTAssertNil(packet.historyType)
    }

    func testD5StableFlagDoesNotComeFromModeByte() throws {
        var data = framedPacket(type: 0xD5)
        encodeWeight(70, state: false, into: &data, stateIndex: 2, weightIndex: 3)
        data[6] = 0x02
        finishChecksum(&data)

        let packet = try AFUPacket(data: Data(data))

        XCTAssertFalse(packet.isStable)
    }

    func testParsesSyntheticD6AsFinalResult() throws {
        var data = framedPacket(type: 0xD6)
        data[2] = 0x02
        encodeUInt16(710, into: &data, at: 4)
        encodeUInt16(680, into: &data, at: 6)
        data[8] = 0x01
        encodeWeight(70.2, state: true, into: &data, stateIndex: 9, weightIndex: 10)
        finishChecksum(&data)

        let packet = try AFUPacket(data: Data(data))

        XCTAssertEqual(packet.kind, .finalResult)
        XCTAssertEqual(packet.weightKilograms, 70.2, accuracy: 0.000_1)
        XCTAssertTrue(packet.isStable)
        XCTAssertEqual(packet.impedanceRawCode, 710)
        XCTAssertNil(packet.measuredAt)
        XCTAssertNil(packet.remainingHistoryCount)
        XCTAssertNil(packet.historyType)
    }

    func testParsesSyntheticD8HistoryWithDeviceTime() throws {
        let timestamp: UInt32 = 1_600_000_000
        var data = framedPacket(type: 0xD8)
        data[2] = 0x02
        encodeUInt32(timestamp, into: &data, at: 3)
        encodeWeight(69.8, state: true, into: &data, stateIndex: 7, weightIndex: 8)
        data[11] = 0x02
        data[12] = 0x02
        encodeUInt16(705, into: &data, at: 13)
        encodeUInt16(675, into: &data, at: 15)
        finishChecksum(&data)

        let packet = try AFUPacket(data: Data(data))

        XCTAssertEqual(packet.kind, .history)
        XCTAssertEqual(packet.weightKilograms, 69.8, accuracy: 0.000_1)
        XCTAssertTrue(packet.isStable)
        XCTAssertEqual(packet.impedanceRawCode, 705)
        XCTAssertEqual(packet.measuredAt, Date(timeIntervalSince1970: TimeInterval(timestamp)))
        XCTAssertEqual(packet.remainingHistoryCount, 2)
        XCTAssertEqual(packet.historyType, 2)
    }

    func testParsesSyntheticStablePacket() throws {
        let data = Data([0xAC, 0x00, 0x00, 0x69, 0x11, 0x70, 0x02, 0x00, 0x03, 0x20])

        let packet = try AFUPacket(data: data)

        XCTAssertEqual(packet.weightKilograms, 70, accuracy: 0.000_1)
        XCTAssertTrue(packet.isStable)
        XCTAssertEqual(packet.impedanceRawCode, 800)
        XCTAssertEqual(packet.rawHex, "AC000069117002000320")
        XCTAssertNil(packet.diagnosticOpcode)
    }

    func testAcceptsTwentyByteD5PacketAndExposesDiagnosticOpcode() throws {
        let data = Data([
            0xAC, 0x00, 0x80, 0x69, 0x11, 0x70, 0x02, 0x00, 0x03, 0x20,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD5, 0x00
        ])

        let packet = try AFUPacket(data: data)

        XCTAssertEqual(packet.weightKilograms, 70, accuracy: 0.000_1)
        XCTAssertTrue(packet.isStable)
        XCTAssertNil(packet.impedanceRawCode)
        XCTAssertEqual(packet.diagnosticOpcode, 0xD5)
    }

    func testParsesDynamicPacket() throws {
        let data = Data([0xAC, 0x00, 0x00, 0x68, 0xC3, 0x50, 0x00, 0x00, 0x02, 0x58])

        let packet = try AFUPacket(data: data)

        XCTAssertEqual(packet.weightKilograms, 50.0, accuracy: 0.000_1)
        XCTAssertFalse(packet.isStable)
        XCTAssertEqual(packet.impedanceRawCode, 600)
    }

    func testStableWeightWithoutImpedanceStillParses() throws {
        let data = Data([0xAC, 0x00, 0x00, 0x68, 0xEA, 0x60, 0x02, 0x00, 0x00, 0x00])

        let packet = try AFUPacket(data: data)

        XCTAssertEqual(packet.weightKilograms, 60.0, accuracy: 0.000_1)
        XCTAssertTrue(packet.isStable)
        XCTAssertNil(packet.impedanceRawCode)
    }

    func testRejectsShortPacket() {
        XCTAssertThrowsError(try AFUPacket(data: Data([0xAC, 0x01]))) { error in
            XCTAssertEqual(error as? AFUPacketError, .packetTooShort(actual: 2))
        }
    }

    func testRejectsWrongMagic() {
        let data = Data([0xAD, 0x00, 0x00, 0x69, 0x11, 0x70, 0x02, 0x00, 0x03, 0x20])

        XCTAssertThrowsError(try AFUPacket(data: data)) { error in
            XCTAssertEqual(error as? AFUPacketError, .invalidMagic(actual: 0xAD))
        }
    }

    func testRejectsWeightPrefixBelowProtocolBase() {
        let data = Data([0xAC, 0x00, 0x00, 0x67, 0xFF, 0xFF, 0x02, 0x00, 0x03, 0x20])

        XCTAssertThrowsError(try AFUPacket(data: data)) { error in
            XCTAssertEqual(error as? AFUPacketError, .invalidWeightEncoding)
        }
    }

    func testRejectsImplausibleWeight() {
        let data = Data([0xAC, 0x00, 0x00, 0x6C, 0x93, 0xE1, 0x02, 0x00, 0x03, 0x20])

        XCTAssertThrowsError(try AFUPacket(data: data)) { error in
            guard case let AFUPacketError.implausibleWeight(value) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(value, 300.001, accuracy: 0.000_1)
        }
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
