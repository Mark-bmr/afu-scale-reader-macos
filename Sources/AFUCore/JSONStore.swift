import Foundation

public struct JSONStore: Sendable {
    public let fileURL: URL
    public let canonicalFileURL: URL?
    public let storeID: UUID
    public let deduplicationWindow: TimeInterval

    public init(
        fileURL: URL,
        canonicalFileURL: URL? = nil,
        storeID: UUID,
        deduplicationWindow: TimeInterval = 120
    ) {
        self.fileURL = fileURL
        self.canonicalFileURL = canonicalFileURL
        self.storeID = storeID
        self.deduplicationWindow = deduplicationWindow
    }

    @discardableResult
    public func append(_ record: MeasurementRecord) throws -> Bool {
        try prepareManagedFiles()
        var document = try readDocument()
        let deduplicator = MeasurementDeduplicator(window: deduplicationWindow)
        if deduplicator.isDuplicate(
            record.measurement.signature,
            comparedWith: document.measurements.map(\.signature)
        ) {
            return false
        }

        document.measurements.append(JSONMeasurement(record: record))
        let data = try encode(document)
        if let canonicalFileURL {
            try SecureFile.write(data, to: canonicalFileURL)
        }
        try SecureFile.write(data, to: fileURL)
        return true
    }

    @discardableResult
    public func restoreOutputFromCanonicalIfNeeded() throws -> Bool {
        guard let canonicalFileURL,
              FileManager.default.fileExists(atPath: canonicalFileURL.path)
        else {
            return false
        }

        try ManagedOutput.validate(fileURL: canonicalFileURL, format: .json, storeID: storeID)
        let canonicalData = try Data(contentsOf: canonicalFileURL)
        let outputData = try nonblankData(at: fileURL)
        if let outputData {
            try ManagedOutput.validate(
                data: outputData,
                fileURL: fileURL,
                format: .json,
                storeID: storeID
            )
            guard outputData == canonicalData else {
                try SecureFile.write(canonicalData, to: fileURL)
                return true
            }
            try SecureFile.protect(fileURL)
            return false
        }

        try SecureFile.write(canonicalData, to: fileURL)
        return true
    }

    public func latestWeightKilograms() throws -> Double? {
        let sourceURL = canonicalFileURL ?? fileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return nil
        }
        return try readDocument().measurements.last?.weightKilograms
    }

    private func prepareManagedFiles() throws {
        if let canonicalFileURL {
            try ManagedOutput.initialize(
                outputURL: fileURL,
                canonicalURL: canonicalFileURL,
                format: .json,
                storeID: storeID
            )
        } else {
            try ManagedOutput.ensureManaged(fileURL: fileURL, format: .json, storeID: storeID)
        }
    }

    private func readDocument() throws -> JSONDocument {
        let sourceURL = canonicalFileURL ?? fileURL
        let data = try Data(contentsOf: sourceURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(JSONDocument.self, from: data)
    }

    private func encode(_ document: JSONDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
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

private struct JSONDocument: Codable {
    let schema: Int
    let storeID: String
    var measurements: [JSONMeasurement]

    enum CodingKeys: String, CodingKey {
        case schema
        case storeID = "store_id"
        case measurements
    }
}

private struct JSONMeasurement: Codable {
    let measuredAt: Date
    let weightKilograms: Double
    let impedanceRawCode: Int?
    let timeSource: MeasurementTimeSource?
    let algorithm: String
    let mode: String
    let bmi: Double
    let visceralFatIndex: Double
    let bodyFatPercentage: Double
    let fatMassKilograms: Double
    let musclePercentage: Double
    let muscleMassKilograms: Double
    let bodyWaterPercentage: Double
    let bodyWaterMassKilograms: Double
    let proteinPercentage: Double
    let proteinMassKilograms: Double
    let bonePercentage: Double
    let boneMassKilograms: Double
    let skeletalMuscleMassKilograms: Double
    let skeletalMusclePercentage: Double
    let subcutaneousFatPercentage: Double
    let subcutaneousFatMassKilograms: Double

    init(record: MeasurementRecord) {
        let measurement = record.measurement
        let composition = record.composition
        measuredAt = measurement.measuredAt
        weightKilograms = measurement.weightKilograms
        impedanceRawCode = measurement.impedanceRawCode
        timeSource = measurement.timeSource
        algorithm = composition.algorithmVersion
        mode = composition.mode.rawValue
        bmi = composition.bmi
        visceralFatIndex = composition.visceralFatIndex
        bodyFatPercentage = composition.bodyFatPercentage
        fatMassKilograms = composition.fatMassKilograms
        musclePercentage = composition.musclePercentage
        muscleMassKilograms = composition.muscleMassKilograms
        bodyWaterPercentage = composition.bodyWaterPercentage
        bodyWaterMassKilograms = composition.bodyWaterMassKilograms
        proteinPercentage = composition.proteinPercentage
        proteinMassKilograms = composition.proteinMassKilograms
        bonePercentage = composition.bonePercentage
        boneMassKilograms = composition.boneMassKilograms
        skeletalMuscleMassKilograms = composition.skeletalMuscleMassKilograms
        skeletalMusclePercentage = composition.skeletalMusclePercentage
        subcutaneousFatPercentage = composition.subcutaneousFatPercentage
        subcutaneousFatMassKilograms = composition.subcutaneousFatMassKilograms
    }

    var signature: MeasurementSignature {
        MeasurementSignature(
            measuredAt: measuredAt,
            weightKilograms: weightKilograms,
            impedanceRawCode: impedanceRawCode,
            deviceName: "",
            timeSource: timeSource ?? .received
        )
    }

    enum CodingKeys: String, CodingKey {
        case measuredAt = "measured_at"
        case weightKilograms = "weight_kg"
        case impedanceRawCode = "impedance_raw"
        case timeSource = "time_source"
        case algorithm
        case mode
        case bmi
        case visceralFatIndex = "visceral_fat_index"
        case bodyFatPercentage = "body_fat_percent"
        case fatMassKilograms = "fat_mass_kg"
        case musclePercentage = "muscle_percent"
        case muscleMassKilograms = "muscle_mass_kg"
        case bodyWaterPercentage = "body_water_percent"
        case bodyWaterMassKilograms = "body_water_mass_kg"
        case proteinPercentage = "protein_percent"
        case proteinMassKilograms = "protein_mass_kg"
        case bonePercentage = "bone_percent"
        case boneMassKilograms = "bone_mass_kg"
        case skeletalMuscleMassKilograms = "skeletal_muscle_mass_kg"
        case skeletalMusclePercentage = "skeletal_muscle_percent"
        case subcutaneousFatPercentage = "subcutaneous_fat_percent"
        case subcutaneousFatMassKilograms = "subcutaneous_fat_mass_kg"
    }
}
