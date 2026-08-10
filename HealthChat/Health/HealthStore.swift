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
    /// 分期时长。只有 Apple Watch 记的睡眠才分期;iPhone 写的是 asleepUnspecified,
    /// 这三项就都是 0——那种情况下别去解读"深睡不足"。
    var deep: TimeInterval = 0
    var core: TimeInterval = 0
    var rem: TimeInterval = 0
    /// 卧床期间清醒的时长,和入睡后醒来的次数。
    var awake: TimeInterval = 0
    var wakeCount: Int = 0
    /// 睡眠时段的平均心率和最低心率。
    var heartRate: Double?
    var lowestHeartRate: Double?

    /// 睡眠效率:睡着的时间占卧床时间的百分比。
    var efficiency: Double? {
        guard let bedtime, let wake else { return nil }
        let inBed = wake.timeIntervalSince(bedtime)
        guard inBed > 0, asleep > 0 else { return nil }
        return min(asleep / inBed, 1) * 100
    }

    /// 分期数据存在才有意义:三项全 0 说明这晚只有"睡着"没有分期。
    var hasStages: Bool { deep > 0 || core > 0 || rem > 0 }
}

struct DayHeart: Sendable, Equatable {
    let date: Date
    let restingHR: Double?
    let hrv: Double?
    /// 全天心率的低/高/平均。静息心率只有一天一个值,看不出白天冲到过多少。
    var lowestHR: Double?
    var highestHR: Double?
    var averageHR: Double?
}

struct WorkoutItem: Sendable, Equatable {
    let date: Date
    let typeName: String
    let duration: TimeInterval
    let activeEnergy: Double?
    /// 公里。跑步/骑行/游泳各自的距离类型,取到哪个算哪个。
    var distance: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
}

/// 一天的活动量。步数之外还有距离、爬楼和运动分钟——只报步数会把骑行和力量训练
/// 那种"步数不动但练了"的日子说成久坐。
struct DayActivity: Sendable, Equatable {
    let date: Date
    let steps: Double
    /// 公里。
    var distance: Double?
    var flights: Double?
    var exerciseMinutes: Double?
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

/// 一条化验/体征记录。来自医院或诊所同步进「健康」的 FHIR 数据。
struct ClinicalItem: Sendable, Equatable {
    let date: Date
    let name: String
    /// "5.4 mmol/L";没有数值的记录(诊断、用药)这里是 nil。
    let value: String?
    let category: String
}

/// HealthKit 读取层,只读不写。所有查询返回按天聚合值(工具输出要紧凑)。
final class HealthStore: Sendable {
    /// 这台设备上的健康数据**只有机主一个人的**(见 `Tenant.Kind`)。
    ///
    /// 归属这件事的真正防线在调用方:健康工具在家人身上一个都不挂,`HealthSituation`、
    /// `SpokenBrief`、check-in 也都不跑。这里这道断言是补网——漏掉其中一条路的后果是把机主的
    /// 数字端到另一个人名下,静默、看着正常、事后查不出来,所以宁可在开发期当场崩掉。
    ///
    /// 只在 DEBUG 崩。线上真漏了一条,让用户看到一个错的数字也好过让 app 挂掉——但那条路
    /// 应该在这之前就被这句断言逼出来了。
    static var shared: HealthStore {
        assert(
            TenantScope.isOwnerActive,
            "当前是家人成员（\(TenantScope.current.displayName)），这台设备的健康数据不属于他。"
                + "调用方应该先按 Tenant.isOwner 挡住这条路。"
        )
        return owner
    }

    /// 不看当前选中的是谁。check-in、Siri 播报、后台派生这几件从头到尾都是机主的事,
    /// 它们要的就是这一份(同 `TenantScope.ownerStores`)。
    static let owner = HealthStore()

    /// 算个人基线用多长的窗口。
    ///
    /// 60 天而不是 14 天:两周里一次熬夜就能把"平常"拉偏一大截。取中位数而不是均值,
    /// 出于同一个理由——异常值不该定义什么叫正常。
    static let baselineDays = 60

    private let store = HKHealthStore()
    private let calendar = Calendar.autoupdatingCurrent

    private let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.distanceCycling),
        HKQuantityType(.distanceSwimming),
        HKQuantityType(.flightsClimbed),
        HKQuantityType(.appleExerciseTime),
        HKQuantityType(.restingHeartRate),
        // 逐次心率。静息心率是一天一个汇总值,睡眠期间心率、白天峰值都得从这里来。
        HKQuantityType(.heartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.bodyMass),
        HKQuantityType(.bodyFatPercentage),
        HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType(),
        // 下面这几项多数人没有数据(血压要血压计、血氧和手腕温度要够新的 Apple Watch)。
        // 照样申请:授权本身不要求有数据,等用户以后真的记了就直接能读到。
        HKQuantityType(.oxygenSaturation),
        HKQuantityType(.respiratoryRate),
        HKQuantityType(.bodyTemperature),
        HKQuantityType(.appleSleepingWristTemperature)
    ]

    /// 真的要读的时候才申请的类型。
    ///
    /// 血压和病历都有同一个毛病:授权状态永远停在 `shouldRequest`。血压在 HealthKit 里
    /// 是一对关联数据,授权面板上只有"血压"一行,给了之后两个数量类型各自查仍然算没决定;
    /// 病历在模拟器上根本给不了。于是只要它们在启动请求里,每次启动都会弹一次面板又被
    /// 立刻收回去——就是那个闪屏,而且永远闪不完。
    ///
    /// 挪到按需申请还顺带解决了另一件事:用户还没问任何问题,就弹窗要读化验单,本来
    /// 就过界了。
    private let bloodPressureReadTypes: Set<HKObjectType> = [
        HKQuantityType(.bloodPressureSystolic),
        HKQuantityType(.bloodPressureDiastolic)
    ]

    private let clinicalReadTypes: Set<HKObjectType> = [
        HKClinicalType(.labResultRecord),
        HKClinicalType(.vitalSignRecord)
    ]

    /// 一次运行里只自动问一次。
    ///
    /// 从设置返回时 SwiftUI 会让根视图重新 appear,挂在上面的 `.task` 跟着重跑;
    /// 每跑一次就请求一次授权,面板就闪一次。设置页那个按钮传 `force: true` 绕开它。
    @MainActor private static var hasRequestedThisLaunch = false

    /// 需要问的时候才问,返回这次有没有真的弹窗。
    ///
    /// 所有类型都已经决定过时再调 `requestAuthorization`,iOS 仍然会把授权面板推上来
    /// 再立刻收回去。`statusForAuthorizationRequest` 能在不弹任何 UI 的情况下问清楚
    /// "还需不需要问"。
    @MainActor
    @discardableResult
    func requestAuthorizationIfNeeded(force: Bool = false) async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthStoreError.healthDataUnavailable
        }
        if !force {
            guard !Self.hasRequestedThisLaunch else { return false }
        }
        Self.hasRequestedThisLaunch = true

        // force 时把按需那几类也一起问了:设置页那个按钮是用户主动点的,
        // 一次问全比让他们各点一遍强。
        let requested = force ? readTypes.union(bloodPressureReadTypes).union(clinicalReadTypes) : readTypes
        let status = try await store.statusForAuthorizationRequest(toShare: [], read: requested)
        guard status == .shouldRequest else { return false }

        try await store.requestAuthorization(toShare: [], read: requested)
        return true
    }

    /// 后台读数据之前能问清楚的三种状态。
    enum ReadAccess: Sendable {
        case ready
        /// 还没问过授权。后台弹不出面板,只能让用户先打开 app。
        case notRequested
        case unavailable
    }

    /// 现在能不能直接读,**不弹任何 UI**。
    ///
    /// Siri 那条路跑在后台,授权面板推不上来。所以在查之前先问一句:没问过授权就照实说
    /// "先打开 Vana",而不是查出一片空然后报"最近没有数据"——后者是在撒谎。
    func readAccess() async -> ReadAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        return status == .shouldRequest ? .notRequested : .ready
    }

    /// 锁屏时整个 HealthKit 库都读不了。这不是"没有数据",得分开说。
    static func isDatabaseLocked(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == HKError.errorDomain
            && error.code == HKError.errorDatabaseInaccessible.rawValue
    }

    /// 按需授权:第一次真的要读的时候才问,一次运行只问一次。
    @MainActor private static var requestedOnDemand: Set<String> = []

    @MainActor
    private func requestOnDemand(_ types: Set<HKObjectType>, key: String) async {
        guard !Self.requestedOnDemand.contains(key) else { return }
        Self.requestedOnDemand.insert(key)

        guard let status = try? await store.statusForAuthorizationRequest(toShare: [], read: types),
              status == .shouldRequest else {
            return
        }
        try? await store.requestAuthorization(toShare: [], read: types)
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

    /// 每日活动量:步数、步行跑步距离、爬楼层数、运动分钟。
    ///
    /// 后三项没有记录时是 nil 而不是 0——"没有 Apple Watch 所以没有运动分钟"和
    /// "今天一分钟都没动"是两回事。
    func dailyActivity(days: Int) async throws -> [DayActivity] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        async let stepCollection = dailyCollection(
            type: HKQuantityType(.stepCount),
            options: .cumulativeSum,
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let distanceCollection = dailyCollection(
            type: HKQuantityType(.distanceWalkingRunning),
            options: .cumulativeSum,
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let flightCollection = dailyCollection(
            type: HKQuantityType(.flightsClimbed),
            options: .cumulativeSum,
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let exerciseCollection = dailyCollection(
            type: HKQuantityType(.appleExerciseTime),
            options: .cumulativeSum,
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let steps = try await stepCollection
        // 距离、楼层、运动分钟没授权就当没有,不该让整个活动量查询失败。
        let distance = try? await distanceCollection
        let flights = try? await flightCollection
        let exercise = try? await exerciseCollection

        return (0..<dayCount).compactMap { offset -> DayActivity? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            return DayActivity(
                date: date,
                steps: steps.statistics(for: date)?.sumQuantity()?.doubleValue(for: .count()) ?? 0,
                distance: distance?
                    .statistics(for: date)?
                    .sumQuantity()?
                    .doubleValue(for: .meterUnit(with: .kilo)),
                flights: flights?.statistics(for: date)?.sumQuantity()?.doubleValue(for: .count()),
                exerciseMinutes: exercise?
                    .statistics(for: date)?
                    .sumQuantity()?
                    .doubleValue(for: .minute())
            )
        }
    }

    /// `includeHeartRate` 为真时,额外查每一晚睡眠时段的心率(每晚一次查询)。
    /// 算基线的那趟不要开——60 晚就是 60 次查询,而基线只用得上时长。
    func sleepSummary(days: Int, includeHeartRate: Bool = false) async throws -> [NightSleep] {
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
            guard sample.endDate > sample.startDate else { continue }
            let night = calendar.startOfDay(for: shiftedDate)
            let interval = DateInterval(start: sample.startDate, end: sample.endDate)
            var accumulator = nights[night, default: SleepAccumulator()]
            accumulator.bedtime = minDate(accumulator.bedtime, sample.startDate)
            accumulator.wake = maxDate(accumulator.wake, sample.endDate)

            if asleepValues.contains(sample.value) {
                accumulator.asleepIntervals.append(interval)
            }
            switch sample.value {
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                accumulator.deepIntervals.append(interval)
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                accumulator.coreIntervals.append(interval)
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                accumulator.remIntervals.append(interval)
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                accumulator.awakeIntervals.append(interval)
            default:
                break
            }
            nights[night] = accumulator
        }

        var result: [NightSleep] = []
        for night in nights.keys.sorted().suffix(dayCount) {
            guard let value = nights[night] else { continue }
            let asleepStart = value.asleepIntervals.map(\.start).min()
            let awake = merged(value.awakeIntervals)

            var item = NightSleep(
                night: night,
                asleep: totalDuration(of: value.asleepIntervals),
                bedtime: value.bedtime,
                wake: value.wake,
                deep: totalDuration(of: value.deepIntervals),
                core: totalDuration(of: value.coreIntervals),
                rem: totalDuration(of: value.remIntervals),
                awake: awake.reduce(0) { $0 + $1.duration },
                // 躺下还没睡着那段不算"醒来";只数入睡之后的,而且掐掉一两分钟的翻身。
                wakeCount: awake.filter { segment in
                    segment.duration >= 60 && asleepStart.map { segment.start > $0 } == true
                }.count
            )

            if includeHeartRate, let bedtime = item.bedtime, let wake = item.wake, wake > bedtime {
                let heart = try? await heartRateStatistics(from: bedtime, to: wake)
                item.heartRate = heart?.average
                item.lowestHeartRate = heart?.lowest
            }
            result.append(item)
        }
        return result
    }

    /// 一段时间内的心率统计。睡眠时段心率就是拿这个按每晚的卧床区间去问的。
    func heartRateStatistics(
        from start: Date,
        to end: Date
    ) async throws -> (average: Double?, lowest: Double?, highest: Double?) {
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(.heartRate),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            ),
            options: [.discreteAverage, .discreteMin, .discreteMax]
        )
        let unit = HKUnit.count().unitDivided(by: .minute())

        do {
            let statistics = try await descriptor.result(for: store)
            return (
                statistics?.averageQuantity()?.doubleValue(for: unit),
                statistics?.minimumQuantity()?.doubleValue(for: unit),
                statistics?.maximumQuantity()?.doubleValue(for: unit)
            )
        } catch let error as HKError where Self.isAuthorizationIssue(error) {
            return (nil, nil, nil)
        }
    }

    /// 逐小时步数。给面板画日内分布用,不进模型上下文。
    func hourlySteps(from start: Date, to end: Date) async throws -> [DayValue] {
        try await hourlyValues(
            type: HKQuantityType(.stepCount),
            unit: .count(),
            options: .cumulativeSum,
            from: start,
            to: end
        )
    }

    /// 逐小时平均心率。夜间那段就是拿睡眠的卧床区间来问的。
    func hourlyHeartRate(from start: Date, to end: Date) async throws -> [DayValue] {
        try await hourlyValues(
            type: HKQuantityType(.heartRate),
            unit: HKUnit.count().unitDivided(by: .minute()),
            options: .discreteAverage,
            from: start,
            to: end
        )
    }

    private func hourlyValues(
        type: HKQuantityType,
        unit: HKUnit,
        options: HKStatisticsOptions,
        from start: Date,
        to end: Date
    ) async throws -> [DayValue] {
        guard end > start else { return [] }
        let anchor = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            ),
            options: options,
            anchorDate: anchor,
            intervalComponents: DateComponents(hour: 1)
        )

        let collection: HKStatisticsCollection
        do {
            collection = try await descriptor.result(for: store)
        } catch let error as HKError where Self.isAuthorizationIssue(error) {
            return []
        }

        var values: [DayValue] = []
        collection.enumerateStatistics(from: anchor, to: end) { statistics, _ in
            let quantity = options.contains(.cumulativeSum)
                ? statistics.sumQuantity()
                : statistics.averageQuantity()
            guard let value = quantity?.doubleValue(for: unit) else { return }
            values.append(DayValue(date: statistics.startDate, value: value))
        }
        return values
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
        // 全天心率的低/高/平均一次查完:三个统计量共用一个 collection。
        async let heartCollection = dailyCollection(
            type: HKQuantityType(.heartRate),
            options: [.discreteAverage, .discreteMin, .discreteMax],
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let (resting, hrv) = try await (restingCollection, hrvCollection)
        let heart = try? await heartCollection
        let restingUnit = HKUnit.count().unitDivided(by: .minute())
        let hrvUnit = HKUnit.secondUnit(with: .milli)

        return (0..<dayCount).compactMap { offset -> DayHeart? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            let daily = heart?.statistics(for: date)
            return DayHeart(
                date: date,
                restingHR: resting
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: restingUnit),
                hrv: hrv
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: hrvUnit),
                lowestHR: daily?.minimumQuantity()?.doubleValue(for: restingUnit),
                highestHR: daily?.maximumQuantity()?.doubleValue(for: restingUnit),
                averageHR: daily?.averageQuantity()?.doubleValue(for: restingUnit)
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
        let heartUnit = HKUnit.count().unitDivided(by: .minute())
        let kilometer = HKUnit.meterUnit(with: .kilo)

        return try await descriptor.result(for: store).compactMap { workout in
            let typeName = workoutName(for: workout.workoutActivityType)
            guard activity == nil || activity == typeName else { return nil }

            // 距离按运动类型分了三个数量类型,哪个有值算哪个(游泳那个单位也是米)。
            let distance = [
                HKQuantityType(.distanceWalkingRunning),
                HKQuantityType(.distanceCycling),
                HKQuantityType(.distanceSwimming)
            ].lazy.compactMap {
                workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: kilometer)
            }.first { $0 > 0 }

            let heart = workout.statistics(for: HKQuantityType(.heartRate))
            return WorkoutItem(
                date: workout.startDate,
                typeName: typeName,
                duration: workout.duration,
                activeEnergy: workout
                    .statistics(for: energyType)?
                    .sumQuantity()?
                    .doubleValue(for: .kilocalorie()),
                distance: distance,
                averageHeartRate: heart?.averageQuantity()?.doubleValue(for: heartUnit),
                maxHeartRate: heart?.maximumQuantity()?.doubleValue(for: heartUnit)
            )
        }
    }

    func bloodPressureSummary(days: Int) async throws -> [DayBloodPressure] {
        await requestOnDemand(bloodPressureReadTypes, key: "bloodPressure")

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

    /// 「健康」里的体检报告和化验单(FHIR)。
    ///
    /// 只有用户在「健康」App 里连过医院或诊所才会有;没连过就是空的,跟血压一样属于
    /// "没有很正常"。这里只取化验结果和体征两类——诊断和用药涉及的解读责任太重。
    func clinicalRecords(days: Int) async throws -> [ClinicalItem] {
        // 用户真的问到化验单了,这时候申请授权才说得过去。
        await requestOnDemand(clinicalReadTypes, key: "clinical")

        let dayCount = min(max(days, 1), 3650)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -dayCount, to: today) else {
            return []
        }

        let types: [(HKClinicalType, String)] = [
            (HKClinicalType(.labResultRecord), "化验"),
            (HKClinicalType(.vitalSignRecord), "体征")
        ]

        var items: [ClinicalItem] = []
        for (type, category) in types {
            let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: [])
            let descriptor = HKSampleQueryDescriptor<HKClinicalRecord>(
                predicates: [.clinicalRecord(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
                limit: 100
            )

            let records: [HKClinicalRecord]
            do {
                records = try await descriptor.result(for: store)
            } catch let error as HKError where Self.isAuthorizationIssue(error) {
                continue
            }

            items.append(contentsOf: records.map { record in
                ClinicalItem(
                    date: record.startDate,
                    name: record.displayName,
                    value: Self.fhirValue(from: record),
                    category: category
                )
            })
        }

        return items.sorted { $0.date > $1.date }
    }

    /// 从 FHIR 里挖出数值。
    ///
    /// 只认 Observation 的 `valueQuantity`——真正想比较的是"血糖 5.4 mmol/L"这种。
    /// 其他形状(区间、编码值、组合观测)一律不猜,留空让模型只报名称和日期。
    private static func fhirValue(from record: HKClinicalRecord) -> String? {
        guard let data = record.fhirResource?.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quantity = json["valueQuantity"] as? [String: Any],
              let value = quantity["value"] as? Double else {
            return nil
        }
        let unit = (quantity["unit"] as? String) ?? ""
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        return unit.isEmpty ? number : "\(number) \(unit)"
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
        try await dailyCollection(
            type: type,
            options: .discreteAverage,
            startDate: startDate,
            endDate: endDate,
            anchorDate: anchorDate
        )
    }

    private func dailyCollection(
        type: HKQuantityType,
        options: HKStatisticsOptions,
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
            options: options,
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
    private func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        var running: DateInterval?

        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            guard let current = running else {
                running = interval
                continue
            }
            if interval.start <= current.end {
                running = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                result.append(current)
                running = interval
            }
        }

        if let running {
            result.append(running)
        }
        return result
    }

    private func totalDuration(of intervals: [DateInterval]) -> TimeInterval {
        merged(intervals).reduce(0) { $0 + $1.duration }
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
    var deepIntervals: [DateInterval] = []
    var coreIntervals: [DateInterval] = []
    var remIntervals: [DateInterval] = []
    var awakeIntervals: [DateInterval] = []
    var bedtime: Date?
    var wake: Date?
}
