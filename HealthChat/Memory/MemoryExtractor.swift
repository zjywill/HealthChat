import Foundation
import AIKit

/// 对现有记忆的一次修改。
///
/// 抽取器输出的是操作,不是新的一份记忆全文。只会 append 的话,三个月后会有四十条
/// 「关心睡眠」;每次全量重写又会像「摘要的摘要」一样,把最早那几条磨成一句客套。
/// 这和 `SummarizationPlan.previousSummary` 是同一个道理。
enum MemoryOperation: Equatable, Sendable {
    case add(kind: MemoryKind, text: String, expiresInDays: Int?)
    case update(id: UUID, text: String)
    case delete(id: UUID)
}

/// 从一条聊完的会话里抽记忆。
///
/// 和 `QuestionSuggester` 一样是一次性的模型调用,不走 `AgentLoop`——它不需要工具,也不
/// 需要上下文预算那一整套。失败就当没发生:记忆学不到东西是小事,让保存会话跟着失败是大事。
struct MemoryExtractor: Sendable {
    let providerId: String
    let model: String
    /// 抽取时的现有记忆。模型要看得见它,才知道该 update 哪一条、哪些不用再记一遍。
    let snapshot: MemorySnapshot

    /// 一条会话喂给模型的文本上限。真要有人聊了两百轮,前面那些多半也已经被摘要过了。
    private static let maxTranscriptCharacters = 6_000
    private static let maxMessageCharacters = 400
    /// 一条记忆写成一段话就说明模型跑偏了。截断只会截出半句莫名其妙的话,不如整条丢掉。
    private static let maxItemCharacters = 120

    /// 不是 private:「用药不归抽取器管」这条边界有测试盯着。两条写入路径落到同一件事上,
    /// 就是两份会各自被改的记录,而对不上的那次可能是禁忌那一条。
    static let instructions = """
    你在为一个健康分析 app 维护「关于这位用户」的长期记忆。这份记忆会放进之后每一次对话的系统提示里，
    所以它必须是长期成立的，而且要少而准。

    只记这四类，查得到的一律不记：
    - profile 长期情况：作息、工作安排、伤病或身体限制、正在进行的目标和训练计划。
    - preference 表达偏好：他希望助手怎么说话，他自己看重哪个指标。
    - interpretation 已有解释：对他而言某个指标的正常范围，或者某段异常已经查明的原因。
    - followUp 待跟进：说好过一阵子再看的事，必须给出 days（几天后失效）。

    绝对不要记：
    - 任何具体的健康数值和某一天的数据（步数、睡眠时长、心率、体重……）。这些每次都会重新查，
      记下来第二天就是错的。
    - 他在吃什么药或补剂、对什么过敏、试过什么没用。这些有专门的地方存（用户能在那儿直接编辑），
      记进这里就是同一件事两份，改了一份另一份还是旧的。
    - 只在这次对话里成立的话题，或者一次性的提问。
    - 诊断结论。可以记「他说自己有房颤」，不能记「他有房颤，需要重点关注」。

    已有记忆每条前面有一个编号（M1、M2…）。你输出的是对这份记忆的**修改**，不是重写：
    - 已经记过的事不要再 add。有更准确的说法就 update 那一条。
    - 事实变了或者已经不成立，delete。
    - 这次对话没有值得记的，就输出空数组。宁可什么都不记，也不要记一堆用不上的。

    只输出 JSON，不要任何解释：
    {"operations":[
      {"op":"add","kind":"profile","text":"…"},
      {"op":"add","kind":"followUp","text":"…","days":14},
      {"op":"update","id":"M2","text":"…"},
      {"op":"delete","id":"M5"}
    ]}

    每条 text 用中文第三人称写，一句话，不超过 40 个字。
    """

    func operations(from session: ChatSession) async throws -> [MemoryOperation] {
        guard let storedKey = try KeychainStore.get(account: KeychainStore.apiKeyAccount) else {
            throw AgentError.needsAPIKey
        }
        let key = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.needsAPIKey }

        let transcript = Self.transcript(of: session)
        guard !transcript.isEmpty else { return [] }

        let client = try AIClient(providerId: providerId, configuration: .init(apiKey: key))
        let response = try await client.generate(CallOptions(
            model: model,
            prompt: [
                .system(Self.instructions),
                .user("已有记忆：\n\(snapshot.handleListing)\n\n这次对话：\n\(transcript)")
            ],
            maxOutputTokens: 800,
            // 记事实不是写文案,别让它发挥。
            temperature: 0.2,
            // 从对话里挑出该记的几句是抽取,不是推理。这一轮用户看不见,省下的是他的钱和
            // 电量——而留空是接受模型的默认,好几家的默认是思考。
            thinking: .off
        ))

        return Self.parse(response.text, snapshot: snapshot)
    }

    /// 喂给抽取器的对话文本:**只有说过的话,没有工具输出**。
    ///
    /// 这是「记忆里不存数字」那条规矩的结构性保证。光靠提示词里写「不要记数值」,模型总有
    /// 一次会记;工具结果压根不给它看,它就无从记起。代价是查出来的结论也看不到——但那些
    /// 结论本来每次都该重查一遍。
    static func transcript(of session: ChatSession) -> String {
        var lines: [String] = []
        for message in session.messages {
            // app 写的占位("已停止回复")不是任何人说的话。
            guard !message.textIsPlaceholder else { continue }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let clipped = text.count <= maxMessageCharacters
                ? text
                : "\(text.prefix(maxMessageCharacters))…"
            lines.append("\(message.role == .user ? "用户" : "助手")：\(clipped)")
        }

        // 超长就从头砍。要记的事多半在后半段——那是他刚说完的话。
        var joined = lines.joined(separator: "\n")
        while joined.count > maxTranscriptCharacters, !lines.isEmpty {
            lines.removeFirst()
            joined = lines.joined(separator: "\n")
        }
        return joined
    }

    /// 解析模型输出。任何一条看不懂就丢那一条,整批不作废——三条里有两条能用,
    /// 比因为第三条写歪了什么都不记要好。
    static func parse(_ text: String, snapshot: MemorySnapshot) -> [MemoryOperation] {
        guard let data = jsonPayload(in: text)?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RawOperations.self, from: data)
        else {
            return []
        }

        return decoded.operations.compactMap { raw in
            switch raw.op.lowercased() {
            case "add":
                guard let kind = raw.kind.flatMap(MemoryKind.init(rawValue:)),
                      let text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text.count <= maxItemCharacters
                else { return nil }
                let days = raw.days.map { min(max($0, 1), 180) }
                return .add(kind: kind, text: text, expiresInDays: kind == .followUp ? (days ?? 14) : nil)
            case "update":
                guard let id = raw.id.flatMap(snapshot.resolve(handle:)),
                      let text = raw.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text.count <= maxItemCharacters
                else { return nil }
                return .update(id: id, text: text)
            case "delete":
                guard let id = raw.id.flatMap(snapshot.resolve(handle:)) else { return nil }
                return .delete(id: id)
            default:
                return nil
            }
        }
    }

    /// 模型十有八九会把 JSON 包在 ```json 里,有时前面还带一句「好的，以下是」。
    /// 取第一个 `{` 到最后一个 `}`,比指望它守格式可靠。
    private static func jsonPayload(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end])
    }

    private struct RawOperations: Decodable {
        let operations: [RawOperation]
    }

    private struct RawOperation: Decodable {
        let op: String
        let kind: String?
        let text: String?
        let id: String?
        let days: Int?
    }
}

/// 什么样的会话值得花一次模型调用去抽记忆。
///
/// 抽取跑在会话**结束**时,不是每一轮结束——每问一句多付一次调用,而绝大多数健康对话三五轮
/// 就完了,那笔钱花在一句「他关心睡眠」上不值。
enum MemoryHarvest {
    /// 一问一答的会话没什么可记的:那是查数据,不是说自己的事。
    static let minimumUserMessages = 2

    static func shouldHarvest(_ session: ChatSession) -> Bool {
        // 说好不存就是不存。隐私会话里抽记忆,等于换个地方把它存下来了。
        guard !session.isPrivate else { return false }
        // 上次抽过之后没有新内容,就别再抽一遍。
        guard session.messages.count > session.memoryHarvestedMessageCount else { return false }
        return session.messages.count(where: { $0.role == .user }) >= minimumUserMessages
    }
}
