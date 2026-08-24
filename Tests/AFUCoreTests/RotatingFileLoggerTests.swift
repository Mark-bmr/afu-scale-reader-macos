import Foundation
import XCTest
@testable import AFUCore

// All paths and log messages in this file are synthetic.
final class RotatingFileLoggerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var logURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AFURotatingFileLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        logURL = temporaryDirectory.appendingPathComponent("AFUScaleReader.log")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testDebugMessageIsDroppedByDefault() throws {
        let logger = try RotatingFileLogger(fileURL: logURL, debugEnabled: false)

        try logger.info("reader-started")
        try logger.debug("synthetic-sensitive-detail")
        let text = try String(contentsOf: logURL, encoding: .utf8)

        XCTAssertTrue(text.contains("INFO reader-started"))
        XCTAssertFalse(text.contains("synthetic-sensitive-detail"))
        XCTAssertEqual(permissions(of: logURL), 0o600)
    }

    func testDebugMessageIsWrittenOnlyWhenEnabled() throws {
        let logger = try RotatingFileLogger(fileURL: logURL, debugEnabled: true)

        try logger.debug("synthetic-debug-detail")

        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains("DEBUG synthetic-debug-detail"))
    }

    func testRotatesAtLimitAndProtectsEveryFile() throws {
        let logger = try RotatingFileLogger(
            fileURL: logURL,
            debugEnabled: true,
            maximumBytes: 80,
            backupCount: 2
        )

        try logger.debug(String(repeating: "x", count: 120))
        let firstBackup = URL(fileURLWithPath: logURL.path + ".1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstBackup.path))
        XCTAssertEqual(permissions(of: logURL), 0o600)
        XCTAssertEqual(permissions(of: firstBackup), 0o600)
        XCTAssertLessThanOrEqual(try fileSize(of: logURL), 80)
    }

    func testKeepsOnlyConfiguredNumberOfBackups() throws {
        let logger = try RotatingFileLogger(
            fileURL: logURL,
            debugEnabled: true,
            maximumBytes: 80,
            backupCount: 2
        )

        for index in 0 ..< 6 {
            try logger.debug("entry-\(index)-" + String(repeating: "x", count: 90))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path + ".1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path + ".2"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path + ".3"))
        XCTAssertEqual(permissions(of: URL(fileURLWithPath: logURL.path + ".2")), 0o600)
    }

    private func permissions(of url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
    }

    private func fileSize(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as! NSNumber).intValue
    }
}
