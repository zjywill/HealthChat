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
        HKObjectType.workoutType(),
        HKQuantityType(.bloodPressureSystolic),
        HKQuantityType(.bloodPressureDiastolic),
        HKQuantityType(.oxygenSaturation),
        HKQuantityType(.respiratoryRate),
        // 手腕温度只有 Apple Watch 能写,app 申请写权限会直接抛异常;这里改写体温,
        // 读取那侧两个都留着。
        HKQuantityType(.bodyTemperature)
    ]

    /// 写入种子数据,返回因为没有写权限而跳过的数据类型。
    ///
    /// 按类型分开写:用户在授权弹窗里关掉某一项(或者压根没勾),不该让整批数据都写不进去。
    @discardableResult
    func seed() async throws -> [String] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthStoreError.healthDataUnavailable
        }

        try await store.requestAuthorization(toShare: writeTypes, read: writeTypes)
        await deletePreviousSeed()

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

        var skipped: Set<String> = []
        for (_, group) in Dictionary(grouping: samples, by: { $0.sampleType.identifier }) {
            do {
                try await store.save(group)
            } catch let error as HKError where Self.isAuthorizationIssue(error) {
                skipped.insert(Self.friendlyName(for: group[0].sampleType))
            }
        }

        for dayOffset in stride(from: 2, through: 29, by: 3) {
            guard let day = calendar.date(
                byAdding: .day,
                value: -dayOffset,
                to: calendar.startOfDay(for: Date())
            ) else {
                continue
            }
            do {
                try await saveWorkout(on: day, offset: dayOffset)
            } catch let error as HKError where Self.isAuthorizationIssue(error) {
                skipped.insert("锻炼")
            }
        }

        // 一条都没写进去说明整个授权都没给,那才算失败。
        if skipped.count == Dictionary(grouping: samples, by: { $0.sampleType.identifier }).count {
            throw HealthStoreError.healthDataUnavailable
        }
        return skipped.sorted()
    }

    private static func isAuthorizationIssue(_ error: HKError) -> Bool {
        error.code == .errorAuthorizationNotDetermined || error.code == .errorAuthorizationDenied
    }

    private static func friendlyName(for type: HKSampleType) -> String {
        switch type {
        case HKQuantityType(.stepCount): "步数"
        case HKQuantityType(.restingHeartRate): "静息心率"
        case HKQuantityType(.heartRateVariabilitySDNN): "HRV"
        case HKQuantityType(.bodyMass): "体重"
        case HKQuantityType(.bodyFatPercentage): "体脂"
        case HKQuantityType(.bloodPressureSystolic): "收缩压"
        case HKQuantityType(.bloodPressureDiastolic): "舒张压"
        case HKQuantityType(.oxygenSaturation): "血氧"
        case HKQuantityType(.respiratoryRate): "呼吸频率"
        case HKQuantityType(.bodyTemperature): "体温"
        case HKCategoryType(.sleepAnalysis): "睡眠"
        default: type.identifier
        }
    }

    /// 先删掉本 app 上次写的样本,再写新的。
    ///
    /// HealthKit 不去重:重复点「写入种子数据」就是重复写入,步数直接翻倍、
    /// 一晚睡眠加到 28 小时。只删自己写的,用户真实的健康记录不受影响。
    private func deletePreviousSeed() async {
        let ownSamples = HKQuery.predicateForObjects(from: HKSource.default())

        for type in writeTypes {
            // 删不掉不是致命问题:没写过(errorNoData)、或者这个类型没给写权限,
            // 都跳过就行——为此让整批种子数据写不进去才是本末倒置。
            _ = try? await store.deleteObjects(of: type, predicate: ownSamples)
        }
    }

    func selfCheck() async throws {
        for tool in HealthTools.all {
            print("=== \(tool.name) ===")
            print(try await tool.run(7))
        }
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
        ] + vitalSamples(on: sampleDate, offset: offset, metadata: metadata)
    }

    /// 血压、血氧、呼吸频率、体温。
    ///
    /// 真机上这几项多数人是空的,种子数据也故意做成"不是每天都有":血压隔两天一次,
    /// 对得上真人用血压计的频率。
    private func vitalSamples(on date: Date, offset: Int, metadata: [String: Any]) -> [HKSample] {
        var samples: [HKSample] = []

        if offset % 3 == 0 {
            let systolic = Double(112 + (offset * 5) % 17)
            let diastolic = Double(70 + (offset * 3) % 13)
            let unit = HKUnit.millimeterOfMercury()
            // 收缩压和舒张压分开写。HealthKit 里血压虽然是一对关联样本,但 app 根本
            // 申请不到关联类型的写权限(iOS 直接抛 disallowed),所以只能各写各的——
            // 读取那侧本来也是按两个数量类型分别查。
            samples.append(quantitySample(
                type: HKQuantityType(.bloodPressureSystolic),
                value: systolic,
                unit: unit,
                date: date,
                metadata: metadata
            ))
            samples.append(quantitySample(
                type: HKQuantityType(.bloodPressureDiastolic),
                value: diastolic,
                unit: unit,
                date: date,
                metadata: metadata
            ))
        }

        samples.append(quantitySample(
            type: HKQuantityType(.oxygenSaturation),
            value: Double(95 + (offset * 2) % 4) / 100,
            unit: .percent(),
            date: date,
            metadata: metadata
        ))
        samples.append(quantitySample(
            type: HKQuantityType(.respiratoryRate),
            value: Double(13 + (offset * 3) % 5),
            unit: HKUnit.count().unitDivided(by: .minute()),
            date: date,
            metadata: metadata
        ))
        samples.append(quantitySample(
            type: HKQuantityType(.bodyTemperature),
            value: 36.2 + Double((offset * 7) % 9) / 10,
            unit: .degreeCelsius(),
            date: date,
            metadata: metadata
        ))

        return samples
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
