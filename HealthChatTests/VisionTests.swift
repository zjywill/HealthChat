import Foundation
import Testing
import UIKit

@testable import HealthChat

/// 拍照识别:表格不能散、发出去的是什么用户看得见、图片不进上下文。
///
/// 这套东西真正会翻车的地方只有一处——**按识别顺序平铺**。「血红蛋白 132 g/L 130-175 ↓」
/// 被拆散重排之后,数值和项目对不上,而模型会一本正经地解释一个错的数。所以大半的用例都在
/// 盯 `RecognizedTextLayout`。
@Suite("Vision")
struct VisionTests {

    // MARK: - 按几何重建

    @Test("同一行的项目和数值留在一行，列之间分得开")
    func tableRowStaysTogether() {
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("血红蛋白", x: 0.05, y: 0.30, width: 0.20, height: 0.03),
            RecognizedFragment("132", x: 0.35, y: 0.30, width: 0.06, height: 0.03),
            RecognizedFragment("g/L", x: 0.50, y: 0.30, width: 0.06, height: 0.03),
            RecognizedFragment("130-175", x: 0.65, y: 0.30, width: 0.12, height: 0.03),
        ])
        #expect(text == "血红蛋白 | 132 | g/L | 130-175")
    }

    @Test("识别顺序不算数，按 y 从上到下、x 从左到右重排")
    func readingOrderIsRestored() {
        // Vision 给回来的顺序是它自己的,不一定是阅读顺序。
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("132", x: 0.35, y: 0.30, width: 0.06, height: 0.03),
            RecognizedFragment("白细胞", x: 0.05, y: 0.35, width: 0.16, height: 0.03),
            RecognizedFragment("血红蛋白", x: 0.05, y: 0.30, width: 0.20, height: 0.03),
            RecognizedFragment("6.1", x: 0.35, y: 0.35, width: 0.06, height: 0.03),
        ])
        #expect(text == "血红蛋白 | 132\n白细胞 | 6.1")
    }

    @Test("挨着的中文不补空格，那是识别把一句话切成了两段")
    func adjacentChineseIsNotPaddedWithSpaces() {
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("血红蛋白", x: 0.05, y: 0.30, width: 0.10, height: 0.03),
            RecognizedFragment("浓度", x: 0.155, y: 0.30, width: 0.05, height: 0.03),
        ])
        #expect(text == "血红蛋白浓度")
    }

    @Test("中文之间空出一格的照样补空格")
    func spacedChineseFieldsKeepTheirGap()  {
        // 「性别：男    年龄：34」在版面上是两格。连起来写成「男年龄」比多一个空格难读得多,
        // 而这一条是真拍出来的化验单抬头上第一眼就能看见的。
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("性别：男", x: 0.05, y: 0.10, width: 0.12, height: 0.03),
            RecognizedFragment("年龄：34", x: 0.185, y: 0.10, width: 0.12, height: 0.03),
        ])
        #expect(text == "性别：男 年龄：34")
    }

    @Test("一行里字号差一倍也还是一行")
    func mixedFontSizesShareARow() {
        // 箭头比项目名矮一半。按「中心点差多少」判会把它甩到下一行去,而那个箭头正是
        // 「偏高还是偏低」的全部信息。
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("总胆固醇", x: 0.05, y: 0.10, width: 0.20, height: 0.04),
            RecognizedFragment("↓", x: 0.80, y: 0.115, width: 0.02, height: 0.015),
        ])
        #expect(text == "总胆固醇 | ↓")
    }

    @Test("上下两行不会被并成一行")
    func separateRowsStaySeparate() {
        let rows = RecognizedTextLayout.rows(from: [
            RecognizedFragment("姓名：张三", x: 0.05, y: 0.10, width: 0.25, height: 0.02),
            RecognizedFragment("门诊号：0421", x: 0.05, y: 0.13, width: 0.30, height: 0.02),
        ])
        #expect(rows.count == 2)
    }

    @Test("空白碎片不占一行")
    func blankFragmentsAreDropped() {
        let text = RecognizedTextLayout.reconstruct([
            RecognizedFragment("  ", x: 0.05, y: 0.10, width: 0.05, height: 0.02),
            RecognizedFragment("体检报告", x: 0.05, y: 0.20, width: 0.20, height: 0.02),
        ])
        #expect(text == "体检报告")
    }

    // MARK: - 截断

    @Test("超长按行截，并数清楚截掉了几行")
    func truncationCutsOnLineBoundaries() {
        let text = (1...10).map { "第\($0)行数据" }.joined(separator: "\n")
        let cut = RecognizedTextLayout.truncated(text, maxCharacters: 20)
        // 半行数据比没有这行更糟:截在行边界上。
        #expect(!cut.text.hasSuffix("第"))
        #expect(cut.text.split(separator: "\n").allSatisfy { $0.hasSuffix("行数据") })
        #expect(cut.droppedLines == 10 - cut.text.split(separator: "\n").count)
        #expect(cut.droppedLines > 0)
    }

    @Test("没超就一个字不动")
    func shortTextIsUntouched() {
        let cut = RecognizedTextLayout.truncated("血红蛋白 | 132", maxCharacters: 4000)
        #expect(cut.text == "血红蛋白 | 132")
        #expect(cut.droppedLines == 0)
    }

    @Test("整张图认成一行时也得留下点东西")
    func oneVeryLongLineStillYieldsText() {
        let cut = RecognizedTextLayout.truncated(String(repeating: "数", count: 500), maxCharacters: 100)
        #expect(cut.text.count == 100)
    }

    // MARK: - 模型收到的那一份

    @Test("每张图各自编号，并说清这是机器认的不是他打的")
    func modelTextNumbersEachPhoto() {
        let text = ChatAttachment.modelText(
            typed: "这两页帮我看看",
            attachments: [
                ChatAttachment(text: "血红蛋白 | 132"),
                ChatAttachment(text: "白细胞 | 6.1"),
            ]
        )
        #expect(text.hasPrefix("这两页帮我看看"))
        #expect(text.contains("【照片 1】"))
        #expect(text.contains("【照片 2】"))
        #expect(text.contains("不是他打的字"))
        #expect(text.contains("血红蛋白 | 132"))
    }

    @Test("截掉的那几行要在发出去的文本里说清楚")
    func modelTextDeclaresTruncation() {
        let text = ChatAttachment.modelText(
            typed: "",
            attachments: [ChatAttachment(text: "第一项", droppedLines: 12)]
        )
        // 不说的话,用户问「最后那项呢」的时候模型会一口咬定没有。
        #expect(text.contains("12 行"))
    }

    @Test("一个字都没认出来不是错误")
    func emptyRecognitionIsNotAnError() {
        let text = ChatAttachment.modelText(typed: "这是什么", attachments: [ChatAttachment(text: "")])
        // 一顿饭、一处皮疹本来就没有字。照实说,别让模型对着一段空白硬编。
        #expect(text.contains("没有识别到文字"))
        #expect(text.contains("看不了图像本身"))
    }

    @Test("没有照片时原样就是他打的那句话")
    func modelTextWithoutAttachmentsIsUnchanged() {
        #expect(ChatAttachment.modelText(typed: "今天走了多少步", attachments: []) == "今天走了多少步")
    }

    // MARK: - 消息与会话

    @Test("发给模型的是拼好的那份，存在消息上的仍然只是他打的字")
    func messageKeepsTypedTextApartFromRecognizedText() {
        let message = ChatMessage(
            role: .user,
            text: "帮我看看",
            attachments: [ChatAttachment(text: "血红蛋白 | 132")]
        )
        // 标题、召回索引、记忆抽取要的是他自己说的那句话——把几千字的化验单掺进去,
        // 会话列表上那行标题会变成一行血常规。
        #expect(message.text == "帮我看看")
        #expect(message.agentDTO.text.contains("血红蛋白 | 132"))
        #expect(message.agentDTO.text.hasPrefix("帮我看看"))
    }

    @Test("只拍了一张图、一个字没打，列表上不该叫「新对话」")
    func photoOnlySessionGetsATitle() {
        let session = ChatSession(messages: [
            ChatMessage(role: .user, text: "", attachments: [ChatAttachment(text: "布洛芬缓释胶囊")])
        ])
        #expect(session.title == "照片")
    }

    @Test("附件跟着会话存下来又读回来")
    func attachmentsSurviveARoundTrip() throws {
        let session = ChatSession(messages: [
            ChatMessage(
                role: .user,
                text: "这个能吃吗",
                attachments: [ChatAttachment(text: "布洛芬 | 0.3g", droppedLines: 2, imageFileName: "a.jpg")]
            )
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(ChatSession.self, from: encoder.encode(session))
        let attachment = try #require(restored.messages.first?.attachments.first)
        #expect(attachment.text == "布洛芬 | 0.3g")
        #expect(attachment.droppedLines == 2)
        #expect(attachment.imageFileName == "a.jpg")
    }

    // MARK: - 接到用药表上

    @Test("从识别结果里猜出的名字是第一行的第一格")
    func guessesMedicationNameFromFirstCell() {
        let name = MedicationDraft.guessedName(from: "布洛芬缓释胶囊 | 0.3g × 20粒\n用法：口服")
        #expect(name == "布洛芬缓释胶囊")
    }

    @Test("猜名字跳过空行")
    func guessedNameSkipsBlankLines() {
        #expect(MedicationDraft.guessedName(from: "\n\n褪黑素\n每晚一片") == "褪黑素")
    }

    // MARK: - 隐私会话

    /// 隐私会话是按「有哪些写入路径」定义的,不是按名字。照片是新开的一条写入路径,
    /// 所以这里必须堵上——**图片不落盘**,而识别照常在本机跑、文字照常发得出去。
    @MainActor
    @Test("隐私会话里的照片不落盘，但话照样问得出去")
    func privateSessionKeepsPhotosOffDisk() async throws {
        let client = ScriptedModelClient(
            profile: .init(
                providerId: "anthropic",
                modelId: "claude-sonnet-5",
                contextWindow: 200_000,
                maxOutputTokens: 4_000
            ),
            turns: [.init(text: "这张图里没有文字。")]
        )
        let viewModel = ChatViewModel(
            engineFactory: { _ in LoopEngine(client: client, capabilities: stubRegistry([:])) },
            // 这条路开出来的会话就是隐私会话(不读盘、不写盘)。
            loadsPersistedSession: false
        )

        viewModel.attach([Self.blankImage()])
        try await waitUntil("识别跑完") { !viewModel.isRecognizingAttachments }
        viewModel.send("这是什么")
        try await waitUntil("这轮结束") { !viewModel.isReplying }

        let sent = try #require(viewModel.messages.first { $0.role == .user })
        let attachment = try #require(sent.attachments.first)
        #expect(attachment.imageFileName == nil)
        // 发出去的仍然是文本:图不出本机,而这句话照样有人回答。
        #expect(client.lastPromptText.contains("【照片 1】"))
        #expect(client.lastPromptText.contains("这是什么"))
    }

    /// 一张白纸。识别不出文字是**确定**的结果,所以这条用例不会因为 Vision 认得准不准而飘。
    private static func blankImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }
}
