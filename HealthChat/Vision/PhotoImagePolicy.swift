import Foundation

/// 拍进来的照片,**原图**默认要不要跟着发给模型。
///
/// 这三档管的只是**默认值**:模型看得了图的时候,每一张在核对面板里都还能单独翻
/// (`ChatAttachment.sendsImage`)。所以 `.textOnly` 不是一道锁,是「别主动问我」。
///
/// 为什么要有这个选择,而不是把「认不出字才发」写死:那条规则替用户做完了两个决定,而 app
/// 只判得了其中一个。「这张图里有没有字」是客观的,判得准;「他愿不愿意把这张照片交出去」
/// 判不了——只拍饭菜的人希望每张都直接发,只拍化验单的人一张都不想发,而中间那档对他们俩
/// 都不对。
///
/// 默认停在 `.askWhenNoText`:三档里只有它不要求用户先想清楚一件事,而它替他挡住的正是
/// 代价最大的那一次(化验单上有姓名、就诊号、医院和条码,而那张照片本机认得出字,
/// 这一档连问都不会问)。
enum PhotoImagePolicy: String, CaseIterable, Identifiable, Sendable {
    /// 只发识别出来的文字。要发原图得自己去那张图的核对面板里打开。
    case textOnly
    /// 本机一个字都没认出来时,在输入框上方问一句。**默认**。
    case askWhenNoText
    /// 每张照片都带上原图。
    case always

    var id: String { rawValue }

    var name: String {
        switch self {
        case .textOnly: "只发文字"
        case .askWhenNoText: "认不出字时问一句"
        case .always: "每张都发原图"
        }
    }

    /// 选中之后底下那句话。**说的是这一档会发生什么,不是它有多安全**——三档各有各的代价,
    /// 含糊其辞才是真的逗人玩。
    var summary: String {
        switch self {
        case .textOnly:
            "照片永远不出这台手机。认不出字的那些（一顿饭、一处皮疹）Vana 就答不上来，"
                + "需要的话在那张图的核对面板里单独打开。"
        case .askWhenNoText:
            "只有本机一个字都没认出来的照片才问你一句，你点了才发。"
                + "化验单、药盒这些认得出字的连问都不会问——它们的文字已经够回答问题了。"
        case .always:
            "每张照片的原图都会发到你配置的模型服务上，包括化验单——那上面有姓名、就诊号、"
                + "医院和医生签名，而回答问题通常只需要那几行数值。"
        }
    }

    /// 刚拍进来的一张照片,默认翻不翻。
    ///
    /// `.askWhenNoText` 在这儿是 false:那一档的意思是**问一句**,不是替他答应。
    var sendsImageByDefault: Bool { self == .always }

    /// 要不要主动在输入框上方问他。
    ///
    /// `.always` 也要出那一行——它说的是「这几张原图会发出去 · 撤销」。这一档下面唯一
    /// 不能少的就是这句话:他自己设过一次,但每一次真的要交出去之前仍然该看得见。
    func offers(hasText: Bool) -> Bool {
        switch self {
        case .textOnly: false
        case .askWhenNoText: !hasText
        case .always: true
        }
    }
}
