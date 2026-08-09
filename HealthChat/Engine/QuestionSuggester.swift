import Foundation
import AIKit

/// 用当下时间和最近几天的数据，让模型写三条首屏问题。
///
/// 固定文案只能问"最近一周睡得怎么样"，而真实动机是具体的：昨晚睡得比平时短、
/// 昨天刚跑完十公里、这周一天没动。这些只有看过数据才问得出来。
///
/// 生成失败不算错误——调用方继续用 `SuggestedQuestions.defaults`，首屏不会空着。
struct QuestionSuggester: Sendable {
    let providerId: String
    let model: String
    /// 本地判定出来的处境。模型拿到的是"昨晚少睡 100 分钟"这种结论,不是一堆原始数字。
    let situation: HealthSituation

    private static let instructions = """
    你在为一个健康分析 app 写首屏的问题建议，这些问题会直接显示成三个可点的按钮。
    用户通常是刚练完、觉得没睡好、感觉不太舒服，或者想知道自己最近怎么样，才会打开它。

    要求：
    - 只输出三行，每行一个问题，不要编号、不要引号、不要任何解释。
    - 中文，口语，每行不超过 14 个字，必须是用户会对自己健康数据提的问题。
    - 必须能用步数、睡眠、静息心率与 HRV、锻炼、体重体脂这几类数据回答。
    - 「从数据里读到的情况」按重要性排好了，第一条最该被问到；三个问题不要都问同一件事。
    - 给了「他平时的关注点」的话，在同样重要的几件事里优先问他关心的那一类；\
    但数据里刚发生的事更要紧，别为了迁就习惯把它挤掉。
    - 用第一人称的口气，像用户自己在问，不是像 app 在提示。
    - 不做诊断，也不要写成建议或结论，只写问题。
    """

    func suggestions() async throws -> [SuggestedQuestion] {
        guard let storedKey = try KeychainStore.get(account: KeychainStore.apiKeyAccount) else {
            throw AgentError.needsAPIKey
        }
        let key = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.needsAPIKey }

        let client = try AIClient(providerId: providerId, configuration: .init(apiKey: key))
        let response = try await client.generate(CallOptions(
            model: model,
            prompt: [
                .system(Self.instructions),
                .user("\(situation.brief)\n\n最近数据：\n\(await digest())")
            ],
            maxOutputTokens: 200,
            temperature: 0.7,
            // 同 `FollowUpSuggester`:留空是接受模型的默认,而好几家的默认是思考。
            thinking: .off
        ))

        let questions = Self.parse(response.text)
        // 少于三条说明模型没照格式写,与其拼一半不如整体退回本地判定出来的那几条。
        guard questions.count == 3 else { return situation.questions }
        return questions
    }

    /// 给模型看的数据摘要。工具本身就返回按天聚合的短文本,直接复用。
    private func digest() async -> String {
        let wanted = ["sleep_summary", "daily_steps", "workouts"]
        var lines: [String] = []

        for name in wanted {
            guard let spec = HealthTools.spec(named: name) else { continue }
            guard let result = try? await spec.run(7, nil) else { continue }
            lines.append("[\(name)]\n\(result)")
        }

        return lines.isEmpty ? "（暂时没有可用数据）" : lines.joined(separator: "\n\n")
    }

    private static func parse(_ text: String) -> [SuggestedQuestion] {
        ModelLines.parse(text, minCharacters: 4, maxCharacters: 14, limit: 3)
            .map { SuggestedQuestion(icon: "sparkles", text: $0) }
    }
}

/// 「让模型写几行短句」这件事的收尾:剥壳、按长度筛、取前几条。
///
/// 首屏建议和追问 chip 共用一份。各写一遍迟早漂,而漂的后果是不对称的——一边照常显示,
/// 另一边悄悄空着,谁都不会发现。
enum ModelLines {
    static func parse(
        _ text: String,
        minCharacters: Int,
        maxCharacters: Int,
        limit: Int
    ) -> [String] {
        let lines: [String] = text.split(separator: "\n").map { line in
            line.trimmingCharacters(in: .whitespaces)
                // 模型经常还是会带上 "1. " "- " "「」" 之类的壳。
                .trimmingCharacters(in: shell)
        }
        let usable = lines.filter { $0.count >= minCharacters && $0.count <= maxCharacters }
        return Array(usable.prefix(limit))
    }

    private static let shell = CharacterSet(charactersIn: "0123456789.、-–—*·「」\"“” ")
}
