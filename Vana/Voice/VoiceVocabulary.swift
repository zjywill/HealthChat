import Foundation

/// 说给识别器听的那份词表(`AnalysisContext.contextualStrings`)。
///
/// **这是自己做语音输入的唯一硬理由。** 系统键盘上那颗麦克风本来就在 Vana 的输入框里能用,
/// 不需要一行代码;它缺的不是「能说话」,是不知道用户在跟一个健康 app 说话——「静息心率」
/// 「HRV」「甘氨酸镁」按通用语言模型猜,十次里认不对几次。而该提示什么这个 app 是现成的:
/// 用药表里的药名、记忆里他惯用的说法、健康工具的指标名。识别对一次「甘氨酸镁」,比整套
/// 录音 UI 都值钱。
///
/// 几条边界:
///
/// - **纯函数,材料从快照来。** 词表跟着会话走(`MedicationSnapshot` / `MemorySnapshot` 都是
///   会话开始时读好的),不中途去读盘——同 system 段那两块。按住说话的那一刻再去读一次
///   `medications.json`,是在用户已经开始说话的时候做一次磁盘 IO。
/// - **两个开关自动生效。** 关掉记忆或用药表时 `ChatViewModel` 那两份快照本来就是空的,
///   这里不需要再判一次:关掉的人不指望 Vana 还记着他吃什么,识别偏置也一样。
/// - **不能吃的排最前面。** 词表满了要裁,而「我对青霉素过敏」这句话里认错的那个词,
///   代价和别处不是一个量级(同 `MedicationSnapshot.trimmed` 永不裁 `cannotTake`)。
enum VoiceVocabulary {
    /// 一次最多提示多少个词。
    ///
    /// 没有公开的硬上限,但这份东西每次识别都要整份带进去,而偏置的效果本来就随词数稀释——
    /// 一百个词里真正会被说到的只有那么几个。药名在前,裁掉的是最不常被说到的那一头。
    static let maxTerms = 100

    /// 单个词最长多少字。再长的不是词,是一句话——而一句话作为提示词只会把识别往它那儿带。
    static let maxTermCharacters = 16

    /// 从工具标签拆出来的那几个,超过这个长度就不要了。
    ///
    /// 标签是写给界面读的短语(「数据之间的关联」),不是人会说出口的词;而真正会被说到的
    /// 指标名都很短(「静息心率」「体脂」「血氧」)。锻炼类型不走这条——「高强度间歇训练」
    /// 有七个字,却是用户原样说出来的那个名字。
    private static let maxDerivedCharacters = 6

    /// 会话相关的那一份。顺序就是裁剪的优先级。
    static func terms(medications: MedicationSnapshot, memory: MemorySnapshot) -> [String] {
        var result: [String] = []
        // 1. 药名。这是这份词表存在的理由,排最前面;「不能吃」那一组又排在药名的最前面。
        for status in MedicationStatus.allCases {
            for item in medications.items where item.status == status {
                result.append(item.name)
            }
        }
        // 2. 他惯用的说法。比通用词表值钱,比药名泛一点。
        result += memoryTerms(in: memory)
        // 3. 指标名。对每个用户都一样,所以排最后——裁掉它们的代价最小。
        result += metricTerms
        return normalized(result)
    }

    /// 健康指标那一组。**和工具目录同一个源**:标签在 `HealthTools.label` 里改了名字,
    /// 这里跟着变,不会出现「界面叫体脂、词表还提示着体脂率」那种漂移。
    ///
    /// 光靠标签不够——它们是「静息心率与 HRV」这种给界面读的短语,而识别真正认不准的是
    /// 更细的那一层(深睡、REM、心率变异性)。所以标签拆开之后再补一组手写的细词。
    static var metricTerms: [String] {
        var terms = HealthTools.all
            .flatMap { split(HealthTools.label(for: $0.name)) }
            .filter { $0.count <= maxDerivedCharacters }
        // 锻炼类型原样进:用户说的就是这几个名字,不受上面那条长度规则管。
        terms += HealthTools.activityNames
        terms += fineGrainedTerms
        return normalized(terms)
    }

    /// 工具标签盖不到、而识别又最容易认错的那一层。
    ///
    /// 判据和整份词表一样:**只放会被说出口、且通用语言模型认不准的**。「今天」「多少」这类
    /// 词不进来——它们本来就认得准,占的却是同一个名额。
    private static let fineGrainedTerms = [
        "静息心率", "心率变异性", "HRV", "血氧", "血氧饱和度", "呼吸频率", "体温",
        "深睡", "核心睡眠", "快速眼动", "REM", "睡眠效率", "入睡时间", "睡眠分期",
        "体脂", "体脂率", "去脂体重", "BMI", "腰围",
        "收缩压", "舒张压", "高压", "低压",
        "步数", "爬楼", "运动分钟", "活动能量", "静息能量", "配速", "最大摄氧量",
        "化验单", "体检报告", "空腹血糖", "糖化血红蛋白", "血红蛋白", "白细胞", "血小板",
        "总胆固醇", "低密度脂蛋白", "高密度脂蛋白", "甘油三酯", "尿酸", "肌酐",
        "转氨酶", "促甲状腺激素", "维生素 D"
    ]

    // MARK: - 记忆里他惯用的说法

    /// 从记忆里挑出**词**,不是句子。
    ///
    /// 记忆存的是「他觉得睡够 7 小时才算好」这种整句,原样丢进 `contextualStrings` 只会把
    /// 识别往这一整句上带。真正值钱的是句子里那几个专有的说法:引号里被他特意标出来的词,
    /// 以及夹在中文里的英文缩写(HRV、CGM、VO2max)——后者恰好是中文识别最容易认崩的一类。
    static func memoryTerms(in memory: MemorySnapshot) -> [String] {
        normalized(memory.items.flatMap { terms(inMemoryText: $0.text) })
    }

    static func terms(inMemoryText text: String) -> [String] {
        var found = quoted(in: text)
        var latin = ""
        // 末尾那一段靠这个哨兵收尾,不必在循环外再抄一遍收集逻辑。
        for character in text + "\u{0}" {
            let isLatin = character.isASCII && (character.isLetter || character.isNumber)
            if isLatin {
                latin.append(character)
                continue
            }
            defer { latin = "" }
            // 纯数字不要:「7」「120」当提示词毫无意义,还会把数字往它上面带。
            guard latin.count >= 2, latin.contains(where: \.isLetter) else { continue }
            found.append(latin)
        }
        return found
    }

    /// 引号(中英文都算)里的那几段。用户特意加引号的地方,多半正是他自己的说法。
    private static func quoted(in text: String) -> [String] {
        let pairs: [(Character, Character)] = [("「", "」"), ("“", "”"), ("《", "》"), ("『", "』")]
        var found: [String] = []
        for (open, close) in pairs {
            var current: String?
            for character in text {
                if character == open {
                    current = ""
                } else if character == close, let value = current {
                    found.append(value)
                    current = nil
                } else {
                    current?.append(character)
                }
            }
        }
        return found
    }

    // MARK: - 收尾

    /// 拆开「静息心率与 HRV」这种并列短语。
    private static func split(_ label: String) -> [String] {
        label
            .components(separatedBy: CharacterSet(charactersIn: "与、和/（）()"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 去空、去重、限长、限量。顺序保持传进来的那个——裁掉的永远是最后面那一批。
    static func normalized(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            // 一个字的词是噪声:它几乎一定会命中,却什么都没消歧。
            guard trimmed.count >= 2, trimmed.count <= maxTermCharacters else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == maxTerms { break }
        }
        return result
    }
}
