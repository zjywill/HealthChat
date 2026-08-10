import Foundation
import AgentRuntime

/// 这一轮工具挑中的动作。跟着 `AgentToolOutput.metadata` 走,卡片照着它渲染。
///
/// **卡片由工具返回的 id 决定,不认正文里的标记。** 让模型在回复里写
/// `[[动作:xxx]]` 的话,它迟早会编一个库里没有的名字出来——而正文写着「参考下面的图示」、
/// 底下却没有那一张,是这套东西最糟的一种失灵。闭集 + 工具锚定让它不可能发生。
struct ExerciseSelection: Codable, Equatable, Sendable {
    let moveIDs: [String]

    static func encodeForToolMetadata(_ selection: ExerciseSelection) -> RuntimeJSONValue? {
        guard let data = try? JSONEncoder().encode(selection) else { return nil }
        return try? JSONDecoder().decode(RuntimeJSONValue.self, from: data)
    }

    /// 健康查询的 metadata 装的是 `HealthReport`,两边互相解不出来(必填键不一样),
    /// 所以同一个字段上并存是安全的。
    static func decode(fromToolMetadata metadata: RuntimeJSONValue?) -> ExerciseSelection? {
        guard let metadata else { return nil }
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return try? JSONDecoder().decode(ExerciseSelection.self, from: data)
    }
}

/// 拉伸与简单锻炼:从打进包里的闭集里挑几个动作,卡片带图显示在这条回复下面。
///
/// **它补的不是知识,是表达。** 模型本来就知道该拉哪儿,只是「弓步下沉,后腿膝盖着地」
/// 这几个字对没练过的人是一串听不懂的词。所以工具返回的是名字和步骤,**图不进上下文**
/// ——图对模型是零信息,对预算是纯损失(同「逐小时序列只画在面板里」)。
enum ExerciseTools {
    static let suggestToolName = "suggest_exercises"

    /// 可以被排除的关节。用户说过哪儿不好,带那个关节的整组根本不返回。
    static let joints = ["颈", "肩", "肘", "腕", "腰", "髋", "膝", "踝"]

    static func registry(library: ExerciseLibrary = .shared) -> CapabilityRegistry {
        CapabilityRegistry(definitions: [suggestDefinition(library: library)]) { invocation in
            guard invocation.name == suggestToolName else {
                return CapabilityExecutionResult(
                    output: .init(kind: .text, text: "不支持名为 \(invocation.name) 的工具。"),
                    isError: true
                )
            }
            return suggest(invocation, library: library)
        }
    }

    // MARK: - 定义

    private static func suggestDefinition(library: ExerciseLibrary) -> CapabilityDefinition {
        let scene: RuntimeJSONValue = .object([
            "type": "string",
            "description": "从哪一类里挑",
            "enum": .array(library.scenes.map(RuntimeJSONValue.string))
        ])
        let excludeJoint: RuntimeJSONValue = .object([
            "type": "array",
            "description": .string(
                "用户说过不好、受过伤、做不了的关节。带这些关节的动作一个都不会返回。"
                    + "记忆或用药表里提到过的也要带上"
            ),
            "items": .object([
                "type": "string",
                "enum": .array(joints.map(RuntimeJSONValue.string))
            ])
        ])
        let noFloor: RuntimeJSONValue = .object([
            "type": "boolean",
            "description": "他不方便躺下或跪地时传 true，比如在办公室、在外面，或者他说了起身困难"
        ])
        let count: RuntimeJSONValue = .object([
            "type": "integer",
            "description": "要几个，1–4，默认 3",
            "minimum": 1,
            "maximum": 4
        ])
        let schema: RuntimeJSONValue = .object([
            "type": "object",
            "properties": .object([
                "scene": scene,
                "excludeJoint": excludeJoint,
                "noFloor": noFloor,
                "count": count
            ]),
            "required": .array([.string("scene")]),
            "additionalProperties": .bool(false)
        ])

        return CapabilityDefinition(
            name: suggestToolName,
            description: """
            在用户问「做点什么」「怎么拉伸」「有什么动作」，\
            或者你打算建议他活动一下的时候调用。\
            返回的动作会带图示显示在你这条回复下面，用户能照着做。\
            **只能推荐这个工具返回的动作**：库以外的动作没有图，说了他也不知道怎么做。\
            疼痛、受伤、术后、孕期不要调这个，先让他去看医生。
            """,
            inputSchema: schema,
            strictPreferred: false
        )
    }

    // MARK: - 执行

    private static func suggest(
        _ invocation: CapabilityInvocation,
        library: ExerciseLibrary
    ) -> CapabilityExecutionResult {
        let input = try? RuntimeJSONValue.decode(from: invocation.input)
        let scene = input?["scene"]?.stringValue ?? ""
        let excluded = input?["excludeJoint"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let noFloor = input?["noFloor"]?.boolValue ?? false
        let count = input?["count"]?.intValue ?? 3

        let picked = library.suggest(
            scene: scene,
            excludeJoints: excluded,
            avoidsFloor: noFloor,
            limit: count
        )

        // 挑不到**不是错误**(同 `search_sessions` / `web_search` 搜不到那条)。报成错误的话
        // 模型会以为工具坏了,换个说法再调一次,白花一轮。
        guard !picked.isEmpty else {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: emptyText(scene: scene, excluded: excluded))
            )
        }

        return CapabilityExecutionResult(
            output: .init(
                kind: .text,
                text: modelText(picked),
                metadata: ExerciseSelection.encodeForToolMetadata(
                    ExerciseSelection(moveIDs: picked.map(\.id))
                )
            )
        )
    }

    static func emptyText(scene: String, excluded: [String]) -> String {
        var text = "动作库里「\(scene)」这一类"
        if excluded.isEmpty {
            text += "暂时没有可推荐的动作。"
        } else {
            text += "里，避开\(excluded.joined(separator: "、"))之后没有剩下可推荐的动作。"
        }
        return text + "照实告诉用户这次没有能配图的动作，需要的话让他去问康复师或医生。不要自己编一个动作出来。"
    }

    /// 给模型的那一份。**只有名字、步骤、要领和禁忌,没有图**。
    static func modelText(_ moves: [ExerciseMove]) -> String {
        var lines = ["为用户挑了这 \(moves.count) 个动作，卡片（含图示）已经显示在你这条回复下面："]
        for (index, move) in moves.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \(move.zh)（\(move.part)；\(move.gear)）")
            lines.append(contentsOf: move.steps.map { "   - \($0)" })
            lines.append("   要领：\(move.cue)")
            lines.append("   什么情况别做：\(move.avoid)")
        }
        lines.append("")
        lines.append(footer)
        return lines.joined(separator: "\n")
    }

    /// 这三句是这个工具真正的产出,不是免责声明。有测试盯着。
    ///
    /// 少第一句,正文会把卡片上已经有的步骤再抄一遍,把用户自己问的那句话推到屏幕外面去。
    /// 少第二句,一个膝盖不好的人会拿到一组深蹲。少第三句,它会开始开处方。
    static let footer = """
        接下来：正文里不要把上面的步骤逐条复述一遍——卡片上已经有图和步骤了，\
        说清为什么挑这几个、他做的时候要注意什么就够了。\
        用户说过做不了的动作绝对不要提。\
        不要给次数、组数或者保持多少秒，让他按自己的感觉来，有不适就停。
        """
}
