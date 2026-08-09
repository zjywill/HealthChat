import Foundation

/// 把一条过往会话摊成给模型读的一段文本。
///
/// **用原文,不重新总结。** 总结要花一次模型调用,而这一步跑在用户已经在等回复的时候——
/// 让他为「想起上次说过什么」多等一个往返,比想不起来更糟。装不下就按位置裁,不按语义裁。
enum SessionRecallTranscript {
    /// 整段的上限。压在 `ContextPolicy.maxToolOutputCharacters`(6000)以下留出余量:
    /// 召回是为了回答**这一句**,它不该把这一轮的预算吃掉一半。
    static let maxCharacters = 2_500
    static let maxUserCharacters = 200
    static let maxAssistantCharacters = 320

    private static let headerPrefix = "这是 "
    private static let headerSuffix = " 的一次对话"

    /// 从读回来的那段里取出日期,给气泡上的胶囊用。
    ///
    /// 从**输出**里取而不是从入参:入参只有一个 `{"id":"S6"}`,而日期已经在输出的第一行——
    /// 它本来就是标给模型看的,顺手也给了用户。两边同一个来源,不会出现胶囊说 8 月 8 日、
    /// 点开是 8 月 6 日。
    static func dateLabel(inOutput output: String?) -> String? {
        guard let first = output?.split(separator: "\n", maxSplits: 1).first.map(String.init),
              first.hasPrefix(headerPrefix),
              let end = first.range(of: headerSuffix)
        else { return nil }
        let label = String(first[first.index(first.startIndex, offsetBy: headerPrefix.count)..<end.lowerBound])
        return label.isEmpty ? nil : label
    }

    static func text(
        for session: ChatSession,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var header = headerPrefix
            + SessionRecall.dateLabel(session.createdAt, now: now, calendar: calendar)
            + headerSuffix
        if let topic = session.topic?.name {
            header += "（话题：\(topic)）"
        }
        header += "："

        let entries = session.messages.compactMap(entry(for:))
        guard !entries.isEmpty else {
            return header + "\n（这次对话没留下内容）"
        }

        return ([header] + fitted(entries) + [footer]).joined(separator: "\n")
    }

    /// 末尾这句是整套召回最要紧的防线,和记忆块末尾那句同源。
    ///
    /// 旧会话里全是当时查出来的具体数字,而它们**全部**已经过期——记忆里顶多有一两句易腐的
    /// 说法,这里是成篇的。没有这句,模型会拿三个月前的睡眠时长当本周的讲。
    static let footer = "（以上是当时说过的话，日期见开头。里面的具体数值都可能已经过时，"
        + "要用就现在重新查一遍工具，一律以本次返回的为准。）"

    private struct Entry {
        let line: String
        /// 这条消息结尾处折叠掉的那一整段的可见摘要。
        ///
        /// 那是当时真的花钱叫模型写的,已经存在会话文件里。裁掉中段时拿它顶上,等于白拿一段
        /// 比「省略了 12 条」有用得多的东西。
        let foldedSummary: String?
    }

    private static func entry(for message: ChatMessage) -> Entry? {
        // app 写给用户的占位("已停止回复"/"无法回复：…")不是模型说过的话。回放时 runtime
        // 靠 `textIsPlaceholder` 判断,这里同理——把它读回来只会让模型去解释一句它没说过的话。
        let text = message.textIsPlaceholder
            ? ""
            : message.text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch message.role {
        case .user:
            guard !text.isEmpty else { return nil }
            return Entry(line: "他：\(truncated(text, to: maxUserCharacters))", foldedSummary: nil)
        case .assistant:
            var line = text.isEmpty ? "" : "Vana：\(truncated(text, to: maxAssistantCharacters))"
            let tools = toolTrace(message)
            if !tools.isEmpty {
                line = line.isEmpty ? "Vana：\(tools)" : "\(line)\n    \(tools)"
            }
            guard !line.isEmpty else { return nil }
            return Entry(line: line, foldedSummary: message.foldedSpan?.visibleSummary)
        }
    }

    /// 那一轮查过什么,只留名字不留数字。
    ///
    /// 留数字是拿过期数据去污染这一轮:模型看到「静息心率 54」就会顺口讲出来,而那是三个月前
    /// 的 54。查过什么本身是有用的——它说明当时的结论建立在哪些数据上。
    private static func toolTrace(_ message: ChatMessage) -> String {
        var seen = Set<String>()
        let labels = message.toolCalls
            .filter { !$0.isError && $0.name != MemoryTools.rememberToolName }
            .compactMap { seen.insert($0.name).inserted ? HealthTools.label(for: $0.name) : nil }
        return labels.isEmpty ? "" : "（当时查了：\(labels.joined(separator: "、"))）"
    }

    /// 装不下就保头保尾。
    ///
    /// 开头那两句是他当时到底在问什么,结尾那几句是聊出来的结论——被丢掉的中间那段多半是
    /// 一步步查数据的过程,而过程恰恰是最该现查一遍、最不值得读回来的东西。
    private static func fitted(_ entries: [Entry]) -> [String] {
        let lines = entries.map(\.line)
        guard lines.reduce(0, { $0 + $1.count }) > maxCharacters else { return lines }

        let head = Array(lines.prefix(2))
        var used = head.reduce(0) { $0 + $1.count }
        var tail: [String] = []
        for line in lines.dropFirst(head.count).reversed() {
            guard used + line.count <= maxCharacters else { break }
            tail.insert(line, at: 0)
            used += line.count
        }

        let dropped = lines.count - head.count - tail.count
        guard dropped > 0 else { return head + tail }

        // 被丢掉的那一段里如果有当时压出来的整段摘要,用最后一份——它覆盖的范围最大。
        let summary = entries
            .dropFirst(head.count)
            .dropLast(tail.count)
            .compactMap(\.foldedSummary)
            .last { !$0.isEmpty }
        let notice = summary.map { "（中间 \(dropped) 条当时已被压成摘要：\(truncated($0, to: maxAssistantCharacters))）" }
            ?? "（中间省略了 \(dropped) 条）"
        return head + [notice] + tail
    }

    private static func truncated(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : text.prefix(limit) + "…"
    }
}
