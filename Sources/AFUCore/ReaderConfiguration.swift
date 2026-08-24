import Foundation

public enum AFUDeviceMatcher {
    public static func matches(
        peripheralName: String?,
        advertisedName: String?,
        requiredPrefix: String
    ) -> Bool {
        let prefix = requiredPrefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !prefix.isEmpty else { return false }

        return [peripheralName, advertisedName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .contains { $0.hasPrefix(prefix) }
    }
}

public enum OutputFormat: String, Codable, CaseIterable, Equatable, Sendable {
    case markdown = "md"
    case json

    public var pathExtension: String { rawValue }
}

public enum ReaderConfigurationError: Error, Equatable, Sendable {
    case fileNotFound(String)
    case unreadableFile(String)
    case invalidJSON
    case syntheticExample
    case missingField(String)
    case invalidSex(String)
    case invalidHeight(Double)
    case invalidBirthDate(String)
    case birthDateInFuture
    case unsupportedAge(Int)
    case invalidOutputPath(String)
    case invalidOutputFormat(String)
    case outputFormatMismatch(format: String, path: String)
    case invalidStoreID(String)
    case invalidDeviceNamePrefix
    case invalidInterval(field: String, value: Double)
}

extension ReaderConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            return "Configuration file does not exist: \(path)"
        case let .unreadableFile(path):
            return "Configuration file cannot be read: \(path)"
        case .invalidJSON:
            return "Configuration file is not valid JSON"
        case .syntheticExample:
            return "The bundled synthetic example is documentation only; run AFUReader --configure"
        case let .missingField(field):
            return "Configuration is missing required field: \(field)"
        case let .invalidSex(value):
            return "Configuration sex must be male or female; received \(value)"
        case let .invalidHeight(value):
            return "Configuration height_cm must be between 100 and 250; received \(value)"
        case let .invalidBirthDate(value):
            return "Configuration birth_date must use YYYY-MM-DD; received \(value)"
        case .birthDateInFuture:
            return "Configuration birth_date cannot be in the future"
        case let .unsupportedAge(value):
            return "Configuration profile must be age 18 through 80; received \(value)"
        case let .invalidOutputPath(path):
            return "Configuration output_path must be an absolute file path; received \(path)"
        case let .invalidOutputFormat(value):
            return "Configuration output_format must be md or json; received \(value)"
        case let .outputFormatMismatch(format, path):
            return "Configuration output format \(format) does not match the output path: \(path)"
        case let .invalidStoreID(value):
            return "Configuration store_id must be a UUID; received \(value)"
        case .invalidDeviceNamePrefix:
            return "Configuration device_name_prefix cannot be empty"
        case let .invalidInterval(field, value):
            return "Configuration \(field) must be greater than zero; received \(value)"
        }
    }
}

public struct ReaderConfiguration: Equatable, Sendable {
    public let deviceNamePrefix: String
    public let outputFileURL: URL
    public let outputFormat: OutputFormat
    public let storeID: UUID
    public let debugLogging: Bool
    public let measurementMirrorURL: URL
    public let logFileURL: URL
    public let profile: BodyProfile
    public let settleInterval: TimeInterval
    public let deduplicationWindow: TimeInterval
    public let connectionTimeout: TimeInterval
    public let retryDelay: TimeInterval

    public init(
        deviceNamePrefix: String = "AFU-WL",
        outputFileURL: URL,
        outputFormat: OutputFormat,
        storeID: UUID,
        debugLogging: Bool,
        configurationDirectoryURL: URL,
        profile: BodyProfile,
        settleInterval: TimeInterval = 2,
        deduplicationWindow: TimeInterval = 120,
        connectionTimeout: TimeInterval = 8,
        retryDelay: TimeInterval = 1
    ) {
        self.deviceNamePrefix = deviceNamePrefix
        self.outputFileURL = outputFileURL
        self.outputFormat = outputFormat
        self.storeID = storeID
        self.debugLogging = debugLogging
        measurementMirrorURL = configurationDirectoryURL
            .appendingPathComponent("measurements.\(outputFormat.pathExtension)")
        logFileURL = configurationDirectoryURL.appendingPathComponent("AFUScaleReader.log")
        self.profile = profile
        self.settleInterval = settleInterval
        self.deduplicationWindow = deduplicationWindow
        self.connectionTimeout = connectionTimeout
        self.retryDelay = retryDelay
    }

    public static func load(
        from fileURL: URL,
        referenceDate: Date = Date()
    ) throws -> ReaderConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ReaderConfigurationError.fileNotFound(fileURL.path)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw ReaderConfigurationError.unreadableFile(fileURL.path)
        }

        let raw: RawConfiguration
        do {
            raw = try JSONDecoder().decode(RawConfiguration.self, from: data)
        } catch {
            throw ReaderConfigurationError.invalidJSON
        }
        if raw.syntheticExample == true {
            throw ReaderConfigurationError.syntheticExample
        }

        guard let rawOutputPath = raw.outputPath else {
            throw ReaderConfigurationError.missingField("output_path")
        }
        let outputPath = expandTilde(rawOutputPath)
        guard outputPath.hasPrefix("/") else {
            throw ReaderConfigurationError.invalidOutputPath(rawOutputPath)
        }

        guard let rawOutputFormat = raw.outputFormat else {
            throw ReaderConfigurationError.missingField("output_format")
        }
        guard let outputFormat = OutputFormat(rawValue: rawOutputFormat.lowercased()) else {
            throw ReaderConfigurationError.invalidOutputFormat(rawOutputFormat)
        }
        guard URL(fileURLWithPath: outputPath).pathExtension.lowercased() == outputFormat.pathExtension else {
            throw ReaderConfigurationError.outputFormatMismatch(format: outputFormat.rawValue, path: rawOutputPath)
        }

        guard let rawStoreID = raw.storeID else {
            throw ReaderConfigurationError.missingField("store_id")
        }
        guard let storeID = UUID(uuidString: rawStoreID) else {
            throw ReaderConfigurationError.invalidStoreID(rawStoreID)
        }
        guard let debugLogging = raw.debugLogging else {
            throw ReaderConfigurationError.missingField("debug_logging")
        }

        guard let rawSex = raw.sex else {
            throw ReaderConfigurationError.missingField("sex")
        }
        guard let sex = BiologicalSex(rawValue: rawSex.lowercased()) else {
            throw ReaderConfigurationError.invalidSex(rawSex)
        }

        guard let height = raw.heightCentimeters else {
            throw ReaderConfigurationError.missingField("height_cm")
        }
        guard (100 ... 250).contains(height) else {
            throw ReaderConfigurationError.invalidHeight(height)
        }

        guard let rawBirthDate = raw.birthDate else {
            throw ReaderConfigurationError.missingField("birth_date")
        }
        guard let birthDate = parseDate(rawBirthDate) else {
            throw ReaderConfigurationError.invalidBirthDate(rawBirthDate)
        }
        guard birthDate <= referenceDate else {
            throw ReaderConfigurationError.birthDateInFuture
        }
        let age = BodyCompositionCalculator.ageYears(
            birthDate: birthDate,
            at: referenceDate
        )
        guard (18 ... 80).contains(age) else {
            throw ReaderConfigurationError.unsupportedAge(age)
        }

        let deviceNamePrefix = raw.deviceNamePrefix ?? "AFU-WL"
        guard !deviceNamePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReaderConfigurationError.invalidDeviceNamePrefix
        }

        let settleInterval = raw.settleSeconds ?? 2
        let deduplicationWindow = raw.deduplicationSeconds ?? 120
        let connectionTimeout = raw.connectionTimeoutSeconds ?? 8
        let retryDelay = raw.retryDelaySeconds ?? 1
        try validateInterval(settleInterval, field: "settle_seconds")
        try validateInterval(deduplicationWindow, field: "deduplication_seconds")
        try validateInterval(connectionTimeout, field: "connection_timeout_seconds")
        try validateInterval(retryDelay, field: "retry_delay_seconds")

        let configuration = ReaderConfiguration(
            deviceNamePrefix: deviceNamePrefix,
            outputFileURL: URL(fileURLWithPath: outputPath),
            outputFormat: outputFormat,
            storeID: storeID,
            debugLogging: debugLogging,
            configurationDirectoryURL: fileURL.deletingLastPathComponent(),
            profile: BodyProfile(sex: sex, heightCentimeters: height, birthDate: birthDate),
            settleInterval: settleInterval,
            deduplicationWindow: deduplicationWindow,
            connectionTimeout: connectionTimeout,
            retryDelay: retryDelay
        )
        try SecureFile.protect(fileURL)
        return configuration
    }

    public func save(to fileURL: URL) throws {
        let raw = RawConfiguration(
            syntheticExample: false,
            outputPath: outputFileURL.path,
            outputFormat: outputFormat.rawValue,
            storeID: storeID.uuidString.lowercased(),
            debugLogging: debugLogging,
            sex: profile.sex.rawValue,
            heightCentimeters: profile.heightCentimeters,
            birthDate: Self.formatDate(profile.birthDate),
            deviceNamePrefix: deviceNamePrefix,
            settleSeconds: settleInterval,
            deduplicationSeconds: deduplicationWindow,
            connectionTimeoutSeconds: connectionTimeout,
            retryDelaySeconds: retryDelay
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(raw)
        data.append(0x0A)
        try SecureFile.write(data, to: fileURL)
    }

    public func validateManagedStorage() throws {
        try ManagedOutput.validate(
            fileURL: outputFileURL,
            format: outputFormat,
            storeID: storeID
        )
        try ManagedOutput.validate(
            fileURL: measurementMirrorURL,
            format: outputFormat,
            storeID: storeID
        )
    }

    static func expandTilde(_ path: String, homeDirectory: URL? = nil) -> String {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        if path == "~" {
            return home.path
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = dateFormatter()
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            return nil
        }
        return date
    }

    private static func formatDate(_ date: Date) -> String {
        dateFormatter().string(from: date)
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private static func validateInterval(_ value: Double, field: String) throws {
        guard value.isFinite, value > 0 else {
            throw ReaderConfigurationError.invalidInterval(field: field, value: value)
        }
    }
}

private struct RawConfiguration: Codable {
    let syntheticExample: Bool?
    let outputPath: String?
    let outputFormat: String?
    let storeID: String?
    let debugLogging: Bool?
    let sex: String?
    let heightCentimeters: Double?
    let birthDate: String?
    let deviceNamePrefix: String?
    let settleSeconds: Double?
    let deduplicationSeconds: Double?
    let connectionTimeoutSeconds: Double?
    let retryDelaySeconds: Double?

    enum CodingKeys: String, CodingKey {
        case syntheticExample = "synthetic_example"
        case outputPath = "output_path"
        case outputFormat = "output_format"
        case storeID = "store_id"
        case debugLogging = "debug_logging"
        case sex
        case heightCentimeters = "height_cm"
        case birthDate = "birth_date"
        case deviceNamePrefix = "device_name_prefix"
        case settleSeconds = "settle_seconds"
        case deduplicationSeconds = "deduplication_seconds"
        case connectionTimeoutSeconds = "connection_timeout_seconds"
        case retryDelaySeconds = "retry_delay_seconds"
    }
}
