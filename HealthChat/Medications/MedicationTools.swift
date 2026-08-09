import Foundation
import AgentRuntime

/// 用药与补剂的三个工具。
///
/// **写是主路径,不是辅路径。** 这和记忆里 `remember` 的地位不一样:记忆的多数条目靠会话结束
/// 后的抽取补上,而这张表的每一条都产生自一次明确的问答("我试试这个吧"),用户当场就该看见
/// 它落下了——等他关掉 app 再由后台补记,他无从知道到底记没记住。
///
/// `update_medication` 是闭环的另一半。没有它,`outcome` 那一列永远是空的——而那正是这张表
/// 最值钱的一列(见 `MedicationItem.outcome`)。
enum MedicationTools {
    static let listToolName = "list_medications"
    static let logToolName = "log_medication"
    static let updateToolName = "update_medication"

    /// - Parameter allowsWrites: 隐私会话传 false。只挂读的那一个。
    static func registry(
        store: MedicationStore = .shared,
        allowsWrites: Bool = true
    ) -> CapabilityRegistry {
        var definitions = [listDefinition]
        if allowsWrites {
            definitions.append(contentsOf: [logDefinition, updateDefinition])
        }

        return CapabilityRegistry(definitions: definitions) { invocation in
            switch invocation.name {
            case listToolName:
                return await list(store: store)
            case logToolName where allowsWrites:
                return await log(invocation, store: store)
            case updateToolName where allowsWrites:
                return await update(invocation, store: store)
            default:
                return CapabilityExecutionResult(
                    output: .init(kind: .text, text: "不支持名为 \(invocation.name) 的工具。"),
                    isError: true
                )
            }
        }
    }

    // MARK: - 定义

    private static var listDefinition: CapabilityDefinition {
        CapabilityDefinition(
            name: listToolName,
            description: """
            读用户记下的全部用药与补剂。系统提示里已经有一份精简名单，\
            只在需要名单上没有的细节时调用：他什么时候开始吃的、当初为什么吃、\
            他自己写的效果评价全文，或者名单因为太长被裁掉的那几条。\
            只是想知道他在吃什么，直接看系统提示里那份，不用调这个。
            """,
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": .bool(false)
            ]),
            strictPreferred: false
        )
    }

    /// 状态枚举在两个工具里都要用一遍,拆出来一份。
    private static var statusValues: RuntimeJSONValue {
        .array(MedicationStatus.allCases.map { RuntimeJSONValue.string($0.rawValue) })
    }

    private static var logDefinition: CapabilityDefinition {
        // 逐条拆开写不是风格问题:整块字面量嵌到三层,编译器就开始超时。
        let name: RuntimeJSONValue = .object([
            "type": "string",
            "description": "药或补剂的名字，用他说的那个叫法，不超过 20 个字"
        ])
        let status: RuntimeJSONValue = .object([
            "type": "string",
            "description": .string(
                "cannotTake 过敏或不能吃、ongoing 长期在吃、asNeeded 需要时才吃、tried 试过之后的结论"
            ),
            "enum": statusValues
        ])
        let when: RuntimeJSONValue = .object([
            "type": "string",
            "description": "什么情况下吃，如「头疼时」「每天早上」「冬天」。不知道就留空"
        ])
        let reason: RuntimeJSONValue = .object([
            "type": "string",
            "description": "为什么吃，或者谁让他吃的。一句话，不超过 30 个字"
        ])
        let followUpDays: RuntimeJSONValue = .object([
            "type": "integer",
            "description": .string(
                "他是刚开始试这个东西时传：几天后回头问他有没有用，范围 3–180。"
                    + "补剂见效慢，给长一点。已经吃了很久的不用传"
            ),
            "minimum": 3,
            "maximum": 180
        ])
        let properties: [String: RuntimeJSONValue] = [
            "name": name,
            "status": status,
            "when": when,
            "reason": reason,
            "followUpDays": followUpDays
        ]
        let schema: RuntimeJSONValue = .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array([.string("name"), .string("status")]),
            "additionalProperties": .bool(false)
        ])

        return CapabilityDefinition(
            name: logToolName,
            description: """
            把一样药或补剂记进用户的清单。在他说出自己和某样东西的关系时调用：\
            决定开始吃、已经在吃、需要时会吃、对某样东西过敏或不能吃。\
            同名的会覆盖原来那条，不会重复。\
            只是在讨论一样东西、他还没说要不要吃，不要记。剂量不要记进来。
            """,
            inputSchema: schema,
            strictPreferred: false
        )
    }

    private static var updateDefinition: CapabilityDefinition {
        let name: RuntimeJSONValue = .object([
            "type": "string",
            "description": "清单里那一条的名字"
        ])
        let outcome: RuntimeJSONValue = .object([
            "type": "string",
            "description": "他自己说的效果，用他的说法写，一句话不超过 30 个字"
        ])
        let status: RuntimeJSONValue = .object([
            "type": "string",
            "description": "关系变了才传：试过之后有结论就是 tried，开始长期吃是 ongoing",
            "enum": statusValues
        ])
        let properties: [String: RuntimeJSONValue] = [
            "name": name,
            "outcome": outcome,
            "status": status
        ]
        let schema: RuntimeJSONValue = .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false)
        ])

        return CapabilityDefinition(
            name: updateToolName,
            description: """
            更新清单里已有的一条：他说某样东西有用、没用、有不良反应，或者已经停了。\
            按名字找。**他给出结果时一定要记**——「试过没用」这件事下次才拦得住你再推荐一遍。
            """,
            inputSchema: schema,
            strictPreferred: false
        )
    }

    // MARK: - 执行

    private static func list(store: MedicationStore) async -> CapabilityExecutionResult {
        let items = await store.items()
        // 找不到**不报错**。「他还没记过什么」是一个有效答案,模型据此就该照常回答;报成错误
        // 它会以为工具坏了,换个说法再试一次,白花一轮(同 `search_sessions`)。
        guard !items.isEmpty else {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "用户还没有记下任何药或补剂。")
            )
        }
        return CapabilityExecutionResult(output: .init(kind: .text, text: render(items)))
    }

    private static func log(
        _ invocation: CapabilityInvocation,
        store: MedicationStore
    ) async -> CapabilityExecutionResult {
        let input = try? RuntimeJSONValue.decode(from: invocation.input)
        let name = (input?["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let status = input?["status"]?.stringValue.flatMap(MedicationStatus.init(rawValue:))
        else {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "参数不全：需要 name 和 status。"),
                isError: true
            )
        }

        let followUpAt = input?["followUpDays"]?.intValue.map {
            Date().addingTimeInterval(Double(min(max($0, 3), 180)) * 86_400)
        }
        let item = MedicationItem(
            name: String(name.prefix(20)),
            status: status,
            when: clipped(input?["when"]?.stringValue, 30),
            reason: clipped(input?["reason"]?.stringValue, 30),
            // `.asked` 而不是 `.manual`:他开口说了的东西,界面上要能标出「你让我记的」。
            origin: .asked,
            followUpAt: followUpAt,
            startedAt: status == .ongoing || status == .asNeeded ? Date() : nil
        )

        do {
            _ = try await store.add(item)
            var text = "已记下：\(item.name)（\(status.title)）"
            if followUpAt != nil { text += "，说好过一阵子回头问他有没有用" }
            return CapabilityExecutionResult(output: .init(kind: .text, text: text + "。"))
        } catch {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "没能记下来：\(error.localizedDescription)"),
                isError: true
            )
        }
    }

    private static func update(
        _ invocation: CapabilityInvocation,
        store: MedicationStore
    ) async -> CapabilityExecutionResult {
        let input = try? RuntimeJSONValue.decode(from: invocation.input)
        let name = (input?["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "参数不全：需要 name。"),
                isError: true
            )
        }

        let status = input?["status"]?.stringValue.flatMap(MedicationStatus.init(rawValue:))
        let outcome = input?["outcome"]?.stringValue

        do {
            let updated = try await store.update(
                name: name,
                status: status,
                outcome: outcome.map { String($0.prefix(30)) }
            )
            guard let updated else {
                // 匹配不上就把现有的名字列出来。只回一句「没找到」的话,模型只能瞎猜下一个
                // 写法,一次要么放弃、要么再白调两轮。
                let names = await store.items().map(\.name)
                let listing = names.isEmpty ? "（清单是空的）" : names.joined(separator: "、")
                return CapabilityExecutionResult(
                    output: .init(
                        kind: .text,
                        text: "清单里没有叫「\(name)」的。现有的是：\(listing)。"
                            + "确实是新的一样东西就用 \(logToolName) 记。"
                    ),
                    isError: true
                )
            }
            return CapabilityExecutionResult(
                output: .init(
                    kind: .text,
                    text: "已更新：\(updated.name)（\(updated.status.title)）"
                        + (updated.outcome.isEmpty ? "" : "，记的是「\(updated.outcome)」") + "。"
                )
            )
        } catch {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "没能更新：\(error.localizedDescription)"),
                isError: true
            )
        }
    }

    // MARK: - 渲染

    /// 不是 private:输出格式有测试盯着。
    static func render(_ items: [MedicationItem], now: Date = Date()) -> String {
        var lines: [String] = []
        for status in MedicationStatus.allCases {
            let matching = items.filter { $0.status == status }
            guard !matching.isEmpty else { continue }
            lines.append("【\(status.title)】")
            for item in matching {
                lines.append("- \(item.name)")
                append(&lines, "什么情况下吃", item.when)
                append(&lines, "为什么吃", item.reason)
                // 他自己的评价排在一般说明前面:一般说明模型随时能重写一遍,这一句只有他知道。
                append(&lines, "他自己的评价", item.outcome)
                append(&lines, "一般说明（自动生成，非医嘱）", item.brief)
                append(&lines, "备注", item.note)
                if let startedAt = item.startedAt {
                    append(&lines, "开始时间", dateLabel(startedAt))
                }
                if let followUpAt = item.followUpAt {
                    append(
                        &lines,
                        "回访",
                        followUpAt <= now ? "说好回头问的时间已经到了" : "\(dateLabel(followUpAt)) 回头问"
                    )
                }
            }
        }
        // 和记忆块末尾那句同源,但这里更要紧:记忆里顶多一句易腐的说法,这里错一次就是剂量。
        lines.append(
            "以上都是用户自己记的，不是完整病历，也不是医嘱。"
                + "不要据此建议他调整剂量、停药或换药；他明确不能吃的绝对不要推荐。"
        )
        return lines.joined(separator: "\n")
    }

    private static func append(_ lines: inout [String], _ label: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append("  \(label)：\(trimmed)")
    }

    private static func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month(.defaultDigits).day())
    }

    private static func clipped(_ value: String?, _ limit: Int) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(limit))
    }
}
