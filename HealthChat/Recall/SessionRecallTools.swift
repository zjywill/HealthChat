import Foundation
import AgentRuntime

/// 在过往对话里找回结论。
///
/// 补的是 `MemoryStore` **故意**不覆盖的那块:记忆只存长期成立的事,不存数字、不存某一次
/// 分析的细节(那条边界是对的,别动)。于是「上个月我们查出来你睡眠差的那几天都是周三,
/// 对上了你说的加班」这类**结论**无处安放——它会过期,不该进记忆;它又是模型当时做的归因,
/// 重查一遍数据也拿不回来。它属于**那次会话**。
///
/// 所以这里只做一件事:让模型能翻到那次会话并读回当时说了什么。数字一概不信,现查。
enum SessionRecallTools {
    static let searchToolName = "search_sessions"
    static let readToolName = "read_session"

    /// - Parameters:
    ///   - store: 测试传自己的。app 侧测试跑在 app host 里,`.shared` 就是模拟器上那份真数据。
    ///   - currentSessionId: 正在进行的这条。排掉它,否则模型会把自己刚说过的话当成"上次"。
    static func registry(
        store: SessionStore = .shared,
        currentSessionId: UUID? = nil
    ) -> CapabilityRegistry {
        CapabilityRegistry(definitions: [searchDefinition, readDefinition]) { invocation in
            let input = try? RuntimeJSONValue.decode(from: invocation.input)
            switch invocation.name {
            case searchToolName:
                return await search(
                    query: input?["query"]?.stringValue ?? "",
                    sinceDays: input?["since_days"]?.intValue,
                    store: store,
                    currentSessionId: currentSessionId
                )
            case readToolName:
                return await read(
                    handle: input?["id"]?.stringValue ?? "",
                    store: store,
                    currentSessionId: currentSessionId
                )
            default:
                return .failure("不支持名为 \(invocation.name) 的工具。")
            }
        }
    }

    // MARK: - 定义

    private static var searchDefinition: CapabilityDefinition {
        CapabilityDefinition(
            name: searchToolName,
            description: """
            在过往对话里找出相关的那几次，返回摘要列表（不含健康数据）。\
            用户提到「上次」「之前说过」「我们聊过」，或者你要回答的问题明显接着一段历史\
            （正在进行的计划、之前解释过的异常、说好要回头看的事）时调用。\
            只想知道最近聊了什么就把 query 留空。\
            找到相关的那条之后用 read_session 读它。\
            这里返回的是当时说过的话，不是现在的健康数据——具体数值一律用健康工具现查。
            """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "query": .object([
                        "type": "string",
                        "description": "要找的话题，用中文关键词，比如「睡眠 加班」「减脂计划」。留空则返回最近几次对话"
                    ]),
                    "since_days": .object([
                        "type": "integer",
                        "description": "只找最近多少天以内的对话，1–365。不传就不限时间",
                        "minimum": 1,
                        "maximum": 365
                    ])
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private static var readDefinition: CapabilityDefinition {
        CapabilityDefinition(
            name: readToolName,
            description: """
            读回某一次过往对话里说过的话。id 用 search_sessions 给出的短编号，比如 S3。\
            读到的每一段都标着日期，里面的具体数值都是当时查的，现在多半已经变了——\
            要用数值就重新调健康工具，以本次返回的为准。
            """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": .object([
                        "type": "string",
                        "description": "search_sessions 给出的短编号，形如 S3"
                    ])
                ]),
                "required": .array([.string("id")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    // MARK: - 执行

    private static func search(
        query: String,
        sinceDays: Int?,
        store: SessionStore,
        currentSessionId: UUID?
    ) async -> CapabilityExecutionResult {
        let index = await store.recallIndex(excluding: currentSessionId)
        let now = Date()
        let since = sinceDays.map { now.addingTimeInterval(-Double(min(max($0, 1), 365)) * 86_400) }
        let matches = index.search(query: query, since: since)

        guard !matches.isEmpty else {
            // 不当错误报。「以前没聊过这个」是一个有效答案,模型据此就该老老实实去查数据;
            // 报成错误它会以为工具坏了,然后换个说法再试一次,白花一轮。
            return .success(index.isEmpty ? "还没有可以回顾的过往对话。" : "没有找到相关的过往对话。")
        }

        let listing = matches.map { $0.listing(now: now, calendar: .current) }.joined(separator: "\n")
        return .success("找到 \(matches.count) 次相关对话：\n\(listing)\n\n用 read_session 读其中一条。")
    }

    private static func read(
        handle: String,
        store: SessionStore,
        currentSessionId: UUID?
    ) async -> CapabilityExecutionResult {
        let index = await store.recallIndex(excluding: currentSessionId)
        guard let digest = index.digest(handle: handle) else {
            return .failure("没有编号为 \(handle) 的对话。先调 search_sessions 拿编号。")
        }
        // 索引只留了检索要用的那点东西,全文现在才去读。
        guard let session = try? await store.load(id: digest.id) else {
            return .failure("编号 \(handle) 的对话已经读不到了，可能刚被删除。")
        }
        return .success(SessionRecallTranscript.text(for: session))
    }
}

private extension CapabilityExecutionResult {
    static func success(_ text: String) -> CapabilityExecutionResult {
        CapabilityExecutionResult(output: .init(kind: .text, text: text))
    }

    static func failure(_ text: String) -> CapabilityExecutionResult {
        CapabilityExecutionResult(output: .init(kind: .text, text: text), isError: true)
    }
}
