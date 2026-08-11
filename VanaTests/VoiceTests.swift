import Foundation
import Testing

@testable import Vana

/// 语音输入。**盯的几乎全是那份词表**——这个功能自己做而不是让用户接着用键盘听写,
/// 唯一撑得住的理由就是它:键盘听写不知道用户在跟一个健康 app 说话,而这个 app 手上正好
/// 有药名、有他惯用的说法、有指标名。
///
/// 录音和识别那一半没法在这儿测(要麦克风和本机模型资产,模拟器上 `supportedLocales`
/// 一个都没有),那部分的验证口在设置页「语音输入」那一段和真机。
@Suite("Voice")
struct VoiceTests {

    private static func medications(_ items: [MedicationItem]) -> MedicationSnapshot {
        MedicationSnapshot(items: items)
    }

    private static func memory(_ texts: [String]) -> MemorySnapshot {
        MemorySnapshot(items: texts.map { MemoryItem(kind: .profile, text: $0) })
    }

    // MARK: - 词表

    /// 「甘氨酸镁」这种词是这个功能存在的理由。它不在词表里的话,整件事就只剩三条体验上的
    /// 改进,而那三条自己撑不起一颗按钮加两个权限弹窗。
    @Test("用药表里的名字进词表")
    func includesMedicationNames() {
        let terms = VoiceVocabulary.terms(
            medications: Self.medications([
                MedicationItem(name: "甘氨酸镁", status: .ongoing),
                MedicationItem(name: "褪黑素", status: .tried)
            ]),
            memory: .empty
        )
        #expect(terms.contains("甘氨酸镁"))
        #expect(terms.contains("褪黑素"))
    }

    /// 词表满了要从后面裁。「我对青霉素过敏」这句话里认错的那个词,代价和别处不是一个量级
    /// (同 `MedicationSnapshot.trimmed` 永不裁 `cannotTake`)。
    @Test("不能吃的那一组排在最前面")
    func cannotTakeComesFirst() throws {
        let terms = VoiceVocabulary.terms(
            medications: Self.medications([
                MedicationItem(name: "维生素 D", status: .ongoing),
                MedicationItem(name: "青霉素", status: .cannotTake)
            ]),
            memory: .empty
        )
        let penicillin = try #require(terms.firstIndex(of: "青霉素"))
        let vitamin = try #require(terms.firstIndex(of: "维生素 D"))
        #expect(penicillin < vitamin)
    }

    /// 药名比指标名值钱:指标名对每个用户都一样,而药名只有这个用户会说。
    @Test("药名排在通用指标名前面")
    func medicationsOutrankMetrics() throws {
        let terms = VoiceVocabulary.terms(
            medications: Self.medications([MedicationItem(name: "甘氨酸镁", status: .ongoing)]),
            memory: .empty
        )
        let medication = try #require(terms.firstIndex(of: "甘氨酸镁"))
        let metric = try #require(terms.firstIndex(of: "静息心率"))
        #expect(medication < metric)
    }

    /// 记忆存的是整句话。原样丢进 `contextualStrings` 只会把识别往这一整句上带——要的是
    /// 句子里那几个专有的说法。
    @Test("记忆只贡献词，不贡献整句")
    func memoryContributesTermsNotSentences() {
        let sentence = "他觉得「深睡」到 90 分钟才算好，HRV 低于 40 就会累"
        let terms = VoiceVocabulary.terms(medications: .empty, memory: Self.memory([sentence]))
        #expect(terms.contains("深睡"))
        #expect(terms.contains("HRV"))
        #expect(!terms.contains(sentence))
        // 纯数字当提示词毫无意义,还会把数字往它上面带。
        #expect(!terms.contains("90"))
        #expect(!terms.contains("40"))
    }

    @Test("夹在中文里的英文缩写挑得出来")
    func picksLatinTokens() {
        let terms = VoiceVocabulary.terms(inMemoryText: "他每天看 CGM 曲线，也在意 VO2max")
        #expect(terms.contains("CGM"))
        #expect(terms.contains("VO2max"))
    }

    /// 一个字的词几乎一定会命中,却什么都没消歧,占的却是同一个名额。
    @Test("一个字的词和超长的句子都不要")
    func rejectsDegenerateTerms() {
        let long = String(repeating: "睡", count: VoiceVocabulary.maxTermCharacters + 1)
        let terms = VoiceVocabulary.normalized(["睡", long, "睡眠"])
        #expect(terms == ["睡眠"])
    }

    @Test("去重不看大小写，顺序保持传进来的那个")
    func deduplicates() {
        #expect(VoiceVocabulary.normalized(["HRV", "hrv", "血氧"]) == ["HRV", "血氧"])
    }

    @Test("超过上限就从后面裁")
    func trimsToLimit() {
        let many = (0..<(VoiceVocabulary.maxTerms + 20)).map { "词\($0)" }
        let terms = VoiceVocabulary.normalized(many)
        #expect(terms.count == VoiceVocabulary.maxTerms)
        #expect(terms.first == "词0")
    }

    /// 指标名和工具目录同一个源。各写一份迟早漂,漂的结果是界面上叫一个名字、词表里提示着
    /// 另一个(同 `SessionTitle.make` 只有一份算法)。
    @Test("指标名跟着 HealthTools 的标签走")
    func metricsFollowToolLabels() {
        #expect(VoiceVocabulary.metricTerms.contains("睡眠"))
        #expect(VoiceVocabulary.metricTerms.contains("血压"))
        // 锻炼类型原样进,不受那条长度规则管——用户说的就是这几个名字。
        #expect(VoiceVocabulary.metricTerms.contains("高强度间歇训练"))
        // 「数据之间的关联」是写给界面读的短语,没有人会这么说话。
        #expect(!VoiceVocabulary.metricTerms.contains("数据之间的关联"))
    }

    /// 关掉记忆或用药表时那两份快照本来就是空的,这里不需要再判一次开关。
    @Test("两份快照都空的时候还剩一份通用指标名")
    func fallsBackToMetrics() {
        let terms = VoiceVocabulary.terms(medications: .empty, memory: .empty)
        #expect(!terms.isEmpty)
        #expect(terms.contains("静息心率"))
    }

    // MARK: - 拼回输入框

    /// 打了半句发现不好打、改成说完的,是这颗按钮最常见的用法之一。覆盖掉他刚打的字是
    /// 不可撤销的——输入框没有撤销。
    @Test("说出来的接在已经打好的字后面")
    func appendsToTypedText() {
        #expect(VoiceTranscript.merge(base: "昨晚", spoken: "睡得怎么样") == "昨晚睡得怎么样")
        #expect(VoiceTranscript.merge(base: "", spoken: "睡得怎么样") == "睡得怎么样")
        #expect(VoiceTranscript.merge(base: "昨晚", spoken: "") == "昨晚")
    }

    /// 中文之间补空格反而多一格;英文之间不补就挤成另一个词。
    @Test("只有两边都是英文数字时才补空格")
    func insertsSpaceOnlyBetweenLatin() {
        #expect(VoiceTranscript.merge(base: "my", spoken: "HRV") == "my HRV")
        #expect(VoiceTranscript.merge(base: "我的", spoken: "HRV") == "我的HRV")
        #expect(VoiceTranscript.merge(base: "昨晚 ", spoken: "睡眠") == "昨晚 睡眠")
    }
}
