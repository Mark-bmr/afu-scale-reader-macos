import AFUCore
import Foundation

private enum CommandLineError: Error, LocalizedError {
    case missingConfigPath
    case conflictingCommands

    var errorDescription: String? {
        switch self {
        case .missingConfigPath:
            return "--config requires a file path"
        case .conflictingCommands:
            return "Use only one of --configure, --validate-config, or --sync-history"
        }
    }
}

private func configurationURL(arguments: [String]) throws -> URL {
    if let index = arguments.firstIndex(of: "--config") {
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
            throw CommandLineError.missingConfigPath
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }
    if let environmentPath = ProcessInfo.processInfo.environment["AFU_SCALE_CONFIG"],
       !environmentPath.isEmpty
    {
        return URL(fileURLWithPath: environmentPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AFUScaleReader/config.json")
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func writeOutput(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

private func validate(_ configURL: URL) throws -> ReaderConfiguration {
    let configuration = try ReaderConfiguration.load(from: configURL)
    try configuration.validateManagedStorage()
    return configuration
}

let arguments = Array(CommandLine.arguments.dropFirst())
let shouldConfigure = arguments.contains("--configure")
let shouldValidate = arguments.contains("--validate-config")
let shouldSyncHistory = arguments.contains("--sync-history")

do {
    guard [shouldConfigure, shouldValidate, shouldSyncHistory].filter({ $0 }).count <= 1 else {
        throw CommandLineError.conflictingCommands
    }
    let configURL = try configurationURL(arguments: arguments)

    if shouldConfigure {
        _ = try ConfigurationWizard().run(configURL: configURL)
        exit(EXIT_SUCCESS)
    }

    if shouldValidate {
        _ = try validate(configURL)
        writeOutput("Configuration is valid.")
        exit(EXIT_SUCCESS)
    }

    let configuration = try validate(configURL)
    let logger = try RotatingFileLogger(
        fileURL: configuration.logFileURL,
        debugEnabled: configuration.debugLogging
    )
    let reader = BluetoothReader(
        configuration: configuration,
        logger: logger,
        sessionMode: shouldSyncHistory ? .history : .live
    )
    reader.start()
    withExtendedLifetime(reader) {
        RunLoop.main.run()
    }
} catch {
    writeError("AFU Scale Reader could not continue: \(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
