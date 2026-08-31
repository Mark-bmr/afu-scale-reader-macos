import Foundation
import XCTest
@testable import AFUCore

// All profiles, paths, device names, and configuration values in this file are synthetic.
final class ReaderConfigurationTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let storeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AFUReaderConfigurationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testDeviceMatcherAcceptsConfiguredAFUName() {
        XCTAssertTrue(AFUDeviceMatcher.matches(
            peripheralName: "AFU-WL-TZ-A1",
            advertisedName: nil,
            requiredPrefix: "AFU-WL"
        ))
        XCTAssertTrue(AFUDeviceMatcher.matches(
            peripheralName: "Cached Peripheral Name",
            advertisedName: "afu-wl-tz-a1",
            requiredPrefix: "AFU-WL"
        ))
    }

    func testDeviceMatcherRejectsUnrelatedFFB0DeviceName() {
        XCTAssertFalse(AFUDeviceMatcher.matches(
            peripheralName: "SYNTHETIC-OTHER-SCALE",
            advertisedName: "SYNTHETIC-OTHER-SCALE",
            requiredPrefix: "AFU-WL"
        ))
    }

    func testDeviceMatcherRejectsMissingNames() {
        XCTAssertFalse(AFUDeviceMatcher.matches(
            peripheralName: nil,
            advertisedName: nil,
            requiredPrefix: "AFU-WL"
        ))
        XCTAssertFalse(AFUDeviceMatcher.matches(
            peripheralName: "AFU-WL-TZ-A1",
            advertisedName: nil,
            requiredPrefix: ""
        ))
    }

    func testLoadsRequiredProfileAndProtocolDefaults() throws {
        let outputPath = temporaryDirectory
            .appendingPathComponent("Synthetic Vault/Health's Data/measurements.md").path
        let url = try writeConfiguration("""
        {
          "output_path": "\(outputPath)",
          "output_format": "md",
          "store_id": "\(storeID.uuidString)",
          "debug_logging": false,
          "sex": "male",
          "height_cm": 175,
          "birth_date": "1990-01-01"
        }
        """)

        let configuration = try ReaderConfiguration.load(from: url)

        XCTAssertEqual(configuration.deviceNamePrefix, "AFU-WL")
        XCTAssertEqual(configuration.outputFileURL.path, outputPath)
        XCTAssertEqual(configuration.outputFormat, .markdown)
        XCTAssertEqual(configuration.storeID, storeID)
        XCTAssertFalse(configuration.debugLogging)
        XCTAssertEqual(configuration.profile.sex, .male)
        XCTAssertEqual(configuration.profile.heightCentimeters, 175)
        XCTAssertEqual(configuration.settleInterval, 2)
        XCTAssertEqual(configuration.deduplicationWindow, 120)
        XCTAssertEqual(configuration.connectionTimeout, 8)
        XCTAssertEqual(configuration.retryDelay, 1)
        XCTAssertEqual(configuration.advertisementQuietInterval, 45)
        XCTAssertEqual(permissions(of: url), 0o600)
    }

    func testPreservesSpacesAndSingleQuoteInOutputPath() throws {
        let outputPath = temporaryDirectory
            .appendingPathComponent("Synthetic Vault/Health's Data/measurements.md").path
        let url = try writeConfiguration(validJSON(outputPath: outputPath))

        let configuration = try ReaderConfiguration.load(from: url)

        XCTAssertEqual(configuration.outputFileURL.path, outputPath)
    }

    func testUsesConfigDirectoryForMeasurementMirror() throws {
        let url = try writeConfiguration(validJSON(outputPath: "/tmp/afu.md"))

        let configuration = try ReaderConfiguration.load(from: url)

        XCTAssertEqual(
            configuration.measurementMirrorURL,
            url.deletingLastPathComponent().appendingPathComponent("measurements.md")
        )
    }

    func testUsesFormatSpecificJSONMirror() throws {
        let outputPath = temporaryDirectory.appendingPathComponent("measurements.json").path
        let url = try writeConfiguration(validJSON(outputPath: outputPath, outputFormat: "json"))

        let configuration = try ReaderConfiguration.load(from: url)

        XCTAssertEqual(configuration.outputFormat, .json)
        XCTAssertEqual(
            configuration.measurementMirrorURL,
            url.deletingLastPathComponent().appendingPathComponent("measurements.json")
        )
    }

    func testExpandsTildeInOutputPath() throws {
        let url = try writeConfiguration(validJSON(outputPath: "~/Documents/AFU/阿福体脂秤.md"))

        let configuration = try ReaderConfiguration.load(from: url)

        XCTAssertEqual(
            configuration.outputFileURL.path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/AFU/阿福体脂秤.md").path
        )
    }

    func testAppliesExplicitOverrides() throws {
        let url = try writeConfiguration("""
        {
          "output_path": "/tmp/afu.md",
          "output_format": "md",
          "store_id": "\(storeID.uuidString)",
          "debug_logging": false,
          "sex": "male",
          "height_cm": 175,
          "birth_date": "1990-01-01",
          "device_name_prefix": "CUSTOM-SCALE",
          "settle_seconds": 3,
          "deduplication_seconds": 180,
          "connection_timeout_seconds": 12,
          "retry_delay_seconds": 2,
          "advertisement_quiet_seconds": 60
        }
        """)

        let configuration = try ReaderConfiguration.load(from: url)

        XCTAssertEqual(configuration.deviceNamePrefix, "CUSTOM-SCALE")
        XCTAssertEqual(configuration.settleInterval, 3)
        XCTAssertEqual(configuration.deduplicationWindow, 180)
        XCTAssertEqual(configuration.connectionTimeout, 12)
        XCTAssertEqual(configuration.retryDelay, 2)
        XCTAssertEqual(configuration.advertisementQuietInterval, 60)
    }

    func testNormalizesLegacyShortAdvertisementQuietInterval() throws {
        let url = try writeConfiguration("""
        {
          "output_path": "/tmp/afu.md",
          "output_format": "md",
          "store_id": "\(storeID.uuidString)",
          "debug_logging": false,
          "sex": "male",
          "height_cm": 175,
          "birth_date": "1990-01-01",
          "advertisement_quiet_seconds": 5
        }
        """)

        let configuration = try ReaderConfiguration.load(from: url)

        XCTAssertEqual(configuration.advertisementQuietInterval, 45)
    }

    func testRejectsUnknownSex() throws {
        let url = try writeConfiguration(validJSON(outputPath: "/tmp/afu.md", sex: "unknown"))

        XCTAssertThrowsError(try ReaderConfiguration.load(from: url)) { error in
            XCTAssertEqual(error as? ReaderConfigurationError, .invalidSex("unknown"))
        }
    }

    func testRejectsInvalidHeight() throws {
        let url = try writeConfiguration(validJSON(outputPath: "/tmp/afu.md", height: 0))

        XCTAssertThrowsError(try ReaderConfiguration.load(from: url)) { error in
            XCTAssertEqual(error as? ReaderConfigurationError, .invalidHeight(0))
        }
    }

    func testRejectsFutureBirthDate() throws {
        let url = try writeConfiguration(validJSON(outputPath: "/tmp/afu.md", birthDate: "2999-12-31"))

        XCTAssertThrowsError(try ReaderConfiguration.load(from: url)) { error in
            XCTAssertEqual(error as? ReaderConfigurationError, .birthDateInFuture)
        }
    }

    func testRejectsProfileBelowSupportedAge() throws {
        let url = try writeConfiguration(validJSON(outputPath: "/tmp/afu.md", birthDate: "2010-01-01"))

        XCTAssertThrowsError(
            try ReaderConfiguration.load(
                from: url,
                referenceDate: date("2026-08-19T00:00:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? ReaderConfigurationError, .unsupportedAge(16))
        }
    }

    func testRejectsProfileAboveSupportedAge() throws {
        let url = try writeConfiguration(validJSON(outputPath: "/tmp/afu.md", birthDate: "1940-01-01"))

        XCTAssertThrowsError(
            try ReaderConfiguration.load(
                from: url,
                referenceDate: date("2026-08-19T00:00:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? ReaderConfigurationError, .unsupportedAge(86))
        }
    }

    func testRejectsNonPositiveIntervals() throws {
        let url = try writeConfiguration("""
        {
          "output_path": "/tmp/afu.md",
          "output_format": "md",
          "store_id": "\(storeID.uuidString)",
          "debug_logging": false,
          "sex": "male",
          "height_cm": 175,
          "birth_date": "1990-01-01",
          "settle_seconds": 0
        }
        """)

        XCTAssertThrowsError(try ReaderConfiguration.load(from: url)) { error in
            XCTAssertEqual(error as? ReaderConfigurationError, .invalidInterval(field: "settle_seconds", value: 0))
        }
    }

    func testRejectsNonPositiveAdvertisementQuietInterval() throws {
        let url = try writeConfiguration("""
        {
          "output_path": "/tmp/afu.md",
          "output_format": "md",
          "store_id": "\(storeID.uuidString)",
          "debug_logging": false,
          "sex": "male",
          "height_cm": 175,
          "birth_date": "1990-01-01",
          "advertisement_quiet_seconds": 0
        }
        """)

        XCTAssertThrowsError(try ReaderConfiguration.load(from: url)) { error in
            XCTAssertEqual(
                error as? ReaderConfigurationError,
                .invalidInterval(field: "advertisement_quiet_seconds", value: 0)
            )
        }
    }

    func testRejectsMissingConfigurationFile() {
        let missing = temporaryDirectory.appendingPathComponent("missing.json")

        XCTAssertThrowsError(try ReaderConfiguration.load(from: missing)) { error in
            XCTAssertEqual(error as? ReaderConfigurationError, .fileNotFound(missing.path))
        }
    }

    func testRejectsMalformedJSON() throws {
        let url = try writeConfiguration("{not-json}")

        XCTAssertThrowsError(try ReaderConfiguration.load(from: url)) { error in
            XCTAssertEqual(error as? ReaderConfigurationError, .invalidJSON)
        }
    }

    func testRejectsSyntheticExampleConfiguration() throws {
        let outputPath = temporaryDirectory.appendingPathComponent("measurements.md").path
        let url = try writeConfiguration(validJSON(outputPath: outputPath, syntheticExample: true))

        XCTAssertThrowsError(try ReaderConfiguration.load(from: url)) { error in
            XCTAssertEqual(error as? ReaderConfigurationError, .syntheticExample)
        }
    }

    func testRejectsOutputExtensionThatDoesNotMatchFormat() throws {
        let outputPath = temporaryDirectory.appendingPathComponent("measurements.json").path
        let url = try writeConfiguration(validJSON(outputPath: outputPath, outputFormat: "md"))

        XCTAssertThrowsError(try ReaderConfiguration.load(from: url)) { error in
            XCTAssertEqual(
                error as? ReaderConfigurationError,
                .outputFormatMismatch(format: "md", path: outputPath)
            )
        }
    }

    func testRejectsMissingStoreID() throws {
        let outputPath = temporaryDirectory.appendingPathComponent("measurements.md").path
        let json = validJSON(outputPath: outputPath)
            .replacingOccurrences(of: "\"store_id\": \"\(storeID.uuidString)\",\n", with: "")
        let url = try writeConfiguration(json)

        XCTAssertThrowsError(try ReaderConfiguration.load(from: url)) { error in
            XCTAssertEqual(error as? ReaderConfigurationError, .missingField("store_id"))
        }
    }

    private func validJSON(
        outputPath: String,
        sex: String = "male",
        height: Double = 175,
        birthDate: String = "1990-01-01",
        outputFormat: String = "md",
        syntheticExample: Bool = false
    ) -> String {
        """
        {
          "synthetic_example": \(syntheticExample),
          "output_path": "\(outputPath)",
          "output_format": "\(outputFormat)",
          "store_id": "\(storeID.uuidString)",
          "debug_logging": false,
          "sex": "\(sex)",
          "height_cm": \(height),
          "birth_date": "\(birthDate)"
        }
        """
    }

    private func writeConfiguration(_ json: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func permissions(of url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
