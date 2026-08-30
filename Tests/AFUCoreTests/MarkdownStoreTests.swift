import Foundation
import XCTest
@testable import AFUCore

// All profiles, timestamps, measurements, paths, and packets in this file are synthetic.
final class MarkdownStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var fileURL: URL!
    private let storeID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AFUMarkdownStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        fileURL = temporaryDirectory.appendingPathComponent("阿福体脂秤.md")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testCreatesTableWithAllMetricsAndNoVisibleTimezone() throws {
        let store = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)

        let appended = try store.append(record(at: date("2026-08-19T08:30:12Z")))
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let rows = measurementRows(in: text)

        XCTAssertTrue(appended)
        XCTAssertTrue(text.hasPrefix("# 阿福体脂秤测量记录\n"))
        XCTAssertTrue(text.contains("<!-- afu-scale-reader:"))
        XCTAssertTrue(text.contains(tableHeader))
        XCTAssertTrue(text.contains(tableSeparator))
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.hasPrefix("| 2026-08-19 08:30:12 | 70.00 |"))
        XCTAssertEqual(row.filter { $0 == "|" }.count, 19)
        XCTAssertTrue(row.contains("<!-- afu-meta: "))
        XCTAssertFalse(text.contains("+00:00"))
        XCTAssertFalse(text.contains("## 2026-"))
    }

    func testRefusesToAppendToUnmanagedMarkdown() throws {
        try "# 我的健康记录\n\n自定义说明\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)

        XCTAssertThrowsError(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "# 我的健康记录\n\n自定义说明\n")
    }

    func testAppendsToObsidianAlignedTableWithoutRepeatingHeader() throws {
        let store = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))

        let original = try String(contentsOf: fileURL, encoding: .utf8)
        let obsidianAligned = original
            .replacingOccurrences(
                of: tableHeader,
                with: "| 时间                  | 体重 (kg) |   BMI |  内脏脂肪 | 体脂率 (%) | 脂肪量 (kg) | 肌肉率 (%) | 肌肉量 (kg) | 体水分率 (%) | 体水分量 (kg) | 蛋白质占比 (%) | 蛋白质含量 (kg) | 骨量占比 (%) | 骨量 (kg) | 骨骼肌量 (kg) | 骨骼肌率 (%) | 皮下脂肪率 (%) | 皮下脂肪量 (kg) |"
            )
            .replacingOccurrences(
                of: tableSeparator,
                with: "| ------------------- | ------: | ----: | ----: | ------: | -------: | ------: | -------: | -------: | --------: | --------: | ---------: | -------: | ------: | --------: | -------: | --------: | ----------------: |"
            )
        try obsidianAligned.write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:33:00Z"), weight: 83)))
        let text = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(semanticHeaderCount(in: text), 1)
        XCTAssertEqual(measurementRows(in: text).count, 2)
    }

    func testSuppressesDuplicateAfterStoreRestart() throws {
        let firstStore = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(try firstStore.append(record(at: date("2026-08-19T08:30:12Z"))))

        let restartedStore = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)
        let duplicate = try restartedStore.append(record(at: date("2026-08-19T08:31:00Z")))
        let text = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertFalse(duplicate)
        XCTAssertEqual(measurementRows(in: text).count, 1)
    }

    func testAllowsSameMeasurementAfterDeduplicationWindow() throws {
        let store = MarkdownStore(fileURL: fileURL, storeID: storeID, deduplicationWindow: 120, timeZone: TimeZone(secondsFromGMT: 0)!)

        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:32:13Z"))))
        let text = try String(contentsOf: fileURL, encoding: .utf8)

        XCTAssertEqual(measurementRows(in: text).count, 2)
    }

    func testPersistsDistinctDeviceTimesInsideReceivedDeduplicationWindow() throws {
        let store = MarkdownStore(
            fileURL: fileURL,
            storeID: storeID,
            deduplicationWindow: 120,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let first = date("2026-08-19T08:30:12Z")
        let second = date("2026-08-19T08:31:12Z")

        XCTAssertTrue(try store.append(record(at: first, timeSource: .device)))
        XCTAssertTrue(try store.append(record(at: second, timeSource: .device)))

        let restarted = MarkdownStore(
            fileURL: fileURL,
            storeID: storeID,
            deduplicationWindow: 120,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertFalse(try restarted.append(record(at: second, timeSource: .device)))
        XCTAssertEqual(
            measurementRows(in: try String(contentsOf: fileURL, encoding: .utf8)).count,
            2
        )
    }

    func testSuppressesReplayedDeviceHistoryBatchAfterRestart() throws {
        let store = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)
        let first = date("2026-08-19T08:30:12Z")
        let second = date("2026-08-19T12:30:12Z")
        XCTAssertTrue(try store.append(record(at: first, timeSource: .device)))
        XCTAssertTrue(try store.append(record(at: second, timeSource: .device)))

        let restarted = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertFalse(try restarted.append(record(at: first, timeSource: .device)))
        XCTAssertFalse(try restarted.append(record(at: second, timeSource: .device)))
        XCTAssertEqual(
            measurementRows(in: try String(contentsOf: fileURL, encoding: .utf8)).count,
            2
        )
    }

    func testLegacyMetadataWithoutTimeSourceStillDecodes() throws {
        let store = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        try removeTimeSourceFromLastMetadata()

        let restarted = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertFalse(try restarted.append(record(at: date("2026-08-19T08:31:00Z"))))
        XCTAssertEqual(
            measurementRows(in: try String(contentsOf: fileURL, encoding: .utf8)).count,
            1
        )
        XCTAssertEqual(try restarted.latestWeightKilograms(), 70)
    }

    func testReturnsLatestWeightForSessionUserMatching() throws {
        let store = MarkdownStore(
            fileURL: fileURL,
            storeID: storeID,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertNil(try store.latestWeightKilograms())
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"), weight: 70)))
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:33:00Z"), weight: 83)))
        XCTAssertEqual(try store.latestWeightKilograms(), 83)
    }

    func testInlineMetadataCannotBreakTableAndStillDeduplicates() throws {
        let store = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)

        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"), deviceName: "AFU--Scale|A1")))
        let restartedStore = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertFalse(try restartedStore.append(record(at: date("2026-08-19T08:31:00Z"), deviceName: "AFU--Scale|A1")))
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let row = try XCTUnwrap(measurementRows(in: text).first)

        XCTAssertFalse(text.contains("AFU--Scale"))
        XCTAssertEqual(row.filter { $0 == "|" }.count, 19)
        XCTAssertEqual(measurementRows(in: text).count, 1)
    }

    func testMetadataContainsOnlyMinimalDeduplicationFields() throws {
        let store = MarkdownStore(fileURL: fileURL, storeID: storeID, timeZone: TimeZone(secondsFromGMT: 0)!)

        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let row = try XCTUnwrap(measurementRows(in: text).first)
        let prefix = "<!-- afu-meta: "
        let suffix = " -->"
        let start = try XCTUnwrap(row.range(of: prefix)).upperBound
        let end = try XCTUnwrap(row.range(of: suffix, range: start ..< row.endIndex)).lowerBound
        let payload = String(row[start ..< end])
        let metadata = try XCTUnwrap(Data(base64Encoded: payload))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            ["algorithm", "impedance_raw", "measured_at", "mode", "store_id", "time_source", "weight_kg"]
        )
        XCTAssertEqual(object["store_id"] as? String, storeID.uuidString.lowercased())
        XCTAssertEqual(object["time_source"] as? String, "received")
        XCTAssertFalse(text.contains("AC000069117002000320"))
        XCTAssertFalse(text.contains("AFU-WL-TZ-A1"))
    }

    func testRestoresExternallyOverwrittenOutputFromCanonicalMirror() throws {
        let canonicalFileURL = temporaryDirectory.appendingPathComponent("measurements.md")
        let store = MarkdownStore(
            fileURL: fileURL,
            canonicalFileURL: canonicalFileURL,
            storeID: storeID,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        let managedOutput = try String(contentsOf: fileURL, encoding: .utf8)
        let externallyChanged = managedOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("| 2026-") }
            .joined(separator: "\n")
        try SecureFile.write(externallyChanged, to: fileURL)

        XCTAssertTrue(try store.restoreOutputFromCanonicalIfNeeded())
        let output = try String(contentsOf: fileURL, encoding: .utf8)
        let canonical = try String(contentsOf: canonicalFileURL, encoding: .utf8)

        XCTAssertEqual(output, canonical)
        XCTAssertEqual(measurementRows(in: output).count, 1)
    }

    func testRestartAppendsFromCanonicalMirrorAfterOutputWasOverwritten() throws {
        let canonicalFileURL = temporaryDirectory.appendingPathComponent("measurements.md")
        let firstStore = MarkdownStore(
            fileURL: fileURL,
            canonicalFileURL: canonicalFileURL,
            storeID: storeID,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertTrue(try firstStore.append(record(at: date("2026-08-19T08:30:12Z"))))
        let managedOutput = try String(contentsOf: fileURL, encoding: .utf8)
        let externallyChanged = managedOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("| 2026-") }
            .joined(separator: "\n")
        try SecureFile.write(externallyChanged, to: fileURL)

        let restartedStore = MarkdownStore(
            fileURL: fileURL,
            canonicalFileURL: canonicalFileURL,
            storeID: storeID,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertTrue(try restartedStore.append(record(at: date("2026-08-19T08:33:00Z"), weight: 83)))
        let output = try String(contentsOf: fileURL, encoding: .utf8)
        let canonical = try String(contentsOf: canonicalFileURL, encoding: .utf8)

        XCTAssertEqual(output, canonical)
        XCTAssertEqual(semanticHeaderCount(in: output), 1)
        XCTAssertEqual(measurementRows(in: output).count, 2)
    }

    func testDoesNotRestoreWhenOutputMatchesCanonicalMirror() throws {
        let canonicalFileURL = temporaryDirectory.appendingPathComponent("measurements.md")
        let store = MarkdownStore(
            fileURL: fileURL,
            canonicalFileURL: canonicalFileURL,
            storeID: storeID,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))

        XCTAssertFalse(try store.restoreOutputFromCanonicalIfNeeded())
    }

    func testRefusesToRestoreOverUnmanagedOutput() throws {
        let canonicalFileURL = temporaryDirectory.appendingPathComponent("measurements.md")
        let store = MarkdownStore(
            fileURL: fileURL,
            canonicalFileURL: canonicalFileURL,
            storeID: storeID,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        try "unmanaged content".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.restoreOutputFromCanonicalIfNeeded())
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "unmanaged content")
    }

    func testProtectsOutputAndCanonicalMirror() throws {
        let canonicalFileURL = temporaryDirectory.appendingPathComponent("measurements.md")
        let store = MarkdownStore(
            fileURL: fileURL,
            canonicalFileURL: canonicalFileURL,
            storeID: storeID,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        XCTAssertEqual(permissions(of: fileURL), 0o600)
        XCTAssertEqual(permissions(of: canonicalFileURL), 0o600)
    }

    private let tableHeader = "| 时间 | 体重 (kg) | BMI | 内脏脂肪 | 体脂率 (%) | 脂肪量 (kg) | 肌肉率 (%) | 肌肉量 (kg) | 体水分率 (%) | 体水分量 (kg) | 蛋白质占比 (%) | 蛋白质含量 (kg) | 骨量占比 (%) | 骨量 (kg) | 骨骼肌量 (kg) | 骨骼肌率 (%) | 皮下脂肪率 (%) | 皮下脂肪量 (kg) |"
    private let tableSeparator = "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"

    private func measurementRows(in text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("| 2026-") }
    }

    private func semanticHeaderCount(in text: String) -> Int {
        let expectedCells = normalizedTableCells(in: tableHeader)
        return text.split(separator: "\n")
            .map(String.init)
            .filter { normalizedTableCells(in: $0) == expectedCells }
            .count
    }

    private func normalizedTableCells(in line: String) -> [String] {
        line.split(separator: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private func record(
        at measuredAt: Date,
        weight: Double = 70,
        impedance: Int? = 800,
        deviceName: String = "AFU-WL-TZ-A1",
        timeSource: MeasurementTimeSource = .received
    ) throws -> MeasurementRecord {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 175,
            birthDate: date("1990-01-01T00:00:00Z")
        )
        let composition = try BodyCompositionCalculator.calculate(
            weightKilograms: weight,
            impedanceRawCode: impedance,
            profile: profile,
            measuredAt: measuredAt
        )
        return MeasurementRecord(
            measurement: StableMeasurement(
                measuredAt: measuredAt,
                weightKilograms: weight,
                impedanceRawCode: impedance,
                rawHex: "AC000069117002000320",
                deviceName: deviceName,
                timeSource: timeSource
            ),
            composition: composition
        )
    }

    private func removeTimeSourceFromLastMetadata() throws {
        var text = try String(contentsOf: fileURL, encoding: .utf8)
        let prefix = "<!-- afu-meta: "
        let suffix = " -->"
        let startRange = try XCTUnwrap(text.range(of: prefix, options: .backwards))
        let payloadStart = startRange.upperBound
        let endRange = try XCTUnwrap(text.range(of: suffix, range: payloadStart ..< text.endIndex))
        let payload = String(text[payloadStart ..< endRange.lowerBound])
        let data = try XCTUnwrap(Data(base64Encoded: payload))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "time_source")
        let legacyPayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .base64EncodedString()
        text.replaceSubrange(payloadStart ..< endRange.lowerBound, with: legacyPayload)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func permissions(of url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
    }
}
