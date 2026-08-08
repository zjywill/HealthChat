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

struct DayBloodPressure: Sendable, Equatable {
    let date: Date
    let systolic: Double?
    let diastolic: Double?
}

/// 血氧、呼吸频率、体温——都是"有就看看,没有很正常"的项。
struct DayVitals: Sendable, Equatable {
    let date: Date
    /// 百分比,已经乘过 100。
    let oxygen: Double?
    let respiratoryRate: Double?
    /// 睡眠期间的手腕温度(Apple Watch),摄氏度。
    let wristTemperature: Double?
    let bodyTemperature: Double?
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
        HKObjectType.workoutType(),
        // 下面这几项多数人没有数据(血压要血压计、血氧和手腕温度要够新的 Apple Watch)。
        // 照样申请:授权本身不要求有数据,等用户以后真的记了就直接能读到。
        HKQuantityType(.bloodPressureSystolic),
        HKQuantityType(.bloodPressureDiastolic),
        HKQuantityType(.oxygenSaturation),
        HKQuantityType(.respiratoryRate),
        HKQuantityType(.bodyTemperature),
        HKQuantityType(.appleSleepingWristTemperature)
    ]

    /// 需要问的时候才问,返回这次有没有真的弹窗。
    ///
    /// 所有类型都已经决定过时再调 `requestAuthorization`,iOS 仍然会把授权面板推上来
    /// 再立刻收回去——启动时看着就是"闪一下"。`statusForAuthorizationRequest` 能在
    /// 不弹任何 UI 的情况下问清楚"还需不需要问"。
    @discardableResult
    func requestAuthorizationIfNeeded() async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthStoreError.healthDataUnavailable
        }

        let status = try await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        guard status == .shouldRequest else { return false }

        try await store.requestAuthorization(toShare: [], read: readTypes)
        return true
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
            if asleepValues.contains(sample.value), sample.endDate > sample.startDate {
                accumulator.asleepIntervals.append(
                    DateInterval(start: sample.startDate, end: sample.endDate)
                )
            }
            nights[night] = accumulator
        }

        return nights.keys.sorted().suffix(dayCount).compactMap { night in
            guard let value = nights[night] else { return nil }
            return NightSleep(
                night: night,
                asleep: mergedDuration(of: value.asleepIntervals),
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

    /// `activity` 传了就只返回那一类锻炼。名字用 `workoutName(for:)` 那套中文名。
    func workouts(days: Int, activity: String? = nil) async throws -> [WorkoutItem] {
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

        return try await descriptor.result(for: store).compactMap { workout in
            let typeName = workoutName(for: workout.workoutActivityType)
            guard activity == nil || activity == typeName else { return nil }

            return WorkoutItem(
                date: workout.startDate,
                typeName: typeName,
                duration: workout.duration,
                activeEnergy: workout
                    .statistics(for: energyType)?
                    .sumQuantity()?
                    .doubleValue(for: .kilocalorie())
            )
        }
    }

    func bloodPressureSummary(days: Int) async throws -> [DayBloodPressure] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        async let systolicCollection = dailyAverageCollection(
            type: HKQuantityType(.bloodPressureSystolic),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let diastolicCollection = dailyAverageCollection(
            type: HKQuantityType(.bloodPressureDiastolic),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let systolic: HKStatisticsCollection
        let diastolic: HKStatisticsCollection
        do {
            (systolic, diastolic) = try await (systolicCollection, diastolicCollection)
        } catch let error as HKError where Self.isAuthorizationIssue(error) {
            // 没授权和没数据对用户是一回事:渲染层会提示去检查授权,不该抛成"查询失败"。
            return []
        }
        let unit = HKUnit.millimeterOfMercury()

        return (0..<dayCount).compactMap { offset -> DayBloodPressure? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            return DayBloodPressure(
                date: date,
                systolic: systolic.statistics(for: date)?.averageQuantity()?.doubleValue(for: unit),
                diastolic: diastolic.statistics(for: date)?.averageQuantity()?.doubleValue(for: unit)
            )
        }
    }

    func vitalsSummary(days: Int) async throws -> [DayVitals] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        async let oxygenCollection = dailyAverageCollection(
            type: HKQuantityType(.oxygenSaturation),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let breathingCollection = dailyAverageCollection(
            type: HKQuantityType(.respiratoryRate),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let wristCollection = dailyAverageCollection(
            type: HKQuantityType(.appleSleepingWristTemperature),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let bodyTemperatureCollection = dailyAverageCollection(
            type: HKQuantityType(.bodyTemperature),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let oxygen: HKStatisticsCollection
        let breathing: HKStatisticsCollection
        let wrist: HKStatisticsCollection
        let temperature: HKStatisticsCollection
        do {
            (oxygen, breathing, wrist, temperature) = try await (
                oxygenCollection, breathingCollection, wristCollection, bodyTemperatureCollection
            )
        } catch let error as HKError where Self.isAuthorizationIssue(error) {
            return []
        }
        let breathingUnit = HKUnit.count().unitDivided(by: .minute())
        let celsius = HKUnit.degreeCelsius()

        return (0..<dayCount).compactMap { offset -> DayVitals? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            let saturation = oxygen
                .statistics(for: date)?
                .averageQuantity()?
                .doubleValue(for: .percent())

            return DayVitals(
                date: date,
                // HealthKit 的血氧是 0–1 的比例,展示要的是 96 不是 0.96。
                oxygen: saturation.map { $0 * 100 },
                respiratoryRate: breathing
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: breathingUnit),
                wristTemperature: wrist
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: celsius),
                bodyTemperature: temperature
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: celsius)
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

    /// 用户没授权某个类型时,统计查询会抛错而不是返回空。血压、血氧这些多数人本来就
    /// 没有,更常见的是压根没允许读——那不该表现成"查询失败"。
    private static func isAuthorizationIssue(_ error: HKError) -> Bool {
        error.code == .errorAuthorizationNotDetermined || error.code == .errorAuthorizationDenied
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

    /// 睡眠样本会重叠:iPhone 和 Apple Watch 同时记录、同一份数据被写入两次、
    /// 或分期样本(核心/深度/REM)与一条 asleepUnspecified 并存。逐条累加时长会
    /// 因此翻倍——曾经算出一晚睡 28 小时。合并重叠区间后再求和。
    private func mergedDuration(of intervals: [DateInterval]) -> TimeInterval {
        var total: TimeInterval = 0
        var running: DateInterval?

        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            guard let current = running else {
                running = interval
                continue
            }
            if interval.start <= current.end {
                running = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                total += current.duration
                running = interval
            }
        }

        return total + (running?.duration ?? 0)
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
    var asleepIntervals: [DateInterval] = []
    var bedtime: Date?
    var wake: Date?
}
