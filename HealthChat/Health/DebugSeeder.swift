#if DEBUG
import Foundation
import HealthKit

final class DebugSeeder: Sendable {
    static let shared = DebugSeeder()

    private let store = HKHealthStore()
    private let calendar = Calendar.autoupdatingCurrent

    private let writeTypes: Set<HKSampleType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.bodyMass),
        HKQuantityType(.bodyFatPercentage),
        HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType()
    ]

    func seed() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthStoreError.healthDataUnavailable
        }

        try await store.requestAuthorization(toShare: writeTypes, read: writeTypes)

        var samples: [HKSample] = []
        for dayOffset in 1...30 {
            guard let day = calendar.date(
                byAdding: .day,
                value: -dayOffset,
                to: calendar.startOfDay(for: Date())
            ) else {
                continue
            }

            samples.append(contentsOf: dailySamples(for: day, offset: dayOffset))
            samples.append(contentsOf: sleepSamples(wakingOn: day, offset: dayOffset))
        }

        try await store.save(samples)

        for dayOffset in stride(from: 2, through: 29, by: 3) {
            guard let day = calendar.date(
                byAdding: .day,
                value: -dayOffset,
                to: calendar.startOfDay(for: Date())
            ) else {
                continue
            }
            try await saveWorkout(on: day, offset: dayOffset)
        }
    }

    func selfCheck() {
        print("健康查询会从 T2.2 起逐项接入此自检入口。")
    }

    private func dailySamples(for day: Date, offset: Int) -> [HKSample] {
        let sampleDate = calendar.date(byAdding: .hour, value: 12, to: day) ?? day
        let metadata = [HKMetadataKeyWasUserEntered: true]
        let steps = Double(4_000 + (offset * 1_937) % 11_001)
        let restingHeartRate = Double(55 + (offset * 7) % 16)
        let hrv = Double(30 + (offset * 13) % 51)
        let weight = 70.0 - Double(30 - offset) * 0.018 + Double(offset % 3) * 0.08
        let bodyFat = 20.0 - Double(30 - offset) * 0.012 + Double(offset % 4) * 0.07

        return [
            quantitySample(
                type: HKQuantityType(.stepCount),
                value: steps,
                unit: .count(),
                date: sampleDate,
                metadata: metadata
            ),
            quantitySample(
                type: HKQuantityType(.restingHeartRate),
                value: restingHeartRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                date: sampleDate,
                metadata: metadata
            ),
            quantitySample(
                type: HKQuantityType(.heartRateVariabilitySDNN),
                value: hrv,
                unit: .secondUnit(with: .milli),
                date: sampleDate,
                metadata: metadata
            ),
            quantitySample(
                type: HKQuantityType(.bodyMass),
                value: weight,
                unit: .gramUnit(with: .kilo),
                date: sampleDate,
                metadata: metadata
            ),
            quantitySample(
                type: HKQuantityType(.bodyFatPercentage),
                value: bodyFat / 100,
                unit: .percent(),
                date: sampleDate,
                metadata: metadata
            )
        ]
    }

    private func sleepSamples(wakingOn day: Date, offset: Int) -> [HKSample] {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let jitterMinutes = (offset * 17) % 91 - 45
        let durationMinutes = 360 + (offset * 29) % 121
        let previousDay = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        let baseBedtime = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: previousDay) ?? previousDay
        let bedtime = calendar.date(byAdding: .minute, value: jitterMinutes, to: baseBedtime) ?? baseBedtime
        let deepEnd = calendar.date(byAdding: .minute, value: durationMinutes * 2 / 10, to: bedtime) ?? bedtime
        let coreEnd = calendar.date(byAdding: .minute, value: durationMinutes * 7 / 10, to: bedtime) ?? deepEnd
        let wake = calendar.date(byAdding: .minute, value: durationMinutes, to: bedtime) ?? coreEnd
        let metadata = [HKMetadataKeyWasUserEntered: true]

        return [
            HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                start: bedtime,
                end: deepEnd,
                metadata: metadata
            ),
            HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                start: deepEnd,
                end: coreEnd,
                metadata: metadata
            ),
            HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                start: coreEnd,
                end: wake,
                metadata: metadata
            )
        ]
    }

    private func saveWorkout(on day: Date, offset: Int) async throws {
        let start = calendar.date(
            bySettingHour: 18,
            minute: (offset * 7) % 30,
            second: 0,
            of: day
        ) ?? day
        let durationMinutes = 30 + (offset * 11) % 31
        let end = calendar.date(byAdding: .minute, value: durationMinutes, to: start) ?? start
        let activity: HKWorkoutActivityType = offset.isMultiple(of: 2) ? .running : .cycling
        let energy = Double(220 + (offset * 31) % 281)

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(
            healthStore: store,
            configuration: configuration,
            device: .local()
        )
        let energySample = HKQuantitySample(
            type: HKQuantityType(.activeEnergyBurned),
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: energy),
            start: start,
            end: end,
            metadata: [HKMetadataKeyWasUserEntered: true]
        )

        try await builder.beginCollection(at: start)
        try await builder.addSamples([energySample])
        try await builder.endCollection(at: end)
        _ = try await builder.finishWorkout()
    }

    private func quantitySample(
        type: HKQuantityType,
        value: Double,
        unit: HKUnit,
        date: Date,
        metadata: [String: Any]
    ) -> HKQuantitySample {
        HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: date,
            end: date,
            metadata: metadata
        )
    }
}
#endif
