import Foundation

public enum AFUPacketError: Error, Equatable, Sendable {
    case packetTooShort(actual: Int)
    case invalidMagic(actual: UInt8)
    case unsupportedPacketType(actual: UInt8)
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
        case let .unsupportedPacketType(actual):
            return String(format: "AFU packet has unsupported type: 0x%02X", actual)
        case .invalidWeightEncoding:
            return "AFU packet contains an invalid weight prefix"
        case let .implausibleWeight(value):
            return String(format: "AFU packet weight is outside the supported range: %.3f kg", value)
        }
    }
}

public enum AFUPacketKind: String, Equatable, Sendable {
    case liveWeight
    case finalResult
    case history
}

public struct AFUPacket: Equatable, Sendable {
    public let kind: AFUPacketKind
    public let weightKilograms: Double
    public let isStable: Bool
    /// First unsigned ADC value from a final or history result. Its physical unit is unknown.
    public let impedanceRawCode: Int?
    /// Device timestamp carried by a history result, when available.
    public let measuredAt: Date?
    /// Number of older history entries reported by the device after this entry.
    public let remainingHistoryCount: Int?
    public let rawHex: String
    public let diagnosticOpcode: UInt8?

    public init(data: Data) throws {
        guard data.count >= 10 else {
            throw AFUPacketError.packetTooShort(actual: data.count)
        }
        guard data[0] == 0xAC else {
            throw AFUPacketError.invalidMagic(actual: data[0])
        }

        let parsed: ParsedPacket
        if data.count >= 20 {
            switch data[18] {
            case 0xD5:
                parsed = try Self.parseLiveWeight(data)
            case 0xD6:
                parsed = try Self.parseFinalResult(data)
            case 0xD8:
                parsed = try Self.parseHistory(data)
            case let packetType:
                throw AFUPacketError.unsupportedPacketType(actual: packetType)
            }
        } else {
            parsed = try Self.parseLegacyWeight(data)
        }

        kind = parsed.kind
        weightKilograms = parsed.weightKilograms
        isStable = parsed.isStable
        impedanceRawCode = parsed.impedanceRawCode
        measuredAt = parsed.measuredAt
        remainingHistoryCount = parsed.remainingHistoryCount
        rawHex = data.map { String(format: "%02X", $0) }.joined()
        diagnosticOpcode = data.count >= 19 ? data[18] : nil
    }

    private struct ParsedPacket {
        let kind: AFUPacketKind
        let weightKilograms: Double
        let isStable: Bool
        let impedanceRawCode: Int?
        let measuredAt: Date?
        let remainingHistoryCount: Int?
    }

    private static func parseLiveWeight(_ data: Data) throws -> ParsedPacket {
        let weightKilograms = try decodeWeight(data[3], data[4], data[5])
        return ParsedPacket(
            kind: .liveWeight,
            weightKilograms: weightKilograms,
            isStable: data[2] & 0x80 != 0 && weightKilograms > 0,
            impedanceRawCode: nil,
            measuredAt: nil,
            remainingHistoryCount: nil
        )
    }

    private static func parseFinalResult(_ data: Data) throws -> ParsedPacket {
        let weightKilograms = try decodeWeight(data[10], data[11], data[12])
        let impedanceRawCode = data[2] > 0 ? nonzeroUInt16(data[4], data[5]) : nil
        return ParsedPacket(
            kind: .finalResult,
            weightKilograms: weightKilograms,
            isStable: weightKilograms > 0,
            impedanceRawCode: impedanceRawCode,
            measuredAt: nil,
            remainingHistoryCount: nil
        )
    }

    private static func parseHistory(_ data: Data) throws -> ParsedPacket {
        let historyType = data[2]
        let timestamp = uint32(data[3], data[4], data[5], data[6])
        let weightKilograms = try decodeWeight(data[8], data[9], data[10])
        let resultDetails: (impedanceRawCode: Int?, remainingHistoryCount: Int?)

        switch historyType {
        case 0:
            let count = data[14]
            resultDetails = (
                count > 0 ? nonzeroUInt16(data[15], data[16]) : nil,
                nil
            )
        case 2:
            let count = data[12]
            resultDetails = (
                count > 0 ? nonzeroUInt16(data[13], data[14]) : nil,
                Int(data[11])
            )
        default:
            resultDetails = (nonzeroUInt16(data[11], data[12]), nil)
        }

        return ParsedPacket(
            kind: .history,
            weightKilograms: weightKilograms,
            isStable: weightKilograms > 0,
            impedanceRawCode: resultDetails.impedanceRawCode,
            measuredAt: timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil,
            remainingHistoryCount: resultDetails.remainingHistoryCount
        )
    }

    private static func parseLegacyWeight(_ data: Data) throws -> ParsedPacket {
        let weightKilograms = try decodeWeight(data[3], data[4], data[5])
        let impedanceRawCode = nonzeroUInt16(data[8], data[9])
        return ParsedPacket(
            kind: .liveWeight,
            weightKilograms: weightKilograms,
            isStable: data[6] == 0x02 && weightKilograms > 0,
            impedanceRawCode: impedanceRawCode,
            measuredAt: nil,
            remainingHistoryCount: nil
        )
    }

    private static func decodeWeight(_ high: UInt8, _ middle: UInt8, _ low: UInt8) throws -> Double {
        guard high >= 0x68 else {
            throw AFUPacketError.invalidWeightEncoding
        }
        let rawWeight = (Int(high) - 0x68) * 65_536 + Int(middle) * 256 + Int(low)
        let weightKilograms = Double(rawWeight) / 1_000.0
        guard weightKilograms <= 300.0 else {
            throw AFUPacketError.implausibleWeight(weightKilograms)
        }
        return weightKilograms
    }

    private static func nonzeroUInt16(_ high: UInt8, _ low: UInt8) -> Int? {
        let value = Int(high) * 256 + Int(low)
        return value > 0 ? value : nil
    }

    private static func uint32(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }
}
