import Foundation
import HealthKit

/// HealthKit 读取层,只读不写。所有查询返回按天聚合值(工具输出要紧凑)。
final class HealthStore: Sendable {
    static let shared = HealthStore()

    private let store = HKHealthStore()

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

    // TODO(M2): 五个聚合查询,对应 HealthTools。
    // func dailySteps(days: Int) async throws -> ...
    // func sleepSummary(days: Int) async throws -> ...
    // func heartRateSummary(days: Int) async throws -> ...
    // func workouts(days: Int) async throws -> ...
    // func bodyMetrics(days: Int) async throws -> ...
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
