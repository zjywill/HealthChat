import Foundation
import HealthKit

/// HealthKit 读取层,只读不写。所有查询返回按天聚合值(工具输出要紧凑)。
final class HealthStore: Sendable {
    static let shared = HealthStore()

    private let store = HKHealthStore()

    // TODO(M1): 声明读取类型集合(步数/睡眠/心率/HRV/锻炼/体重/体脂/活动能量),
    // 请求授权 + 拒绝态引导。
    func requestAuthorization() async throws {
    }

    // TODO(M2): 五个聚合查询,对应 HealthTools。
    // func dailySteps(days: Int) async throws -> ...
    // func sleepSummary(days: Int) async throws -> ...
    // func heartRateSummary(days: Int) async throws -> ...
    // func workouts(days: Int) async throws -> ...
    // func bodyMetrics(days: Int) async throws -> ...
}
