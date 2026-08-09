import Foundation
import Testing
import AgentRuntime

@testable import HealthChat

/// 会话目录的读取开销。
///
/// 这段和上下文规划一样,跑在用户已经在等的时候:每轮回复结束要刷一次列表,
/// `search_sessions` 每次调用要建一次索引,从 check-in 进 app 要找一次延续线。
/// 而会话文件是这个 app 里**最大**的一类数据——一条会话里两次健康查询的原始输出就有一万多
/// 字符,`storedTurn.exactTranscript` 还会再存一份给模型回放用的。
///
/// 盯耗时也盯 `phys_footprint`:iOS 决定要不要干掉这个 app 看的就是它,而"把一年的会话
/// 全部解成对象图"正是那种一次就能把峰值顶上去的操作。
@Suite("Session store performance")
struct SessionStorePerformanceTests {

    /// 一条真实体量的会话:三问三答,每答两次健康查询,工具输出按线上的闸门封顶。
    private static func realisticSession(index: Int, now: Date) -> ChatSession {
        var messages: [ChatMessage] = []
        for turn in 0..<3 {
            messages.append(ChatMessage(role: .user, text: "第 \(turn) 问：最近的睡眠和步数怎么样"))
            let calls = (0..<2).map { slot in
                ToolCallRecord(
                    id: "call_\(index)_\(turn)_\(slot)",
                    name: slot == 0 ? "daily_steps" : "sleep_summary",
                    input: #"{"days":30}"#,
                    // `ContextPolicy.maxToolOutputCharacters` 就是这个量级。
                    output: String(repeating: "08-0\(slot) | 9,132 步 | 7 小时 12 分\n", count: 150)
                )
            }
            messages.append(ChatMessage(
                role: .assistant,
                text: "第 \(turn) 答：这一个月日均 9,100 步，平均睡眠 7 小时 05 分。",
                toolCalls: calls,
                storedTurn: .init(
                    // 回放用的那一份。同样的文本在文件里其实存了两遍——这正是全量解码贵在哪儿。
                    exactTranscript: .init(messages: calls.map {
                        .toolResult(
                            toolCallId: $0.id,
                            toolName: $0.name,
                            result: .string($0.output ?? ""),
                            isError: false
                        )
                    }),
                    state: .completed
                )
            ))
        }
        return ChatSession(
            messages: messages,
            createdAt: now.addingTimeInterval(-Double(index) * 3_600),
            updatedAt: now.addingTimeInterval(-Double(index) * 3_600)
        )
    }

    private static func seededStore(count: Int) async throws -> SessionStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(parent: directory)
        let now = Date()
        for index in 0..<count {
            try await store.save(realisticSession(index: index, now: now))
        }
        return store
    }

    /// 一年的会话。每天一条不算多,而这个 app 是每天都会被打开的那种。
    private static let sessionCount = 300

    @Test("listing, recall and thread lookup stay cheap on a year of conversations")
    func directoryReadsAreBounded() async throws {
        let store = try await Self.seededStore(count: Self.sessionCount)

        let sampler = FootprintSampler()
        sampler.start()
        let started = ContinuousClock.now

        // 一轮回复结束时真实会发生的事:刷列表、建召回索引、找延续线。
        _ = await store.summaries()
        let index = await store.recallIndex(excluding: UUID())
        _ = index.search(query: "睡眠 加班")
        _ = await store.openThread(.checkIn)

        let elapsed = ContinuousClock.now - started
        let peak = sampler.stop()

        // 实测 33 毫秒 / 0.2 MB。留了三四倍余量:数字本身不是目标,盯的是别再退回
        // "每次都把一年的会话全解成对象图"——那一版是 380 毫秒、峰值多 41 MB,
        // 而这段每轮回复结束都要跑一次。
        #expect(index.digests.count == Self.sessionCount)
        #expect(elapsed < .milliseconds(120), "一年的会话读一遍花了 \(elapsed)")
        #expect(peak < 8_000_000, "峰值多了 \(peak / 1_000_000) MB")
    }

    @Test("after a turn only the file that changed is decoded again")
    func indexUpdatesIncrementally() async throws {
        let store = try await Self.seededStore(count: Self.sessionCount)
        _ = await store.summaries()

        // 一轮回复结束真实发生的事:存一条,然后刷列表。另外二百九十九条一个字都没变。
        let fresh = Self.realisticSession(index: 9_999, now: Date())
        try await store.save(fresh)

        let started = ContinuousClock.now
        let summaries = await store.summaries()
        let elapsed = ContinuousClock.now - started

        #expect(summaries.count == Self.sessionCount + 1)
        // 全量重解是 33 毫秒,增量该在个位数。差的这一截就是用户每轮多等的时间。
        #expect(elapsed < .milliseconds(12), "只改了一条却花了 \(elapsed)")
    }

    @Test("a second recall in the same turn costs nothing")
    func recallIndexIsCached() async throws {
        let store = try await Self.seededStore(count: Self.sessionCount)
        let current = UUID()
        _ = await store.recallIndex(excluding: current)

        // 一轮里 `search_sessions` 和 `read_session` 是连着来的。第二次再扫一遍目录是白干。
        let started = ContinuousClock.now
        _ = await store.recallIndex(excluding: current)
        #expect(ContinuousClock.now - started < .milliseconds(5))
    }

    @Test("the cached index does not hold the conversations themselves in memory")
    func indexStaysSlim() async throws {
        let store = try await Self.seededStore(count: Self.sessionCount)

        let sampler = FootprintSampler()
        sampler.start()
        _ = await store.recallIndex()
        let peak = sampler.stop()

        // 索引常驻在 actor 里。它只该留检索要用的那点东西——把一年的工具输出跟着留下,
        // 是为了一个每轮最多用两次的功能付整段内存。实测 0.03 MB。
        #expect(peak < 4_000_000, "索引建完峰值多了 \(peak / 1_000_000) MB")
    }
}
