import Foundation

public enum AFUPacketError: Error, Equatable, Sendable {
    case packetTooShort(actual: Int)
    case invalidMagic(actual: UInt8)
    case invalidWeightEncoding
    case implausibleWeight(Double)
}

extension AFUPacketError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .packetTooShort(actual):
            return "AFU packet is too short: \(actual) bytes (minimum 10)"
        case let .invalidMagic(actual):
            return String(format: "AFU packet has invalid magic byte: 0x%02X", actual)
        case .invalidWeightEncoding:
            return "AFU packet contains an invalid weight prefix"
        case let .implausibleWeight(value):
            return String(format: "AFU packet weight is outside the supported range: %.3f kg", value)
        }
    }
}

public struct AFUPacket: Equatable, Sendable {
    public let weightKilograms: Double
    public let isStable: Bool
    /// Unsigned value from bytes 8-9. Its conversion to physical ohms is unknown.
    public let impedanceRawCode: Int?
    public let rawHex: String
    public let diagnosticOpcode: UInt8?

    public static func isMeasurementCompletion(_ data: Data) -> Bool {
        data.count >= 19 && data[0] == 0xAC && data[18] == 0xD6
    }

    public init(data: Data) throws {
        guard data.count >= 10 else {
            throw AFUPacketError.packetTooShort(actual: data.count)
        }
        guard data[0] == 0xAC else {
            throw AFUPacketError.invalidMagic(actual: data[0])
        }
        guard data[3] >= 0x68 else {
            throw AFUPacketError.invalidWeightEncoding
        }

        let rawWeight = (Int(data[3]) - 0x68) * 65_536
            + Int(data[4]) * 256
            + Int(data[5])
        let weightKilograms = Double(rawWeight) / 1_000.0
        guard weightKilograms <= 300.0 else {
            throw AFUPacketError.implausibleWeight(weightKilograms)
        }

        let rawCode = Int(data[8]) * 256 + Int(data[9])
        self.weightKilograms = weightKilograms
        isStable = data[6] == 0x02 && weightKilograms > 0
        impedanceRawCode = rawCode > 0 ? rawCode : nil
        rawHex = data.map { String(format: "%02X", $0) }.joined()
        diagnosticOpcode = data.count >= 19 ? data[18] : nil
    }
}
