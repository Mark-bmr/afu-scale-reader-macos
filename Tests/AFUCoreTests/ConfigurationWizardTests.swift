import Foundation
import XCTest
@testable import AFUCore

// All profiles, paths, configuration values, and identifiers in this file are synthetic.
final class ConfigurationWizardTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var configURL: URL!
    private let storeID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let referenceDate = ISO8601DateFormatter().date(from: "2026-08-19T00:00:00Z")!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AFUConfigurationWizardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        configURL = temporaryDirectory.appendingPathComponent("Application Support/config.json")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testWizardWritesCompleteMarkdownConfiguration() throws {
        let configuration = try runWizard(inputs: ["male", "175", "1990-01-01", "md", "", "n"])

        XCTAssertEqual(configuration.outputFormat, .markdown)
        XCTAssertEqual(configuration.storeID, storeID)
        XCTAssertFalse(configuration.debugLogging)
        XCTAssertEqual(configuration.outputFileURL.pathExtension, "md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: configuration.outputFileURL.path))
        XCTAssertEqual(permissions(of: configURL), 0o600)
        XCTAssertEqual(permissions(of: configuration.outputFileURL), 0o600)

        let reloaded = try ReaderConfiguration.load(from: configURL)
        XCTAssertEqual(reloaded, configuration)
    }

    func testWizardWritesCompleteJSONConfiguration() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("Exports/body data.json")
        let configuration = try runWizard(
            inputs: ["female", "165", "1995-06-15", "json", outputURL.path, "y"]
        )

        XCTAssertEqual(configuration.outputFormat, .json)
        XCTAssertTrue(configuration.debugLogging)
        XCTAssertEqual(configuration.outputFileURL, outputURL)
        let data = try Data(contentsOf: outputURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["store_id"] as? String, storeID.uuidString.lowercased())
    }

    func testWizardEOFLeavesNoConfigurationOrOutput() throws {
        XCTAssertThrowsError(try runWizard(inputs: ["male"])) { error in
            XCTAssertEqual(error as? ConfigurationWizardError, .endOfInput)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryDirectory.appendingPathComponent("Documents/AFUScaleReader/measurements.md").path
        ))
    }

    func testWizardRejectsMismatchedOutputExtensionWithoutWritingConfiguration() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("measurements.json")

        XCTAssertThrowsError(
            try runWizard(inputs: ["male", "175", "1990-01-01", "md", outputURL.path, "n"])
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testWizardRefusesUnmanagedOutputWithoutOverwritingIt() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("existing.md")
        try "unmanaged content".write(to: outputURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try runWizard(inputs: ["male", "175", "1990-01-01", "md", outputURL.path, "n"])
        )
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "unmanaged content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testWizardRefusesExistingNonUTF8Configuration() throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data([0xFF, 0xFE, 0xFD])
        try original.write(to: configURL)

        XCTAssertThrowsError(try runWizard(inputs: [])) { error in
            XCTAssertEqual(
                error as? ConfigurationWizardError,
                .configurationAlreadyExists(configURL.path)
            )
        }
        XCTAssertEqual(try Data(contentsOf: configURL), original)
    }

    func testWizardRejectsOutputPathThatConflictsWithConfiguration() throws {
        XCTAssertThrowsError(
            try runWizard(inputs: ["male", "175", "1990-01-01", "json", configURL.path, "n"])
        ) { error in
            XCTAssertEqual(
                error as? ConfigurationWizardError,
                .conflictingPath(configURL.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testWizardRejectsUnsupportedAgeWithoutWritingConfigurationOrOutput() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("measurements.md")

        XCTAssertThrowsError(
            try runWizard(inputs: ["male", "175", "2010-01-01", "md", outputURL.path, "n"])
        ) { error in
            XCTAssertEqual(
                error as? ConfigurationWizardError,
                .invalidInput(field: "birth date (supported age 18-80)", value: "2010-01-01")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private func runWizard(inputs: [String]) throws -> ReaderConfiguration {
        var remainingInputs = inputs
        let wizard = ConfigurationWizard(
            readInput: { remainingInputs.isEmpty ? nil : remainingInputs.removeFirst() },
            writeOutput: { _ in },
            homeDirectory: temporaryDirectory,
            storeIDGenerator: { self.storeID },
            currentDate: { self.referenceDate }
        )
        return try wizard.run(configURL: configURL)
    }

    private func permissions(of url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
    }
}
