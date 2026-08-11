import SwiftUI

/// 助手气泡里的正文。段落照旧,表格画成表格。
struct MarkdownTextView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let paragraph):
                    Text(MarkdownInline.attributed(paragraph))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                case .heading(let title):
                    Text(MarkdownInline.attributed(title))
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                case .table(let table):
                    MarkdownTableView(table: table)
                }
            }
        }
    }
}

/// 一张表在手机上的两种画法。
///
/// **横向滚动是错的答案**,哪怕它最好写:一张滚出屏幕的表,第一列(日期)一滑就看不见了,
/// 剩下的数字失去了参照;而"这里还能往右滑"这件事本身就要人先发现。这个 app 的用户里有
/// 相当一部分是把系统字号调大了的——那种设置下,两列的表都未必放得下。
///
/// 所以宽度不够时**换一种排法**,不是换一种滚法:每一行摊成一小段,第一格当小标题,其余
/// 「表头 值」逐行列出。竖着变长在手机上是免费的,横着放不下才是问题。
///
/// 用 `ViewThatFits` 而不是"超过三列就摊开":列数不是判据,**放不放得下**才是——同样三列,
/// 默认字号下宽宽松松,辅助功能的特大字号下一列都塞不进。
struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            stacked
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("表格")
    }

    // MARK: - 放得下:真的画成表

    private var grid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                    Text(MarkdownInline.attributed(header))
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }

            Divider().gridCellUnsizedAxes(.horizontal)

            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownInline.attributed(cell))
                    }
                }
            }
        }
        // 一格里的字不许折行:折了行的表比摊开的那版更难读,而这时候本来就该换成摊开那版。
        // 少了这一句,`ViewThatFits` 会认为挤成三行的表格"放得下"。
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - 放不下:一行摊成一小段

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 3) {
                    // 第一格当这一小段的标题(多半是日期或指标名),它本来就是这一行的身份。
                    if let first = row.first, !first.isEmpty {
                        Text(MarkdownInline.attributed(first))
                            .fontWeight(.semibold)
                    }
                    ForEach(Array(row.enumerated()).dropFirst(), id: \.offset) { column, cell in
                        if !cell.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(MarkdownInline.attributed(header(column)))
                                    .foregroundStyle(.secondary)
                                Text(MarkdownInline.attributed(cell))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if index < table.rows.count - 1 {
                    Divider()
                }
            }
        }
    }

    /// 摊开那版里每个值前面的名字。表头缺了就不写——宁可只显示一个数字,也不写一个
    /// 猜出来的名字。
    private func header(_ column: Int) -> String {
        column < table.headers.count ? table.headers[column] : ""
    }
}
