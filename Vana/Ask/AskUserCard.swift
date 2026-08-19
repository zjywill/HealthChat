import SwiftUI

/// `ask_user` 那张卡。排在正文下面,和动作卡同一个位置。
///
/// **这张卡的全部意义是省掉一次"想怎么描述"。** 「你这个头疼是哪一种」用打字回答,他得先把
/// 感觉翻译成一句话,而多数人此刻翻译不出来,于是回一句「就是疼」,模型只好再问一遍。给几个
/// 选项,他一眼就知道自己是哪种。所以选项的措辞要用**他会说的说法**,不是医学分类。
///
/// 三种形态,不要合并:
///
/// - **能答**(这条回复是最后一条、也没有新的回复在跑)。点得动。
/// - **答过了**。勾上他选的那几条,按钮全部收掉。他答过的东西已经作为一条消息发出去了,
///   再点一次只会把同一句话再发一遍。
/// - **已经过去了**(他没点,直接打了别的字)。整张卡淡下去,点不动。留着它是因为上下文里
///   还有这个问题——模型下一句话可能正接着它;抹掉的话屏幕上就只剩一个没头没尾的回答。
struct AskUserCard: View {
    let question: AskUserQuestion
    /// `nil` 是还没答。空的 `AskUserAnswer` 不能拿来当"没答":他可以只写一句自定义、
    /// 一个选项都不勾,那也是答过了。
    let answer: AskUserAnswer?
    /// 现在还答得了吗。
    let isLive: Bool
    let onAnswer: (AskUserAnswer) -> Void

    @State private var selected: Set<String> = []
    @State private var custom = ""
    @FocusState private var isCustomFocused: Bool

    private var isAnswered: Bool { answer != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.question)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // `alignment: .leading` 不能省:默认的 .center 会把「都不是，我自己说」那一行
            // 按它自己的宽度居中,和上面几行的图标对不齐——一列图标歪一格,整张卡就散了。
            VStack(alignment: .leading, spacing: 0) {
                ForEach(question.options) { option in
                    if option.id != question.options.first?.id { separator }
                    optionRow(option)
                }
                // 「其他」永远在,不做成工具参数。**多给一个参数就多一处模型会判错的地方**,
                // 而判错的那次表现是:一个人的情况恰好不在四个选项里,他却只能在四个错的
                // 答案里挑一个,或者放弃这张卡去输入框重打一遍。留着这一行的代价只是一行。
                if !isAnswered {
                    separator
                    customRow
                }
            }

            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // 一层底色,不是"卡里再套一个浅色块"。两层灰叠在一起的话,分组读不出来,整张卡
        // 反而糊成一片——选项之间靠分隔线分开就够了(同 `ToolResultPanel` 里那几块)。
        .background(
            Color(.secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 18, style: .continuous)
        )
        // 已经过去的那张淡下去。答过的**不淡**:那是一条他自己做过的选择,不是失效的东西。
        .opacity(isLive || isAnswered ? 1 : 0.55)
        .animation(.smooth(duration: 0.2), value: needsConfirmation)
        .animation(.smooth(duration: 0.2), value: isAnswered)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(height: 1)
            .padding(.leading, 32)
    }

    // MARK: - 选项

    @ViewBuilder
    private func optionRow(_ option: AskUserQuestion.Option) -> some View {
        let chosen = isAnswered
            ? (answer?.choices.contains(option.label) ?? false)
            : selected.contains(option.label)

        Button {
            tap(option)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: mark(chosen: chosen))
                    .font(.body)
                    .foregroundStyle(chosen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout)
                        .foregroundStyle(.primary)
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isLive || isAnswered)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
        .accessibilityLabel(option.detail.isEmpty ? option.label : "\(option.label)，\(option.detail)")
    }

    /// 单选用圆点、多选用方框,和 iOS 别处一样——这一眼决定了他会不会去找"发送"那颗按钮。
    private func mark(chosen: Bool) -> String {
        if question.allowsMultiple {
            return chosen ? "checkmark.square.fill" : "square"
        }
        return chosen ? "largecircle.fill.circle" : "circle"
    }

    /// **单选点一下就发出去**,不做"选中再按确认"。
    ///
    /// 那颗确认键在单选时是纯粹的一次多余点击:选项本身已经是一个完整的答案了,而这张卡
    /// 存在的理由正是把一次回答压到一下。点错了他接着打字就是——输入框一直在下面。
    /// 多选和写了自定义的那两种情况没法这样:什么时候算选完了只有他知道。
    private func tap(_ option: AskUserQuestion.Option) {
        guard isLive, !isAnswered else { return }
        if question.allowsMultiple {
            if !selected.insert(option.label).inserted {
                selected.remove(option.label)
            }
            return
        }
        selected = [option.label]
        // 他已经在输入框里写了半句:这一下不能替他发出去,那半句会被一起带走或者丢掉,
        // 而两种都不是他按这一下的意思。这时候由「发送」那颗按钮说了算。
        guard !hasCustomText else { return }
        submit()
    }

    // MARK: - 自己写一句

    /// **输入框一直在,点它只是聚焦**——不做「先是一行字、点了才变成输入框」那一套。
    ///
    /// 那一套踩过两次:`Text` 和 `TextField` 的横向内缩差着一个光标位、固有高度也差几个点,
    /// 于是点下去那一瞬字会横着挪一下、行会长高一点。而这恰好发生在他正要往里打字的时候,
    /// 看起来就是输入框自己在动。**一个控件从头到尾**,就没有两种几何可以对不上了。
    ///
    /// 代价只是那行占位文案一直摆在那儿——而它本来就该一直摆在那儿:这张卡的承诺之一就是
    /// 「你的情况不在这几条里也没关系」,藏起来说等于没说。
    private var customRow: some View {
        // 这一行**不能**跟着选项行用 `.firstTextBaseline`:`TextField` 报出来的首行基线
        // 比它画出来的那行字低一截,按基线对的话图标会浮到文字上方十几点去(试过,比不对齐
        // 还明显)。居中对,并且把图标框成正方形——只给宽度的话,框的高度是字形的自然高度
        // (`square.and.pencil` 上方还留着 ascender 的空),居中的是那个框,不是那支笔。
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.body)
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            TextField("都不是，我自己说", text: $custom, axis: .vertical)
                .font(.callout)
                .lineLimit(1...4)
                .focused($isCustomFocused)
                .submitLabel(.done)
                .disabled(!isLive)
        }
        // 比上面那几行高一点(48 不是 44):带说明的选项本来就是两行高,这一行按 44 收
        // 就显得被挤在最底下。
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(.rect)
        // 点这一行的任何地方都算点进输入框,不只是那几个字上。
        .onTapGesture { isCustomFocused = isLive }
    }

    // MARK: - 底下那一行

    @ViewBuilder
    private var footer: some View {
        if let answer {
            // 答过之后这一行说清楚发生了什么。跳过那次尤其要说——卡上一个勾都没有,
            // 不写这一句的话它和"他没理这张卡"长得一模一样。
            Label(
                answer.declined ? "已跳过" : "已回答",
                systemImage: answer.declined ? "arrow.turn.down.right" : "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if isLive {
            HStack(spacing: 12) {
                // 「跳过」摆在明处,不收进菜单里。它是这张卡的一条承诺:问了不等于必须答。
                // 藏起来的话,不想说的人只能装作没看见——而模型永远不知道他不想说,下一轮
                // 换个说法再问一遍。
                Button("跳过") {
                    submit(declined: true)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(.rect)

                Spacer(minLength: 0)

                if needsConfirmation {
                    Button {
                        submit()
                    } label: {
                        Label(confirmTitle, systemImage: "arrow.up")
                            .font(.footnote.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(draft.isEmpty)
                }
            }
        }
    }

    private var hasCustomText: Bool {
        !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 确认键什么时候出现:多选,或者他自己写了点什么。单选点一下就走,没有它。
    private var needsConfirmation: Bool { question.allowsMultiple || hasCustomText }

    /// **数的是真的会发出去的那几样,自己写的那句也算一样。**
    ///
    /// 按钮上写「发送 2 项」而实际发出去三样,是这张卡唯一会说谎的地方——他勾了两条又补了
    /// 一句,按钮却当那句不存在。所以这个数和 `messageText` 同源(`AskUserAnswer.itemCount`)。
    private var confirmTitle: String {
        let count = draft.itemCount
        guard question.allowsMultiple, count > 1 else { return String(localized: "发送") }
        return String(localized: "发送 \(count) 项")
    }

    private var draft: AskUserAnswer {
        AskUserAnswer(
            // 按卡上的顺序发,不按他点的顺序:同一组勾选每次发出去的都该是同一句话。
            choices: question.options.map(\.label).filter(selected.contains),
            custom: custom
        )
    }

    private func submit(declined: Bool = false) {
        guard isLive, !isAnswered else { return }
        let answer = declined ? AskUserAnswer(declined: true) : draft
        guard !answer.isEmpty else { return }
        isCustomFocused = false
        onAnswer(answer)
    }
}

#Preview {
    let single = AskUserQuestion(
        question: "昨晚主要是哪一种睡不好？",
        options: [
            .init(label: "入睡困难", detail: "躺下半小时以上睡不着"),
            .init(label: "半夜醒", detail: "中间醒来一次以上"),
            .init(label: "醒得太早")
        ]
    )
    let multiple = AskUserQuestion(
        question: "最近有哪些不舒服？可以多选",
        options: [.init(label: "头疼"), .init(label: "乏力"), .init(label: "心慌")],
        allowsMultiple: true
    )

    return ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            AskUserCard(question: single, answer: nil, isLive: true) { _ in }
            AskUserCard(question: multiple, answer: nil, isLive: true) { _ in }
            AskUserCard(
                question: single,
                answer: AskUserAnswer(choices: ["半夜醒"]),
                isLive: false
            ) { _ in }
            AskUserCard(
                question: single,
                answer: AskUserAnswer(declined: true),
                isLive: false
            ) { _ in }
            // 他没点，直接打了别的字：整张卡淡下去，点不动。
            AskUserCard(question: single, answer: nil, isLive: false) { _ in }
        }
        .padding(16)
    }
    .background(Color(.systemGroupedBackground))
}
