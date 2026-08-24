import Foundation

public enum BiologicalSex: String, Codable, Equatable, Sendable {
    case male
    case female
}

public struct BodyProfile: Codable, Equatable, Sendable {
    public let sex: BiologicalSex
    public let heightCentimeters: Double
    public let birthDate: Date

    public init(sex: BiologicalSex, heightCentimeters: Double, birthDate: Date) {
        self.sex = sex
        self.heightCentimeters = heightCentimeters
        self.birthDate = birthDate
    }
}

public enum BodyCompositionMode: String, Codable, Equatable, Sendable {
    case anthropometric
}

public enum BodyCompositionError: Error, Equatable, Sendable {
    case invalidWeight(Double)
    case invalidImpedanceRawCode(Int)
    case invalidHeight(Double)
    case birthDateInFuture
    case unsupportedAge(Int)
}

extension BodyCompositionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidWeight(value):
            return "Weight must be greater than 0 and no more than 300 kg; received \(value)"
        case let .invalidImpedanceRawCode(value):
            return "Raw impedance code must fit the packet's unsigned 16-bit field; received \(value)"
        case let .invalidHeight(value):
            return "Height must be between 100 and 250 cm; received \(value)"
        case .birthDateInFuture:
            return "Birth date cannot be later than the measurement date"
        case let .unsupportedAge(value):
            return "CUN-BAE body-composition estimation supports ages 18 through 80; received \(value)"
        }
    }
}

public struct BodyComposition: Codable, Equatable, Sendable {
    public let algorithmVersion: String
    public let mode: BodyCompositionMode
    public let ageYears: Int
    public let weightKilograms: Double
    public let bmi: Double
    public let visceralFatIndex: Double
    public let bodyFatPercentage: Double
    public let fatMassKilograms: Double
    public let musclePercentage: Double
    public let muscleMassKilograms: Double
    public let bodyWaterPercentage: Double
    public let bodyWaterMassKilograms: Double
    public let proteinPercentage: Double
    public let proteinMassKilograms: Double
    public let bonePercentage: Double
    public let boneMassKilograms: Double
    public let skeletalMuscleMassKilograms: Double
    public let skeletalMusclePercentage: Double
    public let subcutaneousFatPercentage: Double
    public let subcutaneousFatMassKilograms: Double

    public var allVisibleMetrics: [Double] {
        [
            weightKilograms,
            bmi,
            visceralFatIndex,
            bodyFatPercentage,
            fatMassKilograms,
            musclePercentage,
            muscleMassKilograms,
            bodyWaterPercentage,
            bodyWaterMassKilograms,
            proteinPercentage,
            proteinMassKilograms,
            bonePercentage,
            boneMassKilograms,
            skeletalMuscleMassKilograms,
            skeletalMusclePercentage,
            subcutaneousFatPercentage,
            subcutaneousFatMassKilograms
        ]
    }
}

public enum BodyCompositionCalculator {
    public static let algorithmVersion = "afu-cun-bae-v2"

    public static func calculate(
        weightKilograms: Double,
        impedanceRawCode: Int?,
        profile: BodyProfile,
        measuredAt: Date
    ) throws -> BodyComposition {
        guard weightKilograms > 0, weightKilograms <= 300 else {
            throw BodyCompositionError.invalidWeight(weightKilograms)
        }
        if let impedanceRawCode, !(0 ... Int(UInt16.max)).contains(impedanceRawCode) {
            throw BodyCompositionError.invalidImpedanceRawCode(impedanceRawCode)
        }
        guard (100 ... 250).contains(profile.heightCentimeters) else {
            throw BodyCompositionError.invalidHeight(profile.heightCentimeters)
        }
        guard profile.birthDate <= measuredAt else {
            throw BodyCompositionError.birthDateInFuture
        }

        let age = ageYears(birthDate: profile.birthDate, at: measuredAt)
        guard (18 ... 80).contains(age) else {
            throw BodyCompositionError.unsupportedAge(age)
        }

        let heightMeters = profile.heightCentimeters / 100.0
        let bmi = weightKilograms / (heightMeters * heightMeters)
        let ageValue = Double(age)
        let female = profile.sex == .female ? 1.0 : 0.0
        let bmiSquared = bmi * bmi
        // Gómez-Ambrosi et al. (2012), CUN-BAE; sex is 0 for male and 1 for female.
        let bodyFatEstimate = -44.988
            + 0.503 * ageValue
            + 10.689 * female
            + 3.172 * bmi
            - 0.026 * bmiSquared
            + 0.181 * bmi * female
            - 0.020 * bmi * ageValue
            - 0.005 * bmiSquared * female
            + 0.00021 * bmiSquared * ageValue
        let bodyFatPercentage = clamp(bodyFatEstimate, minimum: 5, maximum: 55)
        let fatMassKilograms = weightKilograms * bodyFatPercentage / 100.0
        let fatFreeMassKilograms = weightKilograms - fatMassKilograms
        let bodyWaterMassKilograms = fatFreeMassKilograms * 0.73
        let bodyWaterPercentage = bodyWaterMassKilograms / weightKilograms * 100.0
        let estimatedBoneMassKilograms = clamp(
            weightKilograms * (profile.sex == .male ? 0.041 : 0.036),
            minimum: 1.5,
            maximum: 5.5
        )
        let boneMassKilograms = min(
            estimatedBoneMassKilograms,
            fatFreeMassKilograms * (1.0 - 0.73)
        )
        let bonePercentage = boneMassKilograms / weightKilograms * 100.0
        let muscleMassKilograms = fatFreeMassKilograms - boneMassKilograms
        let musclePercentage = muscleMassKilograms / weightKilograms * 100.0
        let proteinMassKilograms = muscleMassKilograms - bodyWaterMassKilograms
        let proteinPercentage = proteinMassKilograms / weightKilograms * 100.0
        let skeletalMuscleMassKilograms = muscleMassKilograms * 0.526
        let skeletalMusclePercentage = musclePercentage * 0.526
        let subcutaneousFatPercentage = bodyFatPercentage * 0.72
        let subcutaneousFatMassKilograms = weightKilograms * subcutaneousFatPercentage / 100.0

        return BodyComposition(
            algorithmVersion: algorithmVersion,
            mode: .anthropometric,
            ageYears: age,
            weightKilograms: weightKilograms,
            bmi: bmi,
            visceralFatIndex: visceralFatIndex(
                sex: profile.sex,
                heightCentimeters: profile.heightCentimeters,
                weightKilograms: weightKilograms,
                ageYears: age
            ),
            bodyFatPercentage: bodyFatPercentage,
            fatMassKilograms: fatMassKilograms,
            musclePercentage: musclePercentage,
            muscleMassKilograms: muscleMassKilograms,
            bodyWaterPercentage: bodyWaterPercentage,
            bodyWaterMassKilograms: bodyWaterMassKilograms,
            proteinPercentage: proteinPercentage,
            proteinMassKilograms: proteinMassKilograms,
            bonePercentage: bonePercentage,
            boneMassKilograms: boneMassKilograms,
            skeletalMuscleMassKilograms: skeletalMuscleMassKilograms,
            skeletalMusclePercentage: skeletalMusclePercentage,
            subcutaneousFatPercentage: subcutaneousFatPercentage,
            subcutaneousFatMassKilograms: subcutaneousFatMassKilograms
        )
    }

    static func ageYears(birthDate: Date, at measurementDate: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateComponents([.year], from: birthDate, to: measurementDate).year ?? 0
    }

    private static func visceralFatIndex(
        sex: BiologicalSex,
        heightCentimeters: Double,
        weightKilograms: Double,
        ageYears: Int
    ) -> Double {
        let age = Double(ageYears)
        let estimate: Double

        switch sex {
        case .female:
            if weightKilograms > heightCentimeters * 0.5 - 13.0 {
                let denominator = heightCentimeters * 1.45
                    + heightCentimeters * 0.1158 * heightCentimeters
                    - 120.0
                estimate = weightKilograms * 500.0 / denominator - 6.0 + age * 0.07
            } else {
                let coefficient = 0.691 - heightCentimeters * 0.0048
                estimate = (heightCentimeters * 0.027 - coefficient * weightKilograms) * -1.0
                    + age * 0.07
                    - age
            }
        case .male:
            if heightCentimeters < weightKilograms * 1.6 {
                let denominator = (heightCentimeters * 0.4
                    - heightCentimeters * heightCentimeters * 0.0826) * -1.0
                estimate = weightKilograms * 305.0 / (denominator + 48.0) - 2.9 + age * 0.15
            } else {
                let coefficient = 0.765 - heightCentimeters * 0.0015
                estimate = (heightCentimeters * 0.143 - weightKilograms * coefficient) * -1.0
                    + age * 0.15
                    - 5.0
            }
        }

        return clamp(estimate, minimum: 1, maximum: 50)
    }

    private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }
}
