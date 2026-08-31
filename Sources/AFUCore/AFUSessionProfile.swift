import Foundation

public enum AFUSessionProfileError: Error, Equatable, Sendable {
    case advertisementTooShort(actual: Int)
    case invalidManufacturerMagic(actual: UInt8)
    case unsupportedScale(category: UInt8, subtype: UInt8)
    case invalidHeight(Double)
    case unsupportedAge(Int)
    case invalidWeightKilograms(Double)
    case invalidTimestamp(TimeInterval)
    case invalidTimezoneOffset(seconds: Int)
}

extension AFUSessionProfileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .advertisementTooShort(actual):
            return "AFU manufacturer data is too short: \(actual) bytes"
        case let .invalidManufacturerMagic(actual):
            return String(format: "AFU manufacturer data has invalid magic byte: 0x%02X", actual)
        case let .unsupportedScale(category, subtype):
            return "AFU scale protocol is unsupported: category=\(category), subtype=\(subtype)"
        case let .invalidHeight(value):
            return "AFU session profile height is outside 100 through 250 cm: \(value)"
        case let .unsupportedAge(value):
            return "AFU session profile age is outside 18 through 80: \(value)"
        case let .invalidWeightKilograms(value):
            return "AFU session weight is outside the protocol range: \(value)"
        case let .invalidTimestamp(value):
            return "AFU session timestamp is outside the UInt32 range: \(value)"
        case let .invalidTimezoneOffset(seconds):
            return "AFU session timezone offset is outside the Int8 quarter-hour range: \(seconds) seconds"
        }
    }
}

public enum AFUAdvertisementCommunicationType: String, Equatable, Sendable {
    case connect
    case broadcast
}

public struct AFUAdvertisementProtocolMetadata: Equatable, Sendable {
    public let communicationType: AFUAdvertisementCommunicationType
    public let category: UInt8
    public let subtype: UInt8
    public let protocolVersion: UInt8?

    public init(manufacturerData: Data) throws {
        guard manufacturerData.count >= 2 else {
            throw AFUSessionProfileError.advertisementTooShort(actual: manufacturerData.count)
        }
        guard manufacturerData[0] == 0xAC else {
            throw AFUSessionProfileError.invalidManufacturerMagic(actual: manufacturerData[0])
        }

        let flags = manufacturerData[1]
        let category = (flags & 0x70) >> 4
        let subtype = flags & 0x0F
        guard category == 2, subtype == 7 else {
            throw AFUSessionProfileError.unsupportedScale(category: category, subtype: subtype)
        }

        communicationType = flags & 0x80 == 0 ? .connect : .broadcast
        self.category = category
        self.subtype = subtype
        protocolVersion = manufacturerData.count >= 9 ? manufacturerData[8] : nil
    }

    public var sessionDeviceType: UInt8 {
        subtype | (communicationType == .connect ? 0x20 : 0xA0)
    }
}

public enum AFUSessionDeviceType {
    public static let referenceConnect: UInt8 = 0x27

    public static func resolved(
        from metadata: AFUAdvertisementProtocolMetadata?
    ) -> UInt8 {
        metadata?.sessionDeviceType ?? referenceConnect
    }
}

public enum AFUSessionMode: Equatable, Sendable {
    case live
    case history

    public var persistsHistoricalMeasurements: Bool {
        self == .history
    }
}

public enum AFUSessionProfilePacket {
    public static func encode(
        deviceType: UInt8,
        profile: BodyProfile,
        currentWeightKilograms: Double = 60,
        targetWeightKilograms: Double = 50,
        at date: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> Data {
        let timestampValue = date.timeIntervalSince1970
        guard timestampValue.isFinite,
              timestampValue >= 0,
              timestampValue <= Double(UInt32.max)
        else {
            throw AFUSessionProfileError.invalidTimestamp(timestampValue)
        }
        let timestamp = UInt32(timestampValue.rounded(.towardZero))
        let fields = try profileFields(profile, at: date)
        let currentWeight = try centiKilograms(currentWeightKilograms)
        let targetWeight = try centiKilograms(targetWeightKilograms)

        let timezoneSeconds = timeZone.secondsFromGMT(for: date)
        let timezoneQuarters = timezoneSeconds / 900
        guard (Int(Int8.min) ... Int(Int8.max)).contains(timezoneQuarters) else {
            throw AFUSessionProfileError.invalidTimezoneOffset(seconds: timezoneSeconds)
        }

        var payload = Data()
        payload.reserveCapacity(20)
        payload.append(0xAC)
        payload.append(deviceType)
        payload.append(UInt8((timestamp >> 24) & 0xFF))
        payload.append(UInt8((timestamp >> 16) & 0xFF))
        payload.append(UInt8((timestamp >> 8) & 0xFF))
        payload.append(UInt8(timestamp & 0xFF))
        payload.append(UInt8(bitPattern: Int8(timezoneQuarters)))
        payload.append(0x00) // kilograms
        payload.append(0x01) // first local user
        payload.append(fields.height)
        payload.append(UInt8((currentWeight >> 8) & 0xFF))
        payload.append(UInt8(currentWeight & 0xFF))
        payload.append(fields.age)
        payload.append(profile.sex == .male ? 0x01 : 0x02)
        payload.append(UInt8((targetWeight >> 8) & 0xFF))
        payload.append(UInt8(targetWeight & 0xFF))
        payload.append(0x03) // enable impedance/body-fat functions
        payload.append(0x00)
        payload.append(0xD0)
        appendChecksum(to: &payload)
        return payload
    }
}

public enum AFUSessionUserPacket {
    public static func encode(
        deviceType: UInt8,
        profile: BodyProfile,
        currentWeightKilograms: Double = 60,
        at date: Date = Date()
    ) throws -> Data {
        let fields = try profileFields(profile, at: date)
        let currentWeight = try centiKilograms(currentWeightKilograms)

        var payload = Data()
        payload.reserveCapacity(20)
        payload.append(0xAC)
        payload.append(deviceType)
        payload.append(0x01) // one user in this packet
        payload.append(0x00) // first packet
        payload.append(0x01) // first local user
        payload.append(fields.height)
        payload.append(UInt8((currentWeight >> 8) & 0xFF))
        payload.append(UInt8(currentWeight & 0xFF))
        payload.append(fields.age)
        payload.append(profile.sex == .male ? 0x01 : 0x02)
        payload.append(contentsOf: repeatElement(UInt8(0), count: 8))
        payload.append(0xD1)
        appendChecksum(to: &payload)
        return payload
    }
}

public enum AFUSessionInitializationPackets {
    public static func encode(
        mode: AFUSessionMode,
        deviceType: UInt8,
        profile: BodyProfile,
        currentWeightKilograms: Double = 60,
        at date: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> [Data] {
        let profilePacket = try AFUSessionProfilePacket.encode(
            deviceType: deviceType,
            profile: profile,
            currentWeightKilograms: currentWeightKilograms,
            targetWeightKilograms: currentWeightKilograms,
            at: date,
            timeZone: timeZone
        )
        guard mode == .history else { return [profilePacket] }

        let userPacket = try AFUSessionUserPacket.encode(
            deviceType: deviceType,
            profile: profile,
            currentWeightKilograms: currentWeightKilograms,
            at: date
        )
        return [userPacket, profilePacket, userPacket, profilePacket]
    }
}

private func profileFields(
    _ profile: BodyProfile,
    at date: Date
) throws -> (height: UInt8, age: UInt8) {
    let roundedHeight = profile.heightCentimeters.rounded()
    guard (100 ... 250).contains(profile.heightCentimeters),
          roundedHeight >= 0,
          roundedHeight <= Double(UInt8.max)
    else {
        throw AFUSessionProfileError.invalidHeight(profile.heightCentimeters)
    }

    let age = BodyCompositionCalculator.ageYears(birthDate: profile.birthDate, at: date)
    guard (18 ... 80).contains(age) else {
        throw AFUSessionProfileError.unsupportedAge(age)
    }
    return (UInt8(roundedHeight), UInt8(age))
}

private func centiKilograms(_ value: Double) throws -> UInt16 {
    let scaled = value * 100
    guard value.isFinite,
          value >= 0,
          scaled <= Double(UInt16.max)
    else {
        throw AFUSessionProfileError.invalidWeightKilograms(value)
    }
    return UInt16(scaled.rounded())
}

private func appendChecksum(to payload: inout Data) {
    payload.append(payload[2 ... 18].reduce(UInt8(0), &+))
}
