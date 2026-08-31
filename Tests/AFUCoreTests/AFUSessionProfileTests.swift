import Foundation
import XCTest
@testable import AFUCore

// All profiles, timestamps, and advertisements in this file are synthetic.
final class AFUSessionProfileTests: XCTestCase {
    func testParsesSupportedConnectAdvertisement() throws {
        let metadata = try AFUAdvertisementProtocolMetadata(
            manufacturerData: Data([0xAC, 0x27, 1, 2, 3, 4, 5, 6, 9])
        )

        XCTAssertEqual(metadata.communicationType, .connect)
        XCTAssertEqual(metadata.category, 2)
        XCTAssertEqual(metadata.subtype, 7)
        XCTAssertEqual(metadata.protocolVersion, 9)
        XCTAssertEqual(metadata.sessionDeviceType, 0x27)
    }

    func testParsesSupportedBroadcastAdvertisement() throws {
        let metadata = try AFUAdvertisementProtocolMetadata(
            manufacturerData: Data([0xAC, 0xA7])
        )

        XCTAssertEqual(metadata.communicationType, .broadcast)
        XCTAssertNil(metadata.protocolVersion)
        XCTAssertEqual(metadata.sessionDeviceType, 0xA7)
    }

    func testUsesReferenceConnectDeviceTypeWhenManufacturerMetadataIsUnavailable() {
        XCTAssertEqual(AFUSessionDeviceType.resolved(from: nil), 0x27)
    }

    func testRejectsInvalidOrUnsupportedAdvertisement() {
        XCTAssertThrowsError(try AFUAdvertisementProtocolMetadata(manufacturerData: Data([0xAC]))) {
            XCTAssertEqual($0 as? AFUSessionProfileError, .advertisementTooShort(actual: 1))
        }
        XCTAssertThrowsError(
            try AFUAdvertisementProtocolMetadata(manufacturerData: Data([0xAD, 0x27]))
        ) {
            XCTAssertEqual($0 as? AFUSessionProfileError, .invalidManufacturerMagic(actual: 0xAD))
        }
        XCTAssertThrowsError(
            try AFUAdvertisementProtocolMetadata(manufacturerData: Data([0xAC, 0x17]))
        ) {
            XCTAssertEqual(
                $0 as? AFUSessionProfileError,
                .unsupportedScale(category: 1, subtype: 7)
            )
        }
    }

    func testEncodesVendorReferenceD1UserPacket() throws {
        let packet = try AFUSessionUserPacket.encode(
            deviceType: 0x27,
            profile: profile(sex: .male, height: 170, birthDate: date("1990-01-01T00:00:00Z")),
            currentWeightKilograms: 70,
            at: Date(timeIntervalSince1970: 1_600_000_000)
        )

        XCTAssertEqual(packet, Data([
            0xAC, 0x27, 0x01, 0x00, 0x01, 0xAA, 0x1B, 0x58, 0x1E, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xD1, 0x0F
        ]))
    }

    func testEncodesVendorReferenceD0SessionPacket() throws {
        let packet = try AFUSessionProfilePacket.encode(
            deviceType: 0x27,
            profile: profile(sex: .male, height: 170, birthDate: date("1990-01-01T00:00:00Z")),
            currentWeightKilograms: 70,
            targetWeightKilograms: 65,
            at: Date(timeIntervalSince1970: 1_600_000_000),
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        )

        XCTAssertEqual(packet, Data([
            0xAC, 0x27, 0x5F, 0x5E, 0x10, 0x00, 0x20, 0x00, 0x01, 0xAA,
            0x1B, 0x58, 0x1E, 0x01, 0x19, 0x64, 0x03, 0x00, 0xD0, 0x7A
        ]))
    }

    func testBuildsSingleLiveProfilePacket() throws {
        let packets = try AFUSessionInitializationPackets.encode(
            mode: .live,
            deviceType: 0x27,
            profile: profile(sex: .male, height: 170, birthDate: date("1990-01-01T00:00:00Z")),
            currentWeightKilograms: 70,
            at: Date(timeIntervalSince1970: 1_600_000_000),
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        )

        XCTAssertEqual(packets.map { $0[18] }, [0xD0])
    }

    func testBuildsTwoHistoryInitializationRounds() throws {
        let packets = try AFUSessionInitializationPackets.encode(
            mode: .history,
            deviceType: 0x27,
            profile: profile(sex: .male, height: 170, birthDate: date("1990-01-01T00:00:00Z")),
            currentWeightKilograms: 70,
            at: Date(timeIntervalSince1970: 1_600_000_000),
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        )

        XCTAssertEqual(packets.map { $0[18] }, [0xD1, 0xD0, 0xD1, 0xD0])
        XCTAssertEqual(packets[0], packets[2])
        XCTAssertEqual(packets[1], packets[3])
    }

    func testOnlyHistoryModePersistsHistoricalMeasurements() {
        XCTAssertFalse(AFUSessionMode.live.persistsHistoricalMeasurements)
        XCTAssertTrue(AFUSessionMode.history.persistsHistoricalMeasurements)
    }

    func testEncodesNegativeTimezoneUsingTwosComplement() throws {
        let packet = try AFUSessionProfilePacket.encode(
            deviceType: 0x27,
            profile: profile(sex: .female, height: 170, birthDate: date("1990-01-01T00:00:00Z")),
            at: Date(timeIntervalSince1970: 1_600_000_000),
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: -8 * 3_600))
        )

        XCTAssertEqual(packet[6], 0xE0)
        XCTAssertEqual(packet[13], 0x02)
        XCTAssertEqual(packet[19], packet[2 ... 18].reduce(0, &+))
    }

    func testRejectsProfileAndTimestampOutsidePacketRange() {
        XCTAssertThrowsError(try AFUSessionProfilePacket.encode(
            deviceType: 0x27,
            profile: profile(sex: .male, height: 99, birthDate: date("1990-01-01T00:00:00Z")),
            at: Date(timeIntervalSince1970: 1_600_000_000),
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        )) {
            XCTAssertEqual($0 as? AFUSessionProfileError, .invalidHeight(99))
        }

        XCTAssertThrowsError(try AFUSessionProfilePacket.encode(
            deviceType: 0x27,
            profile: profile(sex: .male, height: 170, birthDate: date("2010-01-01T00:00:00Z")),
            at: Date(timeIntervalSince1970: 1_600_000_000),
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        )) {
            XCTAssertEqual($0 as? AFUSessionProfileError, .unsupportedAge(10))
        }

        XCTAssertThrowsError(try AFUSessionProfilePacket.encode(
            deviceType: 0x27,
            profile: profile(sex: .male, height: 170, birthDate: date("1990-01-01T00:00:00Z")),
            at: Date(timeIntervalSince1970: -1),
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        )) {
            guard case .invalidTimestamp = $0 as? AFUSessionProfileError else {
                return XCTFail("Expected invalidTimestamp, received \($0)")
            }
        }

        XCTAssertThrowsError(try AFUSessionInitializationPackets.encode(
            mode: .live,
            deviceType: 0x27,
            profile: profile(sex: .male, height: 170, birthDate: date("1990-01-01T00:00:00Z")),
            currentWeightKilograms: -1,
            at: Date(timeIntervalSince1970: 1_600_000_000),
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        )) {
            XCTAssertEqual($0 as? AFUSessionProfileError, .invalidWeightKilograms(-1))
        }

        XCTAssertThrowsError(try AFUSessionInitializationPackets.encode(
            mode: .live,
            deviceType: 0x27,
            profile: profile(sex: .male, height: 170, birthDate: date("1990-01-01T00:00:00Z")),
            currentWeightKilograms: .nan,
            at: Date(timeIntervalSince1970: 1_600_000_000),
            timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        )) {
            guard case let .invalidWeightKilograms(value) = $0 as? AFUSessionProfileError else {
                return XCTFail("Expected invalidWeightKilograms, received \($0)")
            }
            XCTAssertTrue(value.isNaN)
        }
    }

    private func profile(
        sex: BiologicalSex,
        height: Double,
        birthDate: Date
    ) -> BodyProfile {
        BodyProfile(sex: sex, heightCentimeters: height, birthDate: birthDate)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
