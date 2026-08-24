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

    private func record(at measuredAt: Date) throws -> MeasurementRecord {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 175,
            birthDate: date("1990-01-01T00:00:00Z")
        )
        let composition = try BodyCompositionCalculator.calculate(
            weightKilograms: 70,
            impedanceRawCode: 800,
            profile: profile,
            measuredAt: measuredAt
        )
        return MeasurementRecord(
            measurement: StableMeasurement(
                measuredAt: measuredAt,
                weightKilograms: 70,
                impedanceRawCode: 800,
                rawHex: "AC000069117002000320",
                deviceName: "Synthetic Scale"
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
