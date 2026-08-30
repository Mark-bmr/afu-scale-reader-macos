import Foundation

public enum MeasurementTimeSource: String, Codable, Equatable, Sendable {
    case received
    case device
}

public struct StableMeasurement: Equatable, Sendable {
    public let measuredAt: Date
    public let weightKilograms: Double
    public let impedanceRawCode: Int?
    public let rawHex: String
    public let deviceName: String
    public let timeSource: MeasurementTimeSource

    public init(
        measuredAt: Date,
        weightKilograms: Double,
        impedanceRawCode: Int?,
        rawHex: String,
        deviceName: String,
        timeSource: MeasurementTimeSource = .received
    ) {
        self.measuredAt = measuredAt
        self.weightKilograms = weightKilograms
        self.impedanceRawCode = impedanceRawCode
        self.rawHex = rawHex
        self.deviceName = deviceName
        self.timeSource = timeSource
    }

    public var signature: MeasurementSignature {
        MeasurementSignature(
            measuredAt: measuredAt,
            weightKilograms: weightKilograms,
            impedanceRawCode: impedanceRawCode,
            deviceName: deviceName,
            timeSource: timeSource
        )
    }
}

public struct MeasurementSignature: Codable, Equatable, Sendable {
    public let measuredAt: Date
    public let weightKilograms: Double
    public let impedanceRawCode: Int?
    public let deviceName: String
    public let timeSource: MeasurementTimeSource

    public init(
        measuredAt: Date,
        weightKilograms: Double,
        impedanceRawCode: Int?,
        deviceName: String,
        timeSource: MeasurementTimeSource = .received
    ) {
        self.measuredAt = measuredAt
        self.weightKilograms = weightKilograms
        self.impedanceRawCode = impedanceRawCode
        self.deviceName = deviceName
        self.timeSource = timeSource
    }
}

public struct MeasurementDeduplicator: Sendable {
    public let window: TimeInterval
    public let weightTolerance: Double

    public init(window: TimeInterval = 120, weightTolerance: Double = 0.005) {
        self.window = window
        self.weightTolerance = weightTolerance
    }

    public func isDuplicate(
        _ candidate: MeasurementSignature,
        comparedWith previous: MeasurementSignature?
    ) -> Bool {
        guard let previous else { return false }
        guard candidate.impedanceRawCode == previous.impedanceRawCode else { return false }
        guard abs(candidate.weightKilograms - previous.weightKilograms) <= weightTolerance else {
            return false
        }

        let elapsed = candidate.measuredAt.timeIntervalSince(previous.measuredAt)
        if candidate.timeSource == .device, previous.timeSource == .device {
            return elapsed == 0
        }
        if candidate.timeSource != previous.timeSource {
            return abs(elapsed) <= window
        }
        return elapsed >= 0 && elapsed <= window
    }

    public func isDuplicate(
        _ candidate: MeasurementSignature,
        comparedWith previous: [MeasurementSignature]
    ) -> Bool {
        let comparisons: ArraySlice<MeasurementSignature>
        if candidate.timeSource == .device {
            comparisons = previous[...]
        } else {
            comparisons = previous.suffix(1)
        }
        return comparisons.contains { isDuplicate(candidate, comparedWith: $0) }
    }
}

public struct MeasurementSessionTracker: Sendable {
    private enum State: Sendable {
        case idle
        case measuring
        case emitted
    }

    private struct StableCandidate: Sendable {
        var measurement: StableMeasurement
        var matchingSamples: Int
        let deadline: Date
        let expectsFinalResult: Bool
    }

    public let settleInterval: TimeInterval
    public var isAwaitingFinalResult: Bool {
        candidate?.expectsFinalResult == true
    }

    private let minimumMatchingSamples = 3
    private let weightTolerance = 0.005
    private var state: State = .idle
    private var candidate: StableCandidate?

    public init(settleInterval: TimeInterval = 2) {
        self.settleInterval = max(settleInterval, 0)
    }

    public mutating func receive(
        _ packet: AFUPacket,
        at receivedAt: Date,
        deviceName: String
    ) -> StableMeasurement? {
        if packet.weightKilograms < 1 {
            let measurement = convergedCandidateMeasurement()
            candidate = nil
            state = .idle
            return measurement
        }

        guard state != .emitted else { return nil }

        guard packet.isStable else {
            candidate = nil
            if state == .idle {
                state = .measuring
            }
            return nil
        }

        let isMatchingCandidate = candidate.map {
            $0.measurement.deviceName == deviceName
                && abs($0.measurement.weightKilograms - packet.weightKilograms) <= weightTolerance
        } ?? false
        let firstStableAt = isMatchingCandidate ? candidate?.measurement.measuredAt ?? receivedAt : receivedAt
        let impedanceRawCode = packet.impedanceRawCode
            ?? (isMatchingCandidate ? candidate?.measurement.impedanceRawCode : nil)
        let stableMeasurement = StableMeasurement(
            measuredAt: firstStableAt,
            weightKilograms: packet.weightKilograms,
            impedanceRawCode: impedanceRawCode,
            rawHex: packet.rawHex,
            deviceName: deviceName
        )

        if isMatchingCandidate, var candidate {
            candidate.measurement = stableMeasurement
            candidate.matchingSamples += 1
            self.candidate = candidate
        } else {
            candidate = StableCandidate(
                measurement: stableMeasurement,
                matchingSamples: 1,
                deadline: receivedAt.addingTimeInterval(settleInterval),
                expectsFinalResult: packet.diagnosticOpcode == 0xD5
            )
        }
        state = .measuring

        guard let candidate, candidate.matchingSamples >= minimumMatchingSamples else {
            return nil
        }

        if candidate.measurement.impedanceRawCode != nil
            || (!candidate.expectsFinalResult && receivedAt >= candidate.deadline)
        {
            self.candidate = nil
            state = .emitted
            return candidate.measurement
        }
        return nil
    }

    public mutating func flushIfDue(at date: Date) -> StableMeasurement? {
        guard state != .emitted,
              let candidate,
              !candidate.expectsFinalResult,
              candidate.matchingSamples >= minimumMatchingSamples,
              date >= candidate.deadline
        else {
            return nil
        }
        self.candidate = nil
        state = .emitted
        return candidate.measurement
    }

    public mutating func receiveFinalResult(
        _ packet: AFUPacket,
        at receivedAt: Date,
        deviceName: String
    ) -> StableMeasurement? {
        guard packet.kind == .finalResult || packet.kind == .history else {
            return nil
        }

        candidate = nil
        state = .idle
        guard packet.weightKilograms >= 1 else { return nil }

        return StableMeasurement(
            measuredAt: packet.measuredAt ?? receivedAt,
            weightKilograms: packet.weightKilograms,
            impedanceRawCode: packet.impedanceRawCode,
            rawHex: packet.rawHex,
            deviceName: deviceName,
            timeSource: packet.kind == .history && packet.measuredAt != nil ? .device : .received
        )
    }

    public mutating func disconnect(at _: Date) -> StableMeasurement? {
        endSession()
    }

    public mutating func connectionInterrupted(at _: Date) -> StableMeasurement? {
        guard isAwaitingFinalResult else {
            return endSession()
        }
        return nil
    }

    public mutating func measurementCompleted(at _: Date) -> StableMeasurement? {
        endSession()
    }

    private mutating func endSession() -> StableMeasurement? {
        let measurement = convergedCandidateMeasurement()
        candidate = nil
        state = .idle
        return measurement
    }

    private func convergedCandidateMeasurement() -> StableMeasurement? {
        guard let candidate, candidate.matchingSamples >= minimumMatchingSamples else {
            return nil
        }
        return candidate.measurement
    }
}
