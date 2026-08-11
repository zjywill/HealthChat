#if DEBUG
import Foundation
import HealthKit

final class DebugSeeder: Sendable {
    static let shared = DebugSeeder()

    private let store = HKHealthStore()
    private let calendar = Calendar.autoupdatingCurrent

    private let writeTypes: Set<HKSampleType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.flightsClimbed),
        // 运动分钟(appleExerciseTime)不在这里:那类 app 申请写权限会直接抛异常,
        // 只有 Apple Watch 能写。读那侧留着,真机上有表就有数据。
        HKQuantityType(.heartRate),
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

        // 同样先问"要不要问",否则每次写种子数据都会闪一下授权面板。
        if try await store.statusForAuthorizationRequest(
            toShare: writeTypes,
            read: writeTypes
        ) == .shouldRequest {
            try await store.requestAuthorization(toShare: writeTypes, read: writeTypes)
        }
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
        // 今天的逐小时数据。面板上那条日内分布画的就是今天,只写到此刻为止。
        samples.append(contentsOf: todaySamples())

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
            // 一个工具报错不该让后面几个都跑不到——自检就是要看清哪个坏了。
            do {
                print(try await tool.run(7, nil).modelText)
            } catch {
                print("失败：\(error)")
            }
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
            // 一步约 0.7 米,跟真实数据里步数和距离的比例对得上。
            quantitySample(
                type: HKQuantityType(.distanceWalkingRunning),
                value: steps * 0.0007,
                unit: .meterUnit(with: .kilo),
                date: sampleDate,
                metadata: metadata
            ),
            quantitySample(
                type: HKQuantityType(.flightsClimbed),
                value: Double(2 + (offset * 3) % 12),
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

        // 半夜醒一小会:每三晚一次,让"醒来次数"和睡眠效率不是恒定值。
        var samples: [HKSample] = [
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

        if offset.isMultiple(of: 3),
           let awakeStart = calendar.date(byAdding: .minute, value: -25, to: coreEnd),
           let awakeEnd = calendar.date(byAdding: .minute, value: 8 + offset % 7, to: awakeStart) {
            samples.append(HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.awake.rawValue,
                start: awakeStart,
                end: awakeEnd,
                metadata: metadata
            ))
        }

        // 夜间心率:睡下去往下走,天亮前回升,半夜醒那段抬一截。
        var cursor = bedtime
        var index = 0
        while cursor < wake {
            let progress = cursor.timeIntervalSince(bedtime) / max(wake.timeIntervalSince(bedtime), 1)
            let dip = 8 * sin(progress * .pi)
            let value = Double(58 + offset % 5) - dip + Double(index % 3)
            samples.append(quantitySample(
                type: HKQuantityType(.heartRate),
                value: value,
                unit: HKUnit.count().unitDivided(by: .minute()),
                date: cursor,
                metadata: metadata
            ))
            guard let next = calendar.date(byAdding: .minute, value: 20, to: cursor) else { break }
            cursor = next
            index += 1
        }

        return samples
    }

    /// 今天到此刻的逐小时步数和心率。
    ///
    /// 其余日子只写一条日总量就够了(工具按天聚合),但面板上的日内分布画的是今天,
    /// 得有真正分散在各个小时的样本。
    private func todaySamples() -> [HKSample] {
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)
        let currentHour = calendar.component(.hour, from: now)
        let metadata = [HKMetadataKeyWasUserEntered: true]
        let stepUnit = HKUnit.count()
        let heartUnit = HKUnit.count().unitDivided(by: .minute())

        var samples: [HKSample] = []
        for hour in 0...currentHour {
            guard let start = calendar.date(byAdding: .hour, value: hour, to: startOfDay),
                  let end = calendar.date(byAdding: .minute, value: 55, to: start),
                  end < now else {
                continue
            }

            // 早晚各一个通勤峰,午后一个小坡;夜里基本不动。
            let shape: Double
            switch hour {
            case 8, 9: shape = 1.0
            case 12, 13: shape = 0.6
            case 18, 19: shape = 0.9
            case 7, 10, 11, 14...17, 20, 21: shape = 0.35
            default: shape = 0.03
            }
            let steps = (900 * shape + Double(hour % 4) * 20).rounded()
            if steps > 0 {
                samples.append(HKQuantitySample(
                    type: HKQuantityType(.stepCount),
                    quantity: HKQuantity(unit: stepUnit, doubleValue: steps),
                    start: start,
                    end: end,
                    metadata: metadata
                ))
            }

            samples.append(quantitySample(
                type: HKQuantityType(.heartRate),
                value: 58 + 26 * shape + Double(hour % 3),
                unit: heartUnit,
                date: start,
                metadata: metadata
            ))
        }

        samples.append(quantitySample(
            type: HKQuantityType(.restingHeartRate),
            value: 59,
            unit: heartUnit,
            date: startOfDay.addingTimeInterval(3600),
            metadata: metadata
        ))
        return samples
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
        let metadata = [HKMetadataKeyWasUserEntered: true]
        let energySample = HKQuantitySample(
            type: HKQuantityType(.activeEnergyBurned),
            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: energy),
            start: start,
            end: end,
            metadata: metadata
        )
        // 距离和心率要挂在 workout 上,不然 workout.statistics 取不到——
        // 单独写进「健康」只会变成一条孤立样本。
        let distanceType = activity == .cycling
            ? HKQuantityType(.distanceCycling)
            : HKQuantityType(.distanceWalkingRunning)
        let speed = activity == .cycling ? 0.35 : 0.16
        let distanceSample = HKQuantitySample(
            type: distanceType,
            quantity: HKQuantity(
                unit: .meterUnit(with: .kilo),
                doubleValue: Double(durationMinutes) * speed
            ),
            start: start,
            end: end,
            metadata: metadata
        )

        var heartSamples: [HKSample] = []
        for minute in stride(from: 0, to: durationMinutes, by: 5) {
            guard let moment = calendar.date(byAdding: .minute, value: minute, to: start) else { continue }
            let progress = Double(minute) / Double(max(durationMinutes, 1))
            heartSamples.append(HKQuantitySample(
                type: HKQuantityType(.heartRate),
                quantity: HKQuantity(
                    unit: HKUnit.count().unitDivided(by: .minute()),
                    doubleValue: 118 + 34 * sin(progress * .pi) + Double(offset % 6)
                ),
                start: moment,
                end: moment,
                metadata: metadata
            ))
        }

        try await builder.beginCollection(at: start)
        try await builder.addSamples([energySample, distanceSample] + heartSamples)
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
