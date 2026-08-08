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

        return (0..<dayCount).compactMap { offset in
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

    // TODO(M2): 其余三个聚合查询,对应 HealthTools。
    // func heartRateSummary(days: Int) async throws -> ...
    // func workouts(days: Int) async throws -> ...
    // func bodyMetrics(days: Int) async throws -> ...

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
