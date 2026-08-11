import Foundation

/// 一次健康查询的结果:既是给模型看的文本,也是面板要画的表格。
///
/// 两边同源。分别写两遍迟早会对不上——用户在面板里看到的数字必须就是模型看到的那批,
/// 否则"你说的和数据不一样"这种问题永远查不清。
struct HealthReport: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable {
        let label: String
        /// 与 `columns` 去掉首列后一一对应;没有的值用 `HealthReport.missing`。
        let values: [String]

        init(_ label: String, _ values: [String]) {
            self.label = label
            self.values = values
        }
    }

    /// 日内分布。只画给人看,不进 `modelText`——24 个点对端上模型 4k 的窗口太贵,
    /// 而且模型要的是结论,不是曲线。
    struct Series: Codable, Equatable, Sendable {
        struct Point: Codable, Equatable, Sendable {
            let label: String
            /// nil 表示这一格没有记录(不是 0)。
            let value: Double?
        }

        let title: String
        let unit: String
        let points: [Point]
    }

    /// 表头首列是行标签(日期/区间/项目),`Row.values` 从第二列开始。单位写在列名里,
    /// 格子只放数字——一列上下对齐才看得出趋势,文本也更短。
    let title: String
    var columns: [String] = []
    var rows: [Row] = []
    /// 均值、区间、基线对比这类结论。
    var summary: [String] = []
    /// 没有数据的原因、"相关不是因果"这类提醒。
    var notes: [String] = []
    var series: [Series] = []

    static let missing = "—"

    /// 没查到数据时的结果。说清楚为什么没有,不然模型会当成"读取失败"。
    static func empty(title: String, note: String) -> HealthReport {
        HealthReport(title: title, notes: [note])
    }

    var isEmpty: Bool { rows.isEmpty }

    var modelText: String {
        var lines = [title]
        if !rows.isEmpty {
            if !columns.isEmpty {
                lines.append(columns.joined(separator: " | "))
            }
            lines.append(contentsOf: rows.map { ([$0.label] + $0.values).joined(separator: " | ") })
        }
        lines.append(contentsOf: summary)
        lines.append(contentsOf: notes)
        return lines.joined(separator: "\n")
    }
}
