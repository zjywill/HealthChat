import Foundation
import Testing

@testable import Vana

/// 延续线:每天的 check-in 接成一条,但接得**有期限**。
///
/// 这里盯两头。一头是连不上——每次 check-in 都开新会话,「这件事」就散在三十条标题都叫
/// 「早上好」的会话里。另一头是连过头——永远接着上一条会把它养成一份永不结束的日志:
/// 每轮都要压缩一次,用户翻到底要滑半天。
@Suite("SessionThread")
struct SessionThreadTests {

    private static func freshStore() -> SessionStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionStore(parent: directory)
    }

    private static let day: TimeInterval = 86_400

    private static func threaded(
        _ thread: SessionThread,
        messages: Int = 2,
        updatedAt: Date
    ) -> ChatSession {
        ChatSession(
            messages: (0..<messages).map {
                ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "第\($0)条")
            },
            threadId: thread.id,
            createdAt: updatedAt.addingTimeInterval(-3 * day),
            updatedAt: updatedAt
        )
    }

    // MARK: - 身份

    @Test("a thread id survives the round trip through the session file")
    func threadIdPersists() async throws {
        let store = Self.freshStore()
        let session = Self.threaded(.checkIn, updatedAt: Date())
        try await store.save(session)

        let reopened = try await store.load(id: session.id)
        #expect(reopened?.thread == .checkIn)
    }

    @Test("a follow-up thread round trips with the item it is about")
    func followUpThreadRoundTrips() throws {
        let itemId = UUID()
        let thread = SessionThread.followUp(itemId)
        // 编解码走的是一个字符串。拼得回来才谈得上"下次接着这条"。
        #expect(SessionThread(id: thread.id) == thread)
        #expect(SessionThread(id: "checkin") == .checkIn)
        #expect(SessionThread(id: "随便什么") == nil)
    }

    // MARK: - 接不接得上

    @Test("yesterday's check-in is the one today continues")
    func continuesRecentThread() async throws {
        let store = Self.freshStore()
        let now = Date()
        let yesterday = Self.threaded(.checkIn, updatedAt: now - Self.day)
        try await store.save(yesterday)

        let continued = await store.openThread(.checkIn, now: now)
        #expect(continued?.id == yesterday.id)
    }

    @Test("a thread left alone for a week starts over")
    func staleThreadStartsOver() async throws {
        let store = Self.freshStore()
        let now = Date()
        try await store.save(Self.threaded(.checkIn, updatedAt: now - 7 * Self.day))

        // 出差一周回来,接着上周三那句「昨晚睡得怎么样」往下说是接不上的。
        #expect(await store.openThread(.checkIn, now: now) == nil)
    }

    @Test("a thread that got long enough starts over instead of growing forever")
    func longThreadStartsOver() async throws {
        let store = Self.freshStore()
        let now = Date()
        try await store.save(Self.threaded(
            .checkIn,
            messages: SessionThreadPolicy.maxMessages,
            updatedAt: now
        ))

        // 断开的那条一条不丢,`search_sessions` 照样翻得到——所以这里断得起。
        #expect(await store.openThread(.checkIn, now: now) == nil)
    }

    @Test("threads do not cross: a follow-up never lands in the daily check-in")
    func threadsDoNotCross() async throws {
        let store = Self.freshStore()
        let now = Date()
        try await store.save(Self.threaded(.checkIn, updatedAt: now))

        #expect(await store.openThread(.followUp(UUID()), now: now) == nil)
    }

    @Test("an ordinary conversation is never continued as a thread")
    func plainSessionsAreNotThreads() async throws {
        let store = Self.freshStore()
        let now = Date()
        try await store.save(ChatSession(
            messages: [ChatMessage(role: .user, text: "今天走了多少步")],
            createdAt: now,
            updatedAt: now
        ))

        #expect(await store.openThread(.checkIn, now: now) == nil)
    }

    // MARK: - 列表上的名字

    @Test("a thread session is titled by its thread, not by its first line")
    func threadSessionTitle() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let session = ChatSession(
            messages: [ChatMessage(role: .user, text: "昨晚睡得怎么样？")],
            threadId: SessionThread.checkIn.id,
            createdAt: when,
            updatedAt: when
        )

        // 拿首条消息当标题的话,列表里会出现好几条一模一样的「昨晚睡得怎么样？」,
        // 而它们本该是一件事的几段。
        #expect(session.title.contains(SessionThread.checkIn.title))
        #expect(session.title.contains(SessionRecall.dateLabel(when, now: when)))
    }

    // MARK: - 从通知进来

    @Test("today's check-in lands in yesterday's thread, not in a fresh session")
    @MainActor
    func checkInContinuesYesterday() async throws {
        let store = Self.freshStore()
        let yesterday = Self.threaded(.checkIn, updatedAt: Date() - Self.day)
        try await store.save(yesterday)

        let viewModel = ChatViewModel(loadsPersistedSession: false, sessionStore: store)
        viewModel.open(CheckInLaunch(topicId: "sleep", question: "昨晚睡得怎么样？", thread: .checkIn))
        try await waitUntil("接上昨天那条") { viewModel.session.id == yesterday.id }

        // 昨天那几句还在:用户第一次能看到一件事的过程,而不是三十条一模一样的新会话。
        #expect(viewModel.messages.count == yesterday.messages.count)
        #expect(viewModel.input == "昨晚睡得怎么样？")
        // 延续线不带话题——今天问活动量、明天问睡眠,写死在 system 段里的话题聊到第三天
        // 就和正在问的事对不上了。
        #expect(viewModel.session.topicId == nil)
    }

    @Test("Siri's one-off question does not get appended to the check-in thread")
    @MainActor
    func siriStartsItsOwnSession() async throws {
        let store = Self.freshStore()
        let existing = Self.threaded(.checkIn, updatedAt: Date())
        try await store.save(existing)

        let viewModel = ChatViewModel(loadsPersistedSession: false, sessionStore: store)
        // Siri 那条路不带线程:一句临时想到的问题接到昨天的 check-in 后面,只会让两件事
        // 互相干扰。
        viewModel.open(CheckInLaunch(topicId: nil, question: "我上周跑了多少公里", autoSend: false))
        try await waitUntil("开出一条新的") { !viewModel.isLoadingConversation }

        #expect(viewModel.session.id != existing.id)
        #expect(viewModel.session.threadId == nil)
    }

    @Test("branching off a thread does not claim the thread")
    @MainActor
    func branchingDropsTheThread() async throws {
        let store = Self.freshStore()
        let threaded = Self.threaded(.checkIn, updatedAt: Date())
        try await store.save(threaded)

        let viewModel = ChatViewModel(loadsPersistedSession: false, sessionStore: store)
        viewModel.open(CheckInLaunch(topicId: nil, question: nil, thread: .checkIn))
        try await waitUntil("接上那条延续线") { viewModel.session.threadId != nil }

        let messageId = try #require(viewModel.messages.last?.id)
        viewModel.branch(from: messageId)

        // 两条会话都认领同一条线的话,下次 check-in 接哪条就成了看谁最后更新的,
        // 而用户完全看不出规则。
        #expect(viewModel.session.threadId == nil)
    }
}
