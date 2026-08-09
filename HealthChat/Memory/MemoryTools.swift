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
    /// - Parameter currentSessionId: 跨会话召回要排掉正在进行的这条,否则模型会把自己刚说过的
    ///   话当成「上次」读回来。
    static func healthChat(
        allowsMemoryWrites: Bool = true,
        memoryStore: MemoryStore = .shared,
        sessionStore: SessionStore = .shared,
        currentSessionId: UUID? = nil
    ) -> CapabilityRegistry {
        var registries = [HealthTools.registry]
        // 跨会话召回归在同一个开关下面。它和记忆是同一件事的两半——一个记「关于他的长期事实」,
        // 一个找回「那次聊出来的结论」;关掉记忆的人不会指望 Vana 还在引用他上个月说过的话。
        // 隐私会话照样能**读**:承诺的是不往盘上留痕迹,不是失忆,而且它自己从不落盘,
        // 天然不在别人的索引里。
        if EngineSettings.memoryEnabled {
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
