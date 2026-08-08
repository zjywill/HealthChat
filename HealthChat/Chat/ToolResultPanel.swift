import SwiftUI

/// 气泡上方那一行:一次健康查询的入口。
///
/// 原来是就地展开一段等宽文本,聊天流里只有一列的宽度,睡眠那种七八列的数据只能糊成
/// 一坨。改成点开面板:数据留在下面弹出的那一层,聊天流保持干净。
struct ToolCallChip: View {
    let call: ToolCallRecord

    @State private var isPresented = false

    var body: some View {
        Button {
            guard call.output != nil else { return }
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: call.isError ? "exclamationmark.triangle" : "heart.text.square")
                Text(note)
                if call.output == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    if let count = call.report?.rows.count, count > 0 {
                        Text("\(count) 行")
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
            }
            .font(.caption)
            .foregroundStyle(call.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(.fill.quaternary, in: Capsule())
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(call.output == nil)
        .accessibilityLabel(note)
        .accessibilityHint(call.output == nil ? "正在查询" : "打开查询到的数据")
        .sheet(isPresented: $isPresented) {
            ToolResultPanel(call: call)
        }
    }

    private var note: String {
        HealthTools.note(
            for: call.name,
            days: HealthTools.days(fromInput: call.input),
            activity: HealthTools.activity(fromInput: call.input)
        )
    }
}

/// 从底部弹出的数据面板:工具这次到底查到了什么。
///
/// 模型在回复里只说结论,数字摆在这儿——想核对的人翻得到,不想看的人不会被一屏表格淹掉。
struct ToolResultPanel: View {
    let call: ToolCallRecord

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let report = call.report {
                        header(report)
                        if !report.summary.isEmpty {
                            summary(report.summary)
                        }
                        if !report.rows.isEmpty {
                            table(report)
                        }
                        ForEach(Array(report.series.enumerated()), id: \.offset) { _, series in
                            HourlyChart(series: series)
                        }
                        if !report.notes.isEmpty {
                            notes(report.notes)
                        }
                        rawText(report.modelText)
                    } else {
                        // 查询失败,或者是旧版本存下来的会话——那时候只留了文本。
                        Text(call.output ?? "正在查询…")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(HealthTools.label(
                for: call.name,
                activity: HealthTools.activity(fromInput: call.input)
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func header(_ report: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text("来自「健康」App，只读取，不修改")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private static let headerHeight: CGFloat = 26
    private static let rowHeight: CGFloat = 34

    /// 数值横向滚动,日期那一列钉住不动。
    ///
    /// 睡眠有十列,再怎么排版也塞不进一个手机宽度;但如果日期跟着滚出去,右边那堆数字
    /// 就不知道是哪天的了。
    private func table(_ report: HealthReport) -> some View {
        let valueColumns = Array(report.columns.dropFirst())

        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(report.columns.first ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: Self.headerHeight, alignment: .leading)

                ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in
                    separator
                    Text(row.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .frame(height: Self.rowHeight, alignment: .leading)
                }
            }
            // 分隔线是横向贪心的,不钉住宽度的话整列会撑到半个屏幕。
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 14)
            .padding(.trailing, 12)

            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(valueColumns.enumerated()), id: \.offset) { _, column in
                            Text(column)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(height: Self.headerHeight)
                        }
                    }

                    ForEach(Array(report.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            separator.gridCellColumns(max(valueColumns.count, 1))
                        }
                        GridRow {
                            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                                Text(value)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(value == HealthReport.missing ? .tertiary : .primary)
                                    .lineLimit(1)
                                    .frame(height: Self.rowHeight)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.trailing, 14)
            }
        }
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 左右两半各画各的分隔线,高度写死才能对齐——用 Divider 会因为两边容器不同而错位。
    private var separator: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1)
    }

    private func notes(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Label(line, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 模型看到的原文。面板里的表格是它排版出来的,想核对"模型到底读到了什么"就看这段。
    private func rawText(_ text: String) -> some View {
        DisclosureGroup("模型收到的原文") {
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
        .font(.subheadline)
        .tint(.secondary)
    }
}

/// 日内分布。一天 24 根柱子,没测到的那格是空的而不是 0。
private struct HourlyChart: View {
    let series: HealthReport.Series

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let peak {
                    Text("峰值 \(format(peak)) \(series.unit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(point.value == nil ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(Color.accentColor))
                            .frame(height: height(of: point.value))
                            .frame(maxHeight: .infinity, alignment: .bottom)

                        // 24 个小时标签挤不下,每三格标一个。
                        Text(showsLabel(point.label) ? point.label : " ")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 76)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var peak: Double? {
        series.points.compactMap(\.value).max()
    }

    /// 心率那种基线不在 0 的曲线,从 0 起画会全是一样高的柱子;从最低值下探一点起画,
    /// 差异才看得出来。
    private var floor: Double {
        let values = series.points.compactMap(\.value).filter { $0 > 0 }
        guard let minimum = values.min(), let maximum = values.max(), maximum > 0 else { return 0 }
        return minimum / maximum > 0.5 ? minimum * 0.9 : 0
    }

    private func height(of value: Double?) -> CGFloat {
        guard let value, let peak, peak > floor else { return 3 }
        let ratio = (value - floor) / (peak - floor)
        return max(3, CGFloat(ratio) * 58)
    }

    private func showsLabel(_ label: String) -> Bool {
        (Int(label) ?? 0).isMultiple(of: 3)
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private var accessibilityText: String {
        guard let peak else { return series.title }
        return "\(series.title)，峰值 \(format(peak)) \(series.unit)"
    }
}
