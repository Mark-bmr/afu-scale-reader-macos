import Foundation

public struct MeasurementRecord: Equatable, Sendable {
    public let measurement: StableMeasurement
    public let composition: BodyComposition

    public init(measurement: StableMeasurement, composition: BodyComposition) {
        self.measurement = measurement
        self.composition = composition
    }
}

public struct MarkdownStore: Sendable {
    private static let tableHeader = "| 时间 | 体重 (kg) | BMI | 内脏脂肪 | 体脂率 (%) | 脂肪量 (kg) | 肌肉率 (%) | 肌肉量 (kg) | 体水分率 (%) | 体水分量 (kg) | 蛋白质占比 (%) | 蛋白质含量 (kg) | 骨量占比 (%) | 骨量 (kg) | 骨骼肌量 (kg) | 骨骼肌率 (%) | 皮下脂肪率 (%) | 皮下脂肪量 (kg) |"
    private static let tableSeparator = "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"

    public let fileURL: URL
    public let canonicalFileURL: URL?
    public let storeID: UUID
    public let deduplicationWindow: TimeInterval
    public let timeZone: TimeZone

    public init(
        fileURL: URL,
        canonicalFileURL: URL? = nil,
        storeID: UUID,
        deduplicationWindow: TimeInterval = 120,
        timeZone: TimeZone = .current
    ) {
        self.fileURL = fileURL
        self.canonicalFileURL = canonicalFileURL
        self.storeID = storeID
        self.deduplicationWindow = deduplicationWindow
        self.timeZone = timeZone
    }

    @discardableResult
    public func append(_ record: MeasurementRecord) throws -> Bool {
        try prepareManagedFiles()
        let existingText = try readExistingText()
        let deduplicator = MeasurementDeduplicator(window: deduplicationWindow)
        if deduplicator.isDuplicate(record.measurement.signature, comparedWith: lastSignature(in: existingText)) {
            return false
        }

        let renderedRow = try renderRow(record)
        var suffix = existingText.hasSuffix("\n") ? "" : "\n"
        if !containsTableHeader(in: existingText) {
            suffix += "\n\(Self.tableHeader)\n\(Self.tableSeparator)\n"
        }
        let updatedText = existingText + suffix + renderedRow + "\n"

        if let canonicalFileURL {
            try SecureFile.write(updatedText, to: canonicalFileURL)
        }
        try SecureFile.write(updatedText, to: fileURL)
        return true
    }

    @discardableResult
    public func restoreOutputFromCanonicalIfNeeded() throws -> Bool {
        guard let canonicalFileURL,
              FileManager.default.fileExists(atPath: canonicalFileURL.path)
        else {
            return false
        }

        try ManagedOutput.validate(
            fileURL: canonicalFileURL,
            format: .markdown,
            storeID: storeID
        )
        let canonicalData = try Data(contentsOf: canonicalFileURL)
        let outputData = try nonblankData(at: fileURL)
        if let outputData {
            try ManagedOutput.validate(
                data: outputData,
                fileURL: fileURL,
                format: .markdown,
                storeID: storeID
            )
            guard outputData != canonicalData else {
                try SecureFile.protect(fileURL)
                return false
            }
        }

        try SecureFile.write(canonicalData, to: fileURL)
        return true
    }

    private func prepareManagedFiles() throws {
        if let canonicalFileURL {
            try ManagedOutput.initialize(
                outputURL: fileURL,
                canonicalURL: canonicalFileURL,
                format: .markdown,
                storeID: storeID
            )
        } else {
            try ManagedOutput.ensureManaged(fileURL: fileURL, format: .markdown, storeID: storeID)
        }
    }

    private func readExistingText() throws -> String {
        if let canonicalFileURL {
            return try String(contentsOf: canonicalFileURL, encoding: .utf8)
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private func lastSignature(in text: String) -> MeasurementSignature? {
        let prefix = "<!-- afu-meta: "
        let suffix = " -->"

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let value = String(line)
            guard let startRange = value.range(of: prefix, options: .backwards) else { continue }
            let remainder = value[startRange.upperBound...]
            guard let endRange = remainder.range(of: suffix) else { continue }
            let payload = String(remainder[..<endRange.lowerBound])
            guard let json = Data(base64Encoded: payload) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let metadata = try? decoder.decode(MarkdownMetadata.self, from: json),
                  metadata.storeID.caseInsensitiveCompare(storeID.uuidString) == .orderedSame
            else {
                continue
            }
            return metadata.signature
        }
        return nil
    }

    private func containsTableHeader(in text: String) -> Bool {
        guard let expectedCells = tableCells(in: Self.tableHeader) else { return false }
        return text.split(separator: "\n", omittingEmptySubsequences: false).contains {
            tableCells(in: String($0)) == expectedCells
        }
    }

    private func tableCells(in line: String) -> [String]? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLine.hasPrefix("|"), trimmedLine.hasSuffix("|") else { return nil }
        return trimmedLine.split(separator: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private func renderRow(_ record: MeasurementRecord) throws -> String {
        let measurement = record.measurement
        let composition = record.composition
        let metadata = MarkdownMetadata(
            measuredAt: measurement.measuredAt,
            weightKilograms: measurement.weightKilograms,
            impedanceRawCode: measurement.impedanceRawCode,
            algorithm: composition.algorithmVersion,
            mode: composition.mode.rawValue,
            storeID: storeID.uuidString.lowercased()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let metadataPayload = try encoder.encode(metadata).base64EncodedString()

        let cells = [
            formatDate(measurement.measuredAt),
            format(composition.weightKilograms),
            format(composition.bmi),
            format(composition.visceralFatIndex),
            format(composition.bodyFatPercentage),
            format(composition.fatMassKilograms),
            format(composition.musclePercentage),
            format(composition.muscleMassKilograms),
            format(composition.bodyWaterPercentage),
            format(composition.bodyWaterMassKilograms),
            format(composition.proteinPercentage),
            format(composition.proteinMassKilograms),
            format(composition.bonePercentage),
            format(composition.boneMassKilograms),
            format(composition.skeletalMuscleMassKilograms),
            format(composition.skeletalMusclePercentage),
            format(composition.subcutaneousFatPercentage),
            "\(format(composition.subcutaneousFatMassKilograms)) <!-- afu-meta: \(metadataPayload) -->"
        ]
        return "| " + cells.joined(separator: " | ") + " |"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func nonblankData(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return nil }
        if let text = String(data: data, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return nil
        }
        return data
    }
}

private struct MarkdownMetadata: Codable {
    let measuredAt: Date
    let weightKilograms: Double
    let impedanceRawCode: Int?
    let algorithm: String
    let mode: String
    let storeID: String

    var signature: MeasurementSignature {
        MeasurementSignature(
            measuredAt: measuredAt,
            weightKilograms: weightKilograms,
            impedanceRawCode: impedanceRawCode,
            deviceName: ""
        )
    }

    enum CodingKeys: String, CodingKey {
        case measuredAt = "measured_at"
        case weightKilograms = "weight_kg"
        case impedanceRawCode = "impedance_raw"
        case algorithm
        case mode
        case storeID = "store_id"
    }
}
