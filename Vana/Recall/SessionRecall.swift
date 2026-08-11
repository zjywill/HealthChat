import Foundation

/// 一条过往会话在召回里的样子。
///
/// 只留检索和挑选要用的那点东西,不带消息全文——索引常驻在 `SessionStore` 里,把几十条
/// 会话的全文一起留下,是为了一个每轮最多用两次的功能付整段内存。真要读时再去 `load(id:)`。
struct SessionDigest: Identifiable, Equatable, Sendable {
    let id: UUID
    /// 给模型看的短编号,`S1`、`S2`…
    let handle: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let topicName: String?
    /// 这条会话里查过哪几类数据,已经翻成中文标签。
    let toolLabels: [String]
    let messageCount: Int
    /// 打分用的那段文本,小写。
    let searchText: String

    /// 检索结果里的一行。给的信息要刚好够模型判断"值不值得点开读"——太少它会把每条都读一遍,
    /// 太多就等于没有 `read_session` 这一步了。
    func listing(now: Date, calendar: Calendar) -> String {
        var parts = ["\(handle) · \(SessionRecall.dateLabel(updatedAt, now: now, calendar: calendar))"]
        if let topicName { parts.append(topicName) }
        if !toolLabels.isEmpty { parts.append("查过\(toolLabels.prefix(3).joined(separator: "、"))") }
        parts.append("\(messageCount) 条消息")
        return parts.joined(separator: " · ") + "\n    「\(title)」"
    }
}

/// 过往会话的召回索引。
///
/// 检索纯本地:几十条会话、一次目录扫描,不值得为它引入 embedding。为数数花一次模型调用是
/// 纯亏,这条和 `InterestProfile` 是同一个判断。
struct SessionRecallIndex: Equatable, Sendable {
    static let empty = SessionRecallIndex(digests: [])

    /// 最近更新的在前。编号不跟着这个顺序走,见 `init(sessions:excluding:)`。
    let digests: [SessionDigest]

    var isEmpty: Bool { digests.isEmpty }

    init(digests: [SessionDigest]) {
        self.digests = digests
    }

    /// - Parameters:
    ///   - entries: 全部会话的索引。隐私会话从不落盘,所以天然不在这里——「不留痕迹」的承诺
    ///     不需要在这一层再挡一次,但它成立的前提是没人给隐私会话开后门去存盘。
    ///
    ///     传的是索引不是会话全文:这份索引常驻在 `SessionStore` 里,而检索只用得上用户说过
    ///     的话和几个工具名。跟着把一年的工具输出留在内存里,是为了一个每轮最多用两次的功能
    ///     付整段内存。
    ///   - excluding: 当前这条会话。不排掉的话模型会把正在进行的对话当成"过往"读回来,
    ///     得到的是它刚说过的话。
    init(entries: [SessionIndexEntry], excluding current: UUID? = nil) {
        // 编号按 `createdAt` 升序发。创建时间永不变,所以一条会话的编号只在更早的会话被删掉
        // 时才动;按 `updatedAt` 排的话,随便一次保存就能让上一句说的 S3 指到别处去。
        // 同一个理由见 `MemoryStore.sorted`。
        let numbered = entries
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.createdAt < rhs.createdAt
            }
            .enumerated()
            .map { (handle: "S\($0.offset + 1)", entry: $0.element) }

        // 排除放在发号之后:先把当前会话摘掉再发号,会让它之后创建的每条会话都错位一格。
        digests = numbered
            .filter { $0.entry.id != current }
            .map { SessionDigest($0.entry, handle: $0.handle) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func digest(handle: String) -> SessionDigest? {
        let wanted = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        return digests.first { $0.handle.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// 按相关度找几条。查询词为空就给最近的几条——「上次我们聊到哪了」是个合法的问法。
    ///
    /// 门槛是**相对**的:只留和最相关那条差不太多的(`relevanceFloor`)。健康对话里「睡眠」
    /// 「累」这种词几乎每条会话都沾一点,`score > 0` 等于任何查询都能捞回一把弱匹配,而模型
    /// 分不出哪条才是用户说的那次,只好挨条 `read_session` 读过去——一次试探性检索就这么
    /// 变成了三四轮。宁可返回「没有找到」:那是一个有效答案,模型据此就该去查数据。
    func search(query: String, since: Date? = nil, limit: Int = 6) -> [SessionDigest] {
        let candidates = since.map { cutoff in digests.filter { $0.updatedAt >= cutoff } } ?? digests
        let terms = SessionRecall.terms(in: query)
        guard !terms.isEmpty else { return Array(candidates.prefix(limit)) }

        var scored: [(digest: SessionDigest, score: Int)] = []
        for digest in candidates {
            let score = terms.count { digest.searchText.contains($0) }
            if score > 0 { scored.append((digest, score)) }
        }
        guard let best = scored.map(\.score).max() else { return [] }
        // 整数比较,不引浮点:`score / best >= relevanceFloor` 两边同乘。
        let (numerator, denominator) = Self.relevanceFloor
        scored.removeAll { $0.score * denominator < best * numerator }
        // 同分按更近的在前:同样相关的两次对话,新的那次才是他说的「上次」。
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.digest.updatedAt > rhs.digest.updatedAt : lhs.score > rhs.score
        }
        return scored.prefix(limit).map(\.digest)
    }

    /// 一条会话要拿到最高分的多少才算数。
    ///
    /// 三分之二是「差一个词还行,差一半不行」:「睡眠 加班 熬夜」里命中两个的留下,只命中
    /// 「睡眠」的不留。查询只有一两个词时这个门槛自动失效(最高分就是 1,谁都够得着),那也
    /// 正是该失效的时候——用户就给了这么点信息,再挑就是瞎挑。
    private static let relevanceFloor = (numerator: 2, denominator: 3)
}

private extension SessionDigest {
    init(_ entry: SessionIndexEntry, handle: String) {
        id = entry.id
        self.handle = handle
        title = entry.title
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        topicName = ChatTopics.topic(id: entry.topicId)?.name
        // `toolNames` 已经去过重且保序了。`Set` 直接转数组的话,同一条会话每次建索引给出的
        // 标签顺序都不一样,检索结果看着像在抖。
        toolLabels = entry.toolNames
            .filter { $0 != MemoryTools.rememberToolName && $0 != SessionRecallTools.searchToolName
                && $0 != SessionRecallTools.readToolName }
            .map { HealthTools.label(for: $0) }
        messageCount = entry.messageCount

        // 打分只看**用户说过的话** + 话题 + 工具标签,不看助手的回复。
        //
        // 助手那几段长得多,而且什么都提一句(「睡眠、心率、活动量都还行」),放进来的话每条
        // 会话都能匹配上任何查询,检索就退化成了按时间倒序。用户说的话才是他当时真正在问的事。
        searchText = ([entry.userText, topicName ?? ""] + toolLabels)
            .joined(separator: "\n")
            .lowercased()
    }
}

enum SessionRecall {
    /// 打分用的词。
    ///
    /// 中文没有空白可切,按 2-gram 拆:「睡眠不好」拆成 睡眠/眠不/不好,查询和正文都这么拆,
    /// 重合几个就是几分。这套东西粗糙但够用——候选只有几十条,要的是把明显相关的那两三条排到
    /// 前面,不是排出一个准确的相关度序。
    static func terms(in text: String) -> Set<String> {
        var result: Set<String> = []
        for chunk in text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
            let characters = Array(chunk)
            guard characters.count > 1 else { continue }
            // 全英文的词整个留着:把 "hrv" 拆成 hr/rv 会匹配上一堆无关的东西。
            if chunk.allSatisfy(\.isASCII) {
                result.insert(String(chunk))
                continue
            }
            for index in 0..<(characters.count - 1) {
                result.insert(String(characters[index...(index + 1)]))
            }
        }
        return result
    }

    /// 日期怎么说。
    ///
    /// 一律说得出具体是哪天:「上个月」听着自然,但模型拿它没法判断一条三个月前的结论还算不算数,
    /// 而这正是召回最容易出错的地方。今年的省掉年份,别的都写全。
    static func dateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = calendar
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }
}
