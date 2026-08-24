import Foundation
import XCTest
@testable import AFUCore

// All profiles, timestamps, weights, and impedance values in this file are synthetic.
final class BodyCompositionTests: XCTestCase {
    func testMatchesSyntheticFixtureWithCUNBAE() throws {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 175,
            birthDate: date("1990-01-01T00:00:00Z")
        )

        let result = try BodyCompositionCalculator.calculate(
            weightKilograms: 70,
            impedanceRawCode: 800,
            profile: profile,
            measuredAt: date("2025-01-02T00:00:00Z")
        )

        XCTAssertEqual(result.ageYears, 35)
        XCTAssertEqual(result.mode, .anthropometric)
        XCTAssertEqual(result.algorithmVersion, "afu-cun-bae-v2")
        XCTAssertEqual(result.weightKilograms, 70, accuracy: 0.005)
        XCTAssertEqual(result.bmi, 22.86, accuracy: 0.005)
        XCTAssertEqual(result.visceralFatIndex, 10.40, accuracy: 0.005)
        XCTAssertEqual(result.bodyFatPercentage, 19.38, accuracy: 0.005)
        XCTAssertEqual(result.fatMassKilograms, 13.56, accuracy: 0.005)
        XCTAssertEqual(result.musclePercentage, 76.52, accuracy: 0.005)
        XCTAssertEqual(result.muscleMassKilograms, 53.57, accuracy: 0.005)
        XCTAssertEqual(result.bodyWaterPercentage, 58.86, accuracy: 0.005)
        XCTAssertEqual(result.bodyWaterMassKilograms, 41.20, accuracy: 0.005)
        XCTAssertEqual(result.proteinPercentage, 17.67, accuracy: 0.005)
        XCTAssertEqual(result.proteinMassKilograms, 12.37, accuracy: 0.005)
        XCTAssertEqual(result.bonePercentage, 4.10, accuracy: 0.005)
        XCTAssertEqual(result.boneMassKilograms, 2.87, accuracy: 0.005)
        XCTAssertEqual(result.skeletalMuscleMassKilograms, 28.18, accuracy: 0.005)
        XCTAssertEqual(result.skeletalMusclePercentage, 40.25, accuracy: 0.005)
        XCTAssertEqual(result.subcutaneousFatPercentage, 13.95, accuracy: 0.005)
        XCTAssertEqual(result.subcutaneousFatMassKilograms, 9.77, accuracy: 0.005)
    }

    func testRawADCDoesNotChangeAnthropometricComposition() throws {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 175,
            birthDate: date("1990-01-01T00:00:00Z")
        )
        let measuredAt = date("2025-01-02T00:00:00Z")

        let results = try [nil, 500, 800].map { rawCode in
            try BodyCompositionCalculator.calculate(
                weightKilograms: 70,
                impedanceRawCode: rawCode,
                profile: profile,
                measuredAt: measuredAt
            )
        }

        XCTAssertEqual(results[0], results[1])
        XCTAssertEqual(results[1], results[2])
    }

    func testUsesFemaleCUNBAEFormula() throws {
        let profile = BodyProfile(
            sex: .female,
            heightCentimeters: 165,
            birthDate: date("1996-01-01T00:00:00Z")
        )

        let result = try BodyCompositionCalculator.calculate(
            weightKilograms: 60,
            impedanceRawCode: 500,
            profile: profile,
            measuredAt: date("2026-08-19T00:00:00Z")
        )

        XCTAssertEqual(result.ageYears, 30)
        XCTAssertEqual(result.mode, .anthropometric)
        XCTAssertEqual(result.bodyFatPercentage, 29.47, accuracy: 0.005)
        XCTAssertEqual(result.bonePercentage, 3.60, accuracy: 0.005)
        XCTAssertGreaterThanOrEqual(result.visceralFatIndex, 1)
        XCTAssertLessThanOrEqual(result.visceralFatIndex, 50)
    }

    func testDerivedCompartmentsMaintainMassBalance() throws {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 175,
            birthDate: date("1990-01-01T00:00:00Z")
        )

        let result = try BodyCompositionCalculator.calculate(
            weightKilograms: 70,
            impedanceRawCode: 800,
            profile: profile,
            measuredAt: date("2025-01-02T00:00:00Z")
        )

        XCTAssertEqual(
            result.fatMassKilograms
                + result.bodyWaterMassKilograms
                + result.proteinMassKilograms
                + result.boneMassKilograms,
            result.weightKilograms,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            result.muscleMassKilograms,
            result.bodyWaterMassKilograms + result.proteinMassKilograms,
            accuracy: 0.000_001
        )
    }

    func testCalculatesAgeBeforeBirthday() throws {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 180,
            birthDate: date("1992-12-01T00:00:00Z")
        )

        let result = try BodyCompositionCalculator.calculate(
            weightKilograms: 65,
            impedanceRawCode: 700,
            profile: profile,
            measuredAt: date("2026-08-19T00:00:00Z")
        )

        XCTAssertEqual(result.ageYears, 33)
    }

    func testCalculatesWithoutADCAndStillPopulatesMetrics() throws {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 175,
            birthDate: date("1990-01-01T00:00:00Z")
        )

        let result = try BodyCompositionCalculator.calculate(
            weightKilograms: 65,
            impedanceRawCode: nil,
            profile: profile,
            measuredAt: date("2025-01-02T00:00:00Z")
        )

        XCTAssertEqual(result.mode, .anthropometric)
        XCTAssertEqual(result.ageYears, 35)
        XCTAssertTrue(result.allVisibleMetrics.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(result.bodyFatPercentage, 0)
        XCTAssertGreaterThan(result.skeletalMuscleMassKilograms, 0)
    }

    func testRejectsInvalidHeight() {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 0,
            birthDate: date("1990-01-01T00:00:00Z")
        )

        XCTAssertThrowsError(
            try BodyCompositionCalculator.calculate(
                weightKilograms: 65,
                impedanceRawCode: 700,
                profile: profile,
                measuredAt: date("2026-08-19T00:00:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? BodyCompositionError, .invalidHeight(0))
        }
    }

    func testRejectsFutureBirthDate() {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 180,
            birthDate: date("2030-01-01T00:00:00Z")
        )

        XCTAssertThrowsError(
            try BodyCompositionCalculator.calculate(
                weightKilograms: 65,
                impedanceRawCode: 700,
                profile: profile,
                measuredAt: date("2026-08-19T00:00:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? BodyCompositionError, .birthDateInFuture)
        }
    }

    func testRejectsAgeOutsideCUNBAEValidationRange() {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 180,
            birthDate: date("2010-01-01T00:00:00Z")
        )

        XCTAssertThrowsError(
            try BodyCompositionCalculator.calculate(
                weightKilograms: 65,
                impedanceRawCode: 700,
                profile: profile,
                measuredAt: date("2026-08-19T00:00:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? BodyCompositionError, .unsupportedAge(16))
        }
    }

    func testRejectsRawADCOutsidePacketRange() {
        let profile = BodyProfile(
            sex: .male,
            heightCentimeters: 175,
            birthDate: date("1990-01-01T00:00:00Z")
        )

        XCTAssertThrowsError(
            try BodyCompositionCalculator.calculate(
                weightKilograms: 65,
                impedanceRawCode: 65_536,
                profile: profile,
                measuredAt: date("2026-08-19T00:00:00Z")
            )
        ) { error in
            XCTAssertEqual(error as? BodyCompositionError, .invalidImpedanceRawCode(65_536))
        }
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
