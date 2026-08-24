import Foundation

public enum ManagedOutputError: Error, Equatable, Sendable {
    case missingFile(String)
    case unmanagedFile(String)
    case invalidSchema(Int)
    case invalidStoreID(String)
    case storeIDMismatch(expected: String, actual: String)
}

extension ManagedOutputError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .missingFile(path):
            return "Managed output does not exist: \(path)"
        case let .unmanagedFile(path):
            return "Refusing to overwrite a file not managed by AFU Scale Reader: \(path)"
        case let .invalidSchema(schema):
            return "Unsupported AFU Scale Reader output schema: \(schema)"
        case let .invalidStoreID(value):
            return "Managed output contains an invalid store identifier: \(value)"
        case let .storeIDMismatch(expected, actual):
            return "Managed output belongs to another store (expected \(expected), found \(actual))"
        }
    }
}

public enum ManagedOutput {
    public static let schema = 1
    private static let markdownPrefix = "<!-- afu-scale-reader: "
    private static let markdownSuffix = " -->"

    public static func initialize(
        outputURL: URL,
        canonicalURL: URL,
        format: OutputFormat,
        storeID: UUID
    ) throws {
        let outputData = try managedOrInitialData(
            fileURL: outputURL,
            format: format,
            storeID: storeID
        )

        if let canonicalData = try existingNonblankData(at: canonicalURL) {
            try validate(data: canonicalData, fileURL: canonicalURL, format: format, storeID: storeID)
            try SecureFile.protect(canonicalURL)
        } else {
            try SecureFile.write(outputData, to: canonicalURL)
        }
    }

    public static func ensureManaged(
        fileURL: URL,
        format: OutputFormat,
        storeID: UUID
    ) throws {
        _ = try managedOrInitialData(fileURL: fileURL, format: format, storeID: storeID)
    }

    public static func validate(
        fileURL: URL,
        format: OutputFormat,
        storeID: UUID
    ) throws {
        guard let data = try existingNonblankData(at: fileURL) else {
            throw ManagedOutputError.missingFile(fileURL.path)
        }
        try validate(data: data, fileURL: fileURL, format: format, storeID: storeID)
        try SecureFile.protect(fileURL)
    }

    public static func validate(
        data: Data,
        fileURL: URL,
        format: OutputFormat,
        storeID: UUID
    ) throws {
        let marker: Marker
        switch format {
        case .markdown:
            guard let text = String(data: data, encoding: .utf8),
                  let line = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .first(where: { $0.hasPrefix(markdownPrefix) && $0.hasSuffix(markdownSuffix) })
            else {
                throw ManagedOutputError.unmanagedFile(fileURL.path)
            }
            let start = line.index(line.startIndex, offsetBy: markdownPrefix.count)
            let end = line.index(line.endIndex, offsetBy: -markdownSuffix.count)
            guard let markerData = String(line[start ..< end]).data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Marker.self, from: markerData)
            else {
                throw ManagedOutputError.unmanagedFile(fileURL.path)
            }
            marker = decoded
        case .json:
            guard let decoded = try? JSONDecoder().decode(Marker.self, from: data) else {
                throw ManagedOutputError.unmanagedFile(fileURL.path)
            }
            marker = decoded
        }

        guard marker.schema == schema else {
            throw ManagedOutputError.invalidSchema(marker.schema)
        }
        guard let actualStoreID = UUID(uuidString: marker.storeID) else {
            throw ManagedOutputError.invalidStoreID(marker.storeID)
        }
        guard actualStoreID == storeID else {
            throw ManagedOutputError.storeIDMismatch(
                expected: storeID.uuidString.lowercased(),
                actual: marker.storeID
            )
        }
    }

    public static func initialData(format: OutputFormat, storeID: UUID) throws -> Data {
        let marker = Marker(schema: schema, storeID: storeID.uuidString.lowercased())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        switch format {
        case .markdown:
            let markerData = try encoder.encode(marker)
            let markerJSON = String(decoding: markerData, as: UTF8.self)
            return Data("# 阿福体脂秤测量记录\n\n\(markdownPrefix)\(markerJSON)\(markdownSuffix)\n".utf8)
        case .json:
            let document = EmptyJSONDocument(
                schema: schema,
                storeID: storeID.uuidString.lowercased(),
                measurements: []
            )
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(document)
            data.append(0x0A)
            return data
        }
    }

    private static func managedOrInitialData(
        fileURL: URL,
        format: OutputFormat,
        storeID: UUID
    ) throws -> Data {
        if let data = try existingNonblankData(at: fileURL) {
            try validate(data: data, fileURL: fileURL, format: format, storeID: storeID)
            try SecureFile.protect(fileURL)
            return data
        }
        let data = try initialData(format: format, storeID: storeID)
        try SecureFile.write(data, to: fileURL)
        return data
    }

    private static func existingNonblankData(at fileURL: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return nil }
        if let text = String(data: data, encoding: .utf8),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return nil
        }
        return data
    }
}

private struct Marker: Codable {
    let schema: Int
    let storeID: String

    enum CodingKeys: String, CodingKey {
        case schema
        case storeID = "store_id"
    }
}

private struct EmptyJSONDocument: Codable {
    let schema: Int
    let storeID: String
    let measurements: [EmptyMeasurement]

    enum CodingKeys: String, CodingKey {
        case schema
        case storeID = "store_id"
        case measurements
    }
}

private struct EmptyMeasurement: Codable {}
