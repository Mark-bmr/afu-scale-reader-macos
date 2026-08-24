import Foundation

public enum ConfigurationWizardError: Error, Equatable, Sendable {
    case endOfInput
    case configurationAlreadyExists(String)
    case conflictingPath(String)
    case invalidInput(field: String, value: String)
}

extension ConfigurationWizardError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .endOfInput:
            return "Configuration was cancelled before all required answers were provided"
        case let .configurationAlreadyExists(path):
            return "Refusing to replace an existing configuration: \(path)"
        case let .conflictingPath(path):
            return "Configuration, output, mirror, and log paths must be distinct: \(path)"
        case let .invalidInput(field, value):
            return "Invalid \(field): \(value)"
        }
    }
}

public final class ConfigurationWizard {
    public typealias ReadInput = () -> String?
    public typealias WriteOutput = (String) -> Void

    private let readInput: ReadInput
    private let writeOutput: WriteOutput
    private let homeDirectory: URL
    private let storeIDGenerator: () -> UUID
    private let currentDate: () -> Date

    public init(
        readInput: @escaping ReadInput = { readLine() },
        writeOutput: @escaping WriteOutput = { print($0, terminator: "") },
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        storeIDGenerator: @escaping () -> UUID = { UUID() },
        currentDate: @escaping () -> Date = { Date() }
    ) {
        self.readInput = readInput
        self.writeOutput = writeOutput
        self.homeDirectory = homeDirectory
        self.storeIDGenerator = storeIDGenerator
        self.currentDate = currentDate
    }

    public func run(configURL: URL) throws -> ReaderConfiguration {
        if FileManager.default.fileExists(atPath: configURL.path) {
            guard let existing = try? Data(contentsOf: configURL) else {
                throw ConfigurationWizardError.configurationAlreadyExists(configURL.path)
            }
            let isBlank = existing.isEmpty
                || String(data: existing, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            if !isBlank {
                throw ConfigurationWizardError.configurationAlreadyExists(configURL.path)
            }
        }

        writeOutput("AFU Scale Reader 首次配置（数据只保存在你选择的本地文件）\n")
        let referenceDate = currentDate()
        let sex = try readSex()
        let height = try readHeight()
        let birthDate = try readBirthDate(referenceDate: referenceDate)
        let format = try readFormat()
        let outputURL = try readOutputURL(format: format)
        let debugLogging = try readDebugLogging()
        let storeID = storeIDGenerator()

        let configuration = ReaderConfiguration(
            outputFileURL: outputURL,
            outputFormat: format,
            storeID: storeID,
            debugLogging: debugLogging,
            configurationDirectoryURL: configURL.deletingLastPathComponent(),
            profile: BodyProfile(
                sex: sex,
                heightCentimeters: height,
                birthDate: birthDate
            )
        )
        try validateDistinctPaths(configuration: configuration, configURL: configURL)

        try ManagedOutput.initialize(
            outputURL: configuration.outputFileURL,
            canonicalURL: configuration.measurementMirrorURL,
            format: configuration.outputFormat,
            storeID: configuration.storeID
        )
        try configuration.save(to: configURL)
        let reloaded = try ReaderConfiguration.load(
            from: configURL,
            referenceDate: referenceDate
        )
        try reloaded.validateManagedStorage()
        writeOutput("配置完成。\n")
        return reloaded
    }

    private func validateDistinctPaths(
        configuration: ReaderConfiguration,
        configURL: URL
    ) throws {
        let urls = [
            configURL,
            configuration.outputFileURL,
            configuration.measurementMirrorURL,
            configuration.logFileURL
        ]
        var seen: Set<String> = []
        for url in urls {
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            guard seen.insert(normalized).inserted else {
                throw ConfigurationWizardError.conflictingPath(url.path)
            }
        }
    }

    private func readSex() throws -> BiologicalSex {
        let value = try answer("生理性别（male/female）：")
        guard let sex = BiologicalSex(rawValue: value.lowercased()) else {
            throw ConfigurationWizardError.invalidInput(field: "sex", value: value)
        }
        return sex
    }

    private func readHeight() throws -> Double {
        let value = try answer("身高（厘米，100–250）：")
        guard let height = Double(value), height.isFinite, (100 ... 250).contains(height) else {
            throw ConfigurationWizardError.invalidInput(field: "height", value: value)
        }
        return height
    }

    private func readBirthDate(referenceDate: Date) throws -> Date {
        let value = try answer("出生日期（YYYY-MM-DD，当前年龄须为 18–80 岁）：")
        guard let date = ReaderConfiguration.parseDate(value), date <= referenceDate else {
            throw ConfigurationWizardError.invalidInput(field: "birth date", value: value)
        }
        let age = BodyCompositionCalculator.ageYears(
            birthDate: date,
            at: referenceDate
        )
        guard (18 ... 80).contains(age) else {
            throw ConfigurationWizardError.invalidInput(
                field: "birth date (supported age 18-80)",
                value: value
            )
        }
        return date
    }

    private func readFormat() throws -> OutputFormat {
        let value = try answer("输出格式（md/json）：").lowercased()
        guard let format = OutputFormat(rawValue: value) else {
            throw ConfigurationWizardError.invalidInput(field: "output format", value: value)
        }
        return format
    }

    private func readOutputURL(format: OutputFormat) throws -> URL {
        let defaultURL = homeDirectory
            .appendingPathComponent("Documents/AFUScaleReader/measurements.\(format.pathExtension)")
        let value = try answer("输出文件路径（回车使用 \(defaultURL.path)）：", trim: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath = value.isEmpty
            ? defaultURL.path
            : ReaderConfiguration.expandTilde(value, homeDirectory: homeDirectory)
        guard resolvedPath.hasPrefix("/") else {
            throw ConfigurationWizardError.invalidInput(field: "output path", value: value)
        }
        let url = URL(fileURLWithPath: resolvedPath)
        guard url.pathExtension.lowercased() == format.pathExtension else {
            throw ConfigurationWizardError.invalidInput(field: "output path extension", value: value)
        }
        return url
    }

    private func readDebugLogging() throws -> Bool {
        let value = try answer("启用包含测量细节的调试日志？（y/N）：").lowercased()
        switch value {
        case "", "n", "no", "否":
            return false
        case "y", "yes", "是":
            return true
        default:
            throw ConfigurationWizardError.invalidInput(field: "debug logging", value: value)
        }
    }

    private func answer(_ prompt: String, trim: Bool = true) throws -> String {
        writeOutput(prompt)
        guard let value = readInput() else {
            throw ConfigurationWizardError.endOfInput
        }
        return trim ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value
    }
}
