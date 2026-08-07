import Foundation

/// 健康查询工具集:一处声明语义,两个引擎各自适配
/// (FoundationModels 走 Tool 协议,AIKit 走 ToolDefinition/JSON Schema)。
///
/// TODO(M3/M4) 计划的五个工具,全部只返回按天聚合值:
/// - daily_steps(days)        每日步数 + 均值
/// - sleep_summary(days)      每晚时长/入睡起床 + 均值
/// - heart_rate_summary(days) 静息心率、HRV、心率区间
/// - workouts(days)           锻炼列表(类型/时长/消耗)
/// - body_metrics(days)       体重/体脂趋势
enum HealthTools {}
