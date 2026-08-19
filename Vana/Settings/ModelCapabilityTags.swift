import SwiftUI
import AIKit

/// 一个模型能做什么,用几颗小标签说清。
///
/// **只标那些会改变 app 行为的能力**,不是把 catalog 里的字段抄一遍。判据是「这一项不同,
/// 用户在这个 app 里看到的东西会不一样吗」:
///
/// - 看图 → 决定「照片原图」那一节生不生效(`PhotoImagePolicy`),以及拍一张没有文字的
///   照片能不能问出答案。
/// - 思考 → 决定「回答前先思考」那个开关是不是空的。不支持思考的模型上那个开关照常能拨,
///   而拨了什么都不会发生。
/// - 不支持工具 → 这个 app 在它身上基本是废的:健康数据全靠工具调用读。内置目录已经把它们
///   滤掉了(`CloudCatalog.models`),但从服务端拉回来的和手填的模型 ID 没人滤——那正是
///   用户最需要被提醒一句的地方,所以这颗是**警告色**,而且写的是后果不是能力
///   (「读不到健康数据」而不是「不支持 tool call」)。
///
/// 上下文和输出长度不做成标签:它们本来就在副标题那一行里,而且是连续量,一颗标签说不清。
struct ModelCapabilityTags: View {
    let model: ModelInfo

    var body: some View {
        // 一个都没有时整个不出现(比如手填的模型 ID,目录里查不到任何信息)。
        // 摆一排空标签比不摆更让人以为哪儿没画完。
        if !tags.isEmpty {
            HStack(spacing: 5) {
                ForEach(tags, id: \.title) { tag in
                    // **不用 `Label`。** 它给图标和文字之间留的是正文那一档的间距,
                    // 两个字的标签会被撑成一颗宽出一倍的药丸(踩过)。这里要的是一颗
                    // 贴着字的小徽章,间距得自己给。
                    HStack(spacing: 2.5) {
                        Image(systemName: tag.icon)
                            .font(.system(size: 9, weight: .semibold))
                        Text(tag.title)
                            .font(.caption2)
                    }
                    .foregroundStyle(tag.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        tag.tint.opacity(0.12),
                        in: .rect(cornerRadius: 5, style: .continuous)
                    )
                }
            }
            // 一颗颗读出来太碎。合成一句,而且顺序和屏幕上一致。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tags.map(\.title).joined(separator: "，"))
        }
    }

    private struct Tag {
        let title: String
        let icon: String
        let tint: Color
    }

    private var tags: [Tag] {
        var tags: [Tag] = []
        if model.supportsVision {
            tags.append(Tag(title: String(localized: "看图"), icon: "eye", tint: .accentColor))
        }
        if model.supportsReasoning {
            tags.append(Tag(title: String(localized: "思考"), icon: "sparkles", tint: .purple))
        }
        // 排在最后但最要紧。放前面会把两颗中性标签挤到看不见,而这一句是「这个模型在这个
        // app 里基本用不了」——它该被读成一句警告,不是一项参数。
        //
        // 徽章上只写这一项**能力**,后果留给旁边那行说明(选模型那一页的 footer 写着
        // 「不支持的模型读不到健康数据」)。一颗七个字的徽章排在另外两颗两个字的旁边,
        // 读起来不像同一套东西,而它本来就该和它们并排。
        if !model.supportsTools {
            tags.append(Tag(title: String(localized: "不支持工具"), icon: "exclamationmark.triangle.fill", tint: .orange))
        }
        return tags
    }
}

extension ModelCapabilityTags {
    /// 按 id 找出目录里那一份再标。找不到就什么都不显示——手填的模型 ID、比目录新的模型
    /// 都会走到这儿,而**猜一个能力标出去比不标严重得多**:标着「看图」却发一张图过去,
    /// 换回来的是一个 400。
    @ViewBuilder
    static func forModel(_ modelId: String, in providerId: String) -> some View {
        if let info = ProviderCatalog.model(modelId, provider: providerId)?.1 {
            ModelCapabilityTags(model: info)
        }
    }
}
