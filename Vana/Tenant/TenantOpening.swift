import Foundation

/// 家人成员的首屏:那句话和那三颗 chip。
///
/// **完全本地拼,一次模型调用都不发。** 机主那条路上首屏的两级(本地立刻出、模型润色了换掉)
/// 存在的理由是 `HealthSituation` 能算出「昨晚比常态少睡了 100 分钟」这种有内容的句子;家人
/// 这边根本没有那份数据——让模型为「他这儿只有一张用药表」润色一句,它会为了有话说而开始编。
/// 这和「没有触发点就不叫模型」是同一条规矩,顺带省掉一次调用。
enum TenantOpening {
    /// 首屏那句话。说清**这儿有什么、下一步能干什么**,不假装知道他的身体状况。
    static func quickSummary(for tenant: Tenant, medications: MedicationSnapshot) -> String {
        let name = tenant.displayName
        guard !medications.isEmpty else {
            return String(localized: "这里是\(name)的记录。拍一张\(name)的化验单或报告，或者先把\(name)在吃的药记下来。")
        }
        return String(localized: "\(name)的清单里记着 \(medications.items.count) 样东西。读不到\(name)的健康数据，要看具体数值就拍一张化验单给我。")
    }

    /// 三颗 chip。有清单和没清单是两种处境,给的下一步也该是两种。
    static func questions(for tenant: Tenant, medications: MedicationSnapshot) -> [SuggestedQuestion] {
        let name = tenant.displayName
        var questions: [SuggestedQuestion] = []
        if medications.isEmpty {
            questions.append(SuggestedQuestion(
                icon: "pills",
                text: String(localized: "把\(name)在吃的药记下来")
            ))
        } else {
            questions.append(SuggestedQuestion(
                icon: "pills",
                text: String(localized: "\(name)在吃的这些一起吃有问题吗")
            ))
            questions.append(SuggestedQuestion(
                icon: "exclamationmark.triangle",
                text: String(localized: "这几样有什么要注意的")
            ))
        }
        questions.append(SuggestedQuestion(
            icon: "doc.text.viewfinder",
            text: String(localized: "化验单上哪几项要重点看")
        ))
        if let ageBand = tenant.ageBand {
            questions.append(SuggestedQuestion(
                icon: "heart.text.square",
                text: String(localized: "\(ageBand.label)体检要重点查什么")
            ))
        }
        return Array(questions.prefix(3))
    }
}
