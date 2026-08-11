import Foundation
import AgentRuntime

/// `ask_user` 摆在回复下面的那张卡:一个问题,几个点得动的选项。
///
/// **结构必须来自工具,不能从正文里认。** 让模型在回答里写 `A. 入睡困难 / B. 半夜醒` 再由
/// app 去解析,和让它写 `[[动作:xxx]]` 是同一类错(见 `ExerciseSelection`):它迟早会写成
/// 「1）」「- 」「或者」,而解析失败的表现是正文里挂着一串没人点得动的字母。JSON Schema
/// 那一层是免费的,选项的条数、长度、有没有重复,在进屏幕之前就定了。
struct AskUserQuestion: Codable, Equatable, Sendable {
    struct Option: Codable, Equatable, Sendable, Identifiable {
        let label: String
        /// 一句话说清这条是什么意思。模型不给就没有,卡上只显示标签。
        var detail: String = ""

        /// 标签本身就是身份:同一张卡里两条一模一样的选项本来就该被判成一条。
        var id: String { label }
    }

    let question: String
    let options: [Option]
    /// 多选。单选点一下就发出去了,多选要他点完再按一下。
    var allowsMultiple: Bool = false

    // 上限不是排版洁癖:一张卡摆七个选项,人读完七条的成本已经超过自己打一句话了,
    // 而那正是这张卡要省掉的事。
    static let minOptions = 2
    static let maxOptions = 5
    static let maxQuestionCharacters = 40
    static let maxLabelCharacters = 16
    static let maxDetailCharacters = 30

    /// 他按「跳过」时替他说的那句话。
    ///
    /// 是一条**普通的用户消息**,不是占位文案——`ConversationHistoryPlanner` 会把
    /// `textIsPlaceholder` 的用户消息整条丢掉,而「他不想说」恰恰是模型必须知道的一件事
    /// (不知道就会把同一个问题再问一遍,那正是这颗按钮要防的)。
    static let declineText = "跳过这个问题"

    /// 两种 metadata 并存在 `AgentToolOutput.metadata` 同一个字段上是安全的:必填键不一样,
    /// 互相解不出来(`HealthReport` 要 `title`,`ExerciseSelection` 要 `moveIDs`,这里要
    /// `question` + `options`)。加第四种时先确认这一条还成立。
    static func encodeForToolMetadata(_ question: AskUserQuestion) -> RuntimeJSONValue? {
        guard let data = try? JSONEncoder().encode(question) else { return nil }
        return try? JSONDecoder().decode(RuntimeJSONValue.self, from: data)
    }

    static func decode(fromToolMetadata metadata: RuntimeJSONValue?) -> AskUserQuestion? {
        guard let metadata else { return nil }
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return try? JSONDecoder().decode(AskUserQuestion.self, from: data)
    }
}

/// 他在那张卡上最后按了什么。
///
/// 存在 `ToolCallRecord` 上跟着会话落盘:重开这条会话时那张卡得是**答过的样子**。不存的话
/// 三天前答完的问题会以一张还能点的卡重新出现,而点下去发出的是一句接不上任何东西的话。
///
/// 「还没答」是 `nil`,不是空的 `AskUserAnswer`——他可以只写一句自定义、一个选项都不勾,
/// 那也是答过了。
struct AskUserAnswer: Codable, Equatable, Sendable {
    var choices: [String] = []
    /// 他自己写的那句。
    var custom: String = ""
    /// 他按了「跳过」。
    var declined: Bool = false

    /// 发出去的那条用户消息。
    ///
    /// **就是他选的那几个词,不加壳**(不写成「我选择：入睡困难」)。问题就在这条上面一行,
    /// 「入睡困难」读起来本来就是一句回答;而加了壳之后,这句话还要进会话标题、召回索引和
    /// 记忆抽取——那几处要的都是他自己说的话。
    var messageText: String {
        if declined { return AskUserQuestion.declineText }
        var parts = choices
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts.joined(separator: "、")
    }

    /// 一个选项没勾、一个字没写。发出去只会是一条空消息。
    var isEmpty: Bool { messageText.isEmpty }

    /// 这一下会发出去几样东西。
    ///
    /// **自己写的那一句也算一样。** 按钮上写着「发送 2 项」而实际发出去的是三样,是这张卡
    /// 唯一会说谎的地方:他勾了两条又补了一句,按钮却当那句不存在——而这两个数只要有一次
    /// 对不上,他下次就得先发一遍看看到底发了什么。所以数和 `messageText` 是同一个来源。
    var itemCount: Int {
        guard !declined else { return 0 }
        // 不去数 `messageText` 里的顿号:他自己写的那句里就可能有顿号,那样数出来的是
        // 他句子里的分句,不是他做的选择。
        return choices.count + (custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
    }
}
