import Foundation
import XCTest
@testable import AFUCore

// All packets, timestamps, weights, and impedance values in this file are synthetic.
final class AFUPacketTests: XCTestCase {
    func testRecognizesWrappedD6MeasurementCompletion() {
        let completion = Data([
            0xAC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD6, 0x00
        ])
        let weight = Data([
            0xAC, 0x00, 0x00, 0x69, 0x11, 0x70, 0x02, 0x00, 0x03, 0x20,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD5, 0x00
        ])

        XCTAssertTrue(AFUPacket.isMeasurementCompletion(completion))
        XCTAssertFalse(AFUPacket.isMeasurementCompletion(weight))
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

    func testAcceptsTwentyBytePacketAndExposesDiagnosticOpcode() throws {
        let data = Data([
            0xAC, 0x00, 0x00, 0x69, 0x11, 0x70, 0x02, 0x00, 0x03, 0x20,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD5, 0x00
        ])

        let packet = try AFUPacket(data: data)

        XCTAssertEqual(packet.weightKilograms, 70, accuracy: 0.000_1)
        XCTAssertEqual(packet.impedanceRawCode, 800)
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
}
