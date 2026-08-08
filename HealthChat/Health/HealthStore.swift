import Foundation
import HealthKit

struct DayValue: Sendable, Equatable {
    let date: Date
    let value: Double
}

struct NightSleep: Sendable, Equatable {
    let night: Date
    let asleep: TimeInterval
    let bedtime: Date?
    let wake: Date?
}

struct DayHeart: Sendable, Equatable {
    let date: Date
    let restingHR: Double?
    let hrv: Double?
}

struct WorkoutItem: Sendable, Equatable {
    let date: Date
    let typeName: String
    let duration: TimeInterval
    let activeEnergy: Double?
}

struct DayBody: Sendable, Equatable {
    let date: Date
    let weight: Double?
    let bodyFat: Double?
}

/// HealthKit 读取层,只读不写。所有查询返回按天聚合值(工具输出要紧凑)。
final class HealthStore: Sendable {
    static let shared = HealthStore()

    private let store = HKHealthStore()
    private let calendar = Calendar.autoupdatingCurrent

    private let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.bodyMass),
        HKQuantityType(.bodyFatPercentage),
        HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType()
    ]

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthStoreError.healthDataUnavailable
        }

        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func dailySteps(days: Int) async throws -> [DayValue] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        let samplePredicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(.stepCount),
                predicate: samplePredicate
            ),
            options: .cumulativeSum,
            anchorDate: today,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)

        return (0..<dayCount).compactMap { offset -> DayValue? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            let value = collection
                .statistics(for: date)?
                .sumQuantity()?
                .doubleValue(for: .count()) ?? 0
            return DayValue(date: date, value: value)
        }
    }

    func sleepSummary(days: Int) async throws -> [NightSleep] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startBoundary = calendar.date(
            byAdding: .hour,
            value: 12,
            to: calendar.date(byAdding: .day, value: -dayCount, to: today) ?? today
        ),
        let endBoundary = calendar.date(byAdding: .hour, value: 12, to: today) else {
            return []
        }

        let sleepType = HKCategoryType(.sleepAnalysis)
        let datePredicate = HKQuery.predicateForSamples(
            withStart: startBoundary,
            end: endBoundary,
            options: []
        )
        let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
            predicates: [
                .categorySample(type: sleepType, predicate: datePredicate)
            ],
            sortDescriptors: [
                SortDescriptor(\.startDate)
            ]
        )
        let samples = try await descriptor.result(for: store)
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
        ]

        var nights: [Date: SleepAccumulator] = [:]
        for sample in samples {
            guard let shiftedDate = calendar.date(byAdding: .hour, value: -12, to: sample.startDate) else {
                continue
            }
            let night = calendar.startOfDay(for: shiftedDate)
            var accumulator = nights[night, default: SleepAccumulator()]
            accumulator.bedtime = minDate(accumulator.bedtime, sample.startDate)
            accumulator.wake = maxDate(accumulator.wake, sample.endDate)
            if asleepValues.contains(sample.value) {
                accumulator.asleep += sample.endDate.timeIntervalSince(sample.startDate)
            }
            nights[night] = accumulator
        }

        return nights.keys.sorted().suffix(dayCount).compactMap { night in
            guard let value = nights[night] else { return nil }
            return NightSleep(
                night: night,
                asleep: value.asleep,
                bedtime: value.bedtime,
                wake: value.wake
            )
        }
    }

    func heartRateSummary(days: Int) async throws -> [DayHeart] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        async let restingCollection = dailyAverageCollection(
            type: HKQuantityType(.restingHeartRate),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let hrvCollection = dailyAverageCollection(
            type: HKQuantityType(.heartRateVariabilitySDNN),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let (resting, hrv) = try await (restingCollection, hrvCollection)
        let restingUnit = HKUnit.count().unitDivided(by: .minute())
        let hrvUnit = HKUnit.secondUnit(with: .milli)

        return (0..<dayCount).compactMap { offset -> DayHeart? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            return DayHeart(
                date: date,
                restingHR: resting
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: restingUnit),
                hrv: hrv
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: hrvUnit)
            )
        }
    }

    func workouts(days: Int) async throws -> [WorkoutItem] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        let datePredicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )
        let descriptor = HKSampleQueryDescriptor<HKWorkout>(
            predicates: [.workout(datePredicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let energyType = HKQuantityType(.activeEnergyBurned)

        return try await descriptor.result(for: store).map { workout in
            WorkoutItem(
                date: workout.startDate,
                typeName: workoutName(for: workout.workoutActivityType),
                duration: workout.duration,
                activeEnergy: workout
                    .statistics(for: energyType)?
                    .sumQuantity()?
                    .doubleValue(for: .kilocalorie())
            )
        }
    }

    func bodyMetrics(days: Int) async throws -> [DayBody] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        async let weightCollection = dailyAverageCollection(
            type: HKQuantityType(.bodyMass),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let bodyFatCollection = dailyAverageCollection(
            type: HKQuantityType(.bodyFatPercentage),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let (weights, bodyFat) = try await (weightCollection, bodyFatCollection)
        return (0..<dayCount).compactMap { offset -> DayBody? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            let weight = weights
                .statistics(for: date)?
                .averageQuantity()?
                .doubleValue(for: .gramUnit(with: .kilo))
            let fat: Double?
            if let quantity = bodyFat.statistics(for: date)?.averageQuantity() {
                fat = quantity.doubleValue(for: .percent()) * 100
            } else {
                fat = nil
            }

            guard weight != nil || fat != nil else { return nil }
            return DayBody(date: date, weight: weight, bodyFat: fat)
        }
    }

    private func dailyAverageCollection(
        type: HKQuantityType,
        startDate: Date,
        endDate: Date,
        anchorDate: Date
    ) async throws -> HKStatisticsCollection {
        let samplePredicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: samplePredicate),
            options: .discreteAverage,
            anchorDate: anchorDate,
            intervalComponents: DateComponents(day: 1)
        )
        return try await descriptor.result(for: store)
    }

    private func workoutName(for activity: HKWorkoutActivityType) -> String {
        switch activity {
        case .running:
            "跑步"
        case .cycling:
            "骑行"
        case .walking:
            "步行"
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            "力量训练"
        case .swimming:
            "游泳"
        case .hiking:
            "徒步"
        case .yoga:
            "瑜伽"
        case .highIntensityIntervalTraining:
            "高强度间歇训练"
        default:
            "其他"
        }
    }

    private func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }
}

enum HealthStoreError: LocalizedError {
    case healthDataUnavailable

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            "此设备不支持健康数据"
        }
    }
}

private struct SleepAccumulator {
    var asleep: TimeInterval = 0
    var bedtime: Date?
    var wake: Date?
}
