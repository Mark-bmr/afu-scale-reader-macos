import Foundation
import XCTest
@testable import AFUCore

// All profiles, timestamps, measurements, paths, identifiers, and packets in this file are synthetic.
final class JSONStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var outputURL: URL!
    private var canonicalURL: URL!
    private let storeID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AFUJSONStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        outputURL = temporaryDirectory.appendingPathComponent("export/measurements.json")
        canonicalURL = temporaryDirectory.appendingPathComponent("private/measurements.json")
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testAppendsSyntheticMeasurementWithoutRawFrameOrDevice() throws {
        let store = makeStore()

        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        let data = try Data(contentsOf: outputURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let measurements = try XCTUnwrap(object["measurements"] as? [[String: Any]])
        let measurement = try XCTUnwrap(measurements.first)

        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["store_id"] as? String, storeID.uuidString.lowercased())
        XCTAssertEqual(measurements.count, 1)
        XCTAssertNil(measurement["raw"])
        XCTAssertNil(measurement["raw_hex"])
        XCTAssertNil(measurement["device"])
        XCTAssertNil(measurement["device_name"])
        XCTAssertEqual(measurement["weight_kg"] as? Double, 70)
        XCTAssertEqual(measurement["time_source"] as? String, "received")
        XCTAssertNotNil(measurement["body_fat_percent"])
        XCTAssertEqual(permissions(of: outputURL), 0o600)
        XCTAssertEqual(permissions(of: canonicalURL), 0o600)
    }

    func testSuppressesDuplicateAfterRestart() throws {
        XCTAssertTrue(try makeStore().append(record(at: date("2026-08-19T08:30:12Z"))))

        let restarted = makeStore()
        XCTAssertFalse(try restarted.append(record(at: date("2026-08-19T08:31:00Z"))))
        XCTAssertEqual(try measurementCount(at: outputURL), 1)
    }

    func testAllowsSameMeasurementOutsideWindow() throws {
        let store = makeStore()

        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:32:13Z"))))
        XCTAssertEqual(try measurementCount(at: outputURL), 2)
    }

    func testPersistsDistinctDeviceTimesInsideReceivedDeduplicationWindow() throws {
        let store = makeStore()
        let first = date("2026-08-19T08:30:12Z")
        let second = date("2026-08-19T08:31:12Z")

        XCTAssertTrue(try store.append(record(at: first, timeSource: .device)))
        XCTAssertTrue(try store.append(record(at: second, timeSource: .device)))

        XCTAssertFalse(try makeStore().append(record(at: second, timeSource: .device)))
        XCTAssertEqual(try measurementCount(at: outputURL), 2)
    }

    func testSuppressesReplayedDeviceHistoryBatchAfterRestart() throws {
        let store = makeStore()
        let first = date("2026-08-19T08:30:12Z")
        let second = date("2026-08-19T12:30:12Z")
        XCTAssertTrue(try store.append(record(at: first, timeSource: .device)))
        XCTAssertTrue(try store.append(record(at: second, timeSource: .device)))

        XCTAssertFalse(try makeStore().append(record(at: first, timeSource: .device)))
        XCTAssertFalse(try makeStore().append(record(at: second, timeSource: .device)))
        XCTAssertEqual(try measurementCount(at: outputURL), 2)
    }

    func testLegacyJSONWithoutTimeSourceStillDecodes() throws {
        XCTAssertTrue(try makeStore().append(record(at: date("2026-08-19T08:30:12Z"))))
        let source = try Data(contentsOf: canonicalURL)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        var measurements = try XCTUnwrap(document["measurements"] as? [[String: Any]])
        measurements[0].removeValue(forKey: "time_source")
        document["measurements"] = measurements
        var legacyData = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        legacyData.append(0x0A)
        try SecureFile.write(legacyData, to: canonicalURL)
        try SecureFile.write(legacyData, to: outputURL)

        XCTAssertFalse(try makeStore().append(record(at: date("2026-08-19T08:31:00Z"))))
        XCTAssertEqual(try measurementCount(at: outputURL), 1)
        XCTAssertEqual(try makeStore().latestWeightKilograms(), 70)
    }

    func testReturnsLatestWeightForSessionUserMatching() throws {
        let store = makeStore()

        XCTAssertNil(try store.latestWeightKilograms())
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"), weight: 70)))
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:33:00Z"), weight: 83)))
        XCTAssertEqual(try store.latestWeightKilograms(), 83)
    }

    func testRestoresManagedOutputFromCanonicalMirror() throws {
        let store = makeStore()
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        let emptyManaged = try ManagedOutput.initialData(format: .json, storeID: storeID)
        try SecureFile.write(emptyManaged, to: outputURL)

        XCTAssertTrue(try store.restoreOutputFromCanonicalIfNeeded())
        XCTAssertEqual(try Data(contentsOf: outputURL), try Data(contentsOf: canonicalURL))
        XCTAssertEqual(try measurementCount(at: outputURL), 1)
    }

    func testRefusesToRestoreUnmanagedOutput() throws {
        let store = makeStore()
        XCTAssertTrue(try store.append(record(at: date("2026-08-19T08:30:12Z"))))
        try "unmanaged content".write(to: outputURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.restoreOutputFromCanonicalIfNeeded())
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "unmanaged content")
    }

    private func makeStore() -> JSONStore {
        JSONStore(
            fileURL: outputURL,
            canonicalFileURL: canonicalURL,
            storeID: storeID,
            deduplicationWindow: 120
        )
    }

    private func record(
        at measuredAt: Date,
        weight: Double = 70,
        timeSource: MeasurementTimeSource = .received
    ) throws -> MeasurementRecord {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 175,
            birthDate: date("1990-01-01T00:00:00Z")
        )
        let composition = try BodyCompositionCalculator.calculate(
            weightKilograms: weight,
            impedanceRawCode: 800,
            profile: profile,
            measuredAt: measuredAt
        )
        return MeasurementRecord(
            measurement: StableMeasurement(
                measuredAt: measuredAt,
                weightKilograms: weight,
                impedanceRawCode: 800,
                rawHex: "AC000069117002000320",
                deviceName: "Synthetic Scale",
                timeSource: timeSource
            ),
            composition: composition
        )
    }

    private func measurementCount(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["measurements"] as? [Any]).count
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func permissions(of url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue & 0o777
    }
}
