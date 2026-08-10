import Foundation
import AgentRuntime

/// 对话里当场记一条。
///
/// 和会话结束后的自动抽取是**互补**的,不是替代:抽取跑在后台,用户不用等,但它会漏——
/// 模型那一轮的注意力在回答问题上。用户明说「记住我不能跑步」的时候必须当场落下,并且
/// 让他在气泡上看见落下了;等他关掉 app 再由后台补记,他无从知道到底记没记住。
///
/// 反过来也不能只留这个工具:让模型在流式回答中途多跑一次工具轮,用户每次都要多等一个
/// 往返,而多数该记的事用户根本不会明说。
enum MemoryTools {
    static let rememberToolName = "remember"

    /// - Parameter store: 测试传自己的临时 store。默认这个参数不是可有可无的:
    ///   app 侧的测试跑在 app host 里,`MemoryStore.shared` 就是模拟器上那份真的
    ///   `memory.json`——测试写它等于把用户记住的东西删了。
    static func registry(store: MemoryStore = .shared) -> CapabilityRegistry {
        CapabilityRegistry(
        definitions: [
            CapabilityDefinition(
                name: rememberToolName,
                description: """
                记住一条关于这位用户的长期事实，之后每次对话都会带上。\
                只在两种情况下调用：用户明确要求记住某件事，或者他说出了一个长期成立的个人情况\
                （作息、工作安排、伤病限制、正在进行的目标、他希望你怎么说话）。
                不要记具体的健康数值和某一天的数据——那些每次都会重新查，记下来第二天就是错的。\
                不要记只在这次对话里成立的话题。不要记诊断结论。\
                同一件事已经在系统提示的「关于这位用户」里出现过了，就不要再记一遍。
                """,
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "text": .object([
                            "type": "string",
                            "description": "用中文第三人称写，一句话，不超过 40 个字"
                        ]),
                        "kind": .object([
                            "type": "string",
                            "description": .string(
                                "profile 长期情况、preference 表达偏好、"
                                    + "interpretation 已有解释、followUp 说好过一阵子再看的事"
                            ),
                            "enum": .array(MemoryKind.allCases.map { .string($0.rawValue) })
                        ]),
                        "days": .object([
                            "type": "integer",
                            "description": "只有 followUp 用：几天后回头看，范围 1–180",
                            "minimum": 1,
                            "maximum": 180
                        ])
                    ]),
                    "required": .array([.string("text"), .string("kind")]),
                    "additionalProperties": .bool(false)
                ])
            )
        ]
    ) { invocation in
        guard invocation.name == rememberToolName else {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "不支持名为 \(invocation.name) 的工具。"),
                isError: true
            )
        }

        guard EngineSettings.memoryEnabled else {
            // 报成错误,模型才会在回复里跟用户说一声。悄悄丢掉的话,它会顺口说「记住了」。
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "用户关掉了记忆功能，这次没有记下来。"),
                isError: true
            )
        }

        let input = try? RuntimeJSONValue.decode(from: invocation.input)
        let text = (input?["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let kind = input?["kind"]?.stringValue.flatMap(MemoryKind.init(rawValue:)) else {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "参数不全：需要 text 和 kind。"),
                isError: true
            )
        }

        let dueAt = kind == .followUp
            ? Date().addingTimeInterval(Double(days(fromInput: invocation.input)) * 86_400)
            : nil

        do {
            // `.asked` 而不是 `.extracted`:用户开口说了的东西,后台抽取不该再去改它。
            let items = try await store.add(
                kind: kind,
                text: text,
                origin: .asked,
                dueAt: dueAt
            )
            // 上限满了会静静地把它挤掉,那种情况下不能回「已记住」。
            guard items.contains(where: { $0.text == text }) else {
                return CapabilityExecutionResult(
                    output: .init(kind: .text, text: "记忆已满，这条没有记下来。让用户到设置里清理一下。"),
                    isError: true
                )
            }
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "已记住：\(text)")
            )
        } catch {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "没能记下来：\(error.localizedDescription)"),
                isError: true
            )
        }
        }
    }

    static func days(fromInput input: String) -> Int {
        let value = (try? RuntimeJSONValue.decode(from: input))?["days"]?.intValue ?? 14
        return min(max(value, 1), 180)
    }

    static func text(fromInput input: String) -> String? {
        (try? RuntimeJSONValue.decode(from: input))?["text"]?.stringValue
    }
}

extension CapabilityRegistry {
    /// app 这一轮真正提供的能力。
    ///
    /// 记忆关掉时连工具都不挂出去。挂一个只会报错的工具,模型得先调一次才知道不行,
    /// 用户白等一个往返,还多一条「没能记下」的气泡。
    ///
    /// - Parameter allowsMemoryWrites: 隐私会话传 false。**会话结束的抽取被挡住不等于
    ///   这一段没被记下**——`remember` 是另一条写入路径,模型在对话中途就能调,而且它落的
    ///   是最扎眼的那种(用户亲口说的事)。两条路都得堵,「不留痕迹」才是一句真话。
    ///   工具不挂出去,`AIKitEngine.systemInstruction()` 里那段「该记就调 remember」也跟着
    ///   不发——它本来就是照着 registry 里有没有这个工具来拼的。
    /// - Parameter allowsRecall: 这条会话里用户提起过过去吗(`SessionRecallTrigger`)。
    ///   没提就连工具都不挂:召回不是一个该一直摆在模型眼前的能力,把「要不要翻历史」留成
    ///   一个每轮都要做的判断,它就会每轮都判成要翻,而每翻一次用户都要多等两个往返,
    ///   还要在这一轮的上下文里吃一段过期数字。
    /// - Parameter currentSessionId: 跨会话召回要排掉正在进行的这条,否则模型会把自己刚说过的
    ///   话当成「上次」读回来。
    /// - Parameter allowsMedicationWrites: 隐私会话传 false。读的那个照挂——用药表和记忆一样,
    ///   承诺的是不往盘上写,不是失忆;而「他不能吃什么」这一条在隐私会话里尤其不能关掉。
    /// - Parameter webSearch: 网页搜索。`nil` 就**不挂出去**——没配 key 时给一个只会报错的
    ///   工具,模型得先调一次才知道不行,用户白等一个往返。默认从 Keychain 现读:key 的有无
    ///   本身就是这个功能的开关,不另做一个(一个填了 key 却关着的开关,和一个没填 key 的
    ///   开关,在界面上是两种说法、一个结果)。**隐私会话照挂**:它读的是外部世界,不往盘上
    ///   写用户的任何东西,而问题本来就要发给云端模型才有人回答。工具描述里另有一句挡着,
    ///   不许把用户的个人情况写进查询词。
    /// - Parameter includesHealthTools: 这一位成员有没有 Apple 健康数据。**只有机主有**。
    ///
    ///   这是整个多成员功能里最要紧的一处判断。挂出去的话,模型会去查,而查回来的是**机主的**
    ///   数字——它会一本正经地拿爸爸的静息心率解释妈妈的化验单。这是这个功能能出的最严重的
    ///   一种故障,而且**它不报错**:屏幕上看起来一切正常。
    ///
    ///   所以不是"挂了但让它返回空",是**根本不挂出去**——同没配 key 时不挂 `web_search`、
    ///   关掉记忆时不挂 `remember`。给一个只会给错答案的工具,比不给糟得多。
    ///   对应的 system 段那一块在 `Tenant.instructionBlock`。
    static func healthChat(
        includesHealthTools: Bool = true,
        allowsMemoryWrites: Bool = true,
        allowsRecall: Bool = false,
        allowsMedicationWrites: Bool = true,
        memoryStore: MemoryStore = .shared,
        sessionStore: SessionStore = .shared,
        medicationStore: MedicationStore = .shared,
        currentSessionId: UUID? = nil,
        webSearch: WebSearchClient? = .storedKey()
    ) -> CapabilityRegistry {
        var registries: [CapabilityRegistry] = []
        if includesHealthTools {
            registries.append(HealthTools.registry)
        }
        // 动作库**不跟着 `includesHealthTools` 走,也没有自己的开关**。它不读 HealthKit、不落盘、
        // 不联网,一份打进包里的闭集而已——所以家人成员那条路上照样挂得出去,而那正是这个
        // app 里少有的、在家人身上完整成立的健康建议。隐私会话同理:它一个字都不往盘上写。
        registries.append(ExerciseTools.registry())
        if let webSearch {
            registries.append(WebSearchTools.registry(client: webSearch))
        }
        // 用药表**不归在 `memoryEnabled` 下面**,它有自己的开关:关掉记忆的人不指望 Vana 还
        // 记得他随口说过的话,但仍然会指望这张他一条条录进去的表还在。
        if EngineSettings.medicationsEnabled {
            registries.append(MedicationTools.registry(
                store: medicationStore,
                allowsWrites: allowsMedicationWrites
            ))
        }
        // 跨会话召回归在同一个开关下面。它和记忆是同一件事的两半——一个记「关于他的长期事实」,
        // 一个找回「那次聊出来的结论」;关掉记忆的人不会指望 Vana 还在引用他上个月说过的话。
        // 隐私会话照样能**读**:承诺的是不往盘上留痕迹,不是失忆,而且它自己从不落盘,
        // 天然不在别人的索引里。
        if EngineSettings.memoryEnabled && allowsRecall {
            registries.append(SessionRecallTools.registry(
                store: sessionStore,
                currentSessionId: currentSessionId
            ))
        }
        if EngineSettings.memoryEnabled && allowsMemoryWrites {
            registries.append(MemoryTools.registry(store: memoryStore))
        }
        return .combining(registries)
    }

    /// 把几组能力并成一份给 loop。
    ///
    /// runtime 只认一个 `CapabilityRegistry`,但「查健康数据」和「记一件事」是两回事,
    /// 硬塞进 `HealthTools` 会让那个文件开始认识记忆。
    static func combining(_ registries: [CapabilityRegistry]) -> CapabilityRegistry {
        CapabilityRegistry(definitions: registries.flatMap(\.definitions)) { invocation in
            for registry in registries where registry.definition(named: invocation.name) != nil {
                return await registry.execute(invocation)
            }
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "不支持名为 \(invocation.name) 的工具。"),
                isError: true
            )
        }
    }
}
