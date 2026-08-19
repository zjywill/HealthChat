import SwiftUI

/// 一张附件的图。内存里那份优先,没有才去盘上取(见 `AttachmentImageCache`)。
///
/// 取不到就画一个占位:图可能因为写盘失败、或者原会话被删掉(分叉出来的那条和它共用文件)
/// 而不在了,但那条消息真正要紧的东西——识别出来的文字——一个字都没丢,所以这不是错误态。
struct AttachmentImageView: View {
    let attachment: ChatAttachment
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    Rectangle().fill(.fill.tertiary)
                    Image(systemName: attachment.isDocument ? "doc.text" : "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: attachment.id) {
            // 文件没有图,不必去问一次盘。
            guard !attachment.isDocument else { return }
            image = await AttachmentImageCache.shared.image(for: attachment)
        }
        .accessibilityHidden(true)
    }
}

/// 文件那一格:没有缩略图可看,那就把**它叫什么**摆在最显眼的位置。
///
/// 用户一次带三份文件时,认出哪份是哪份靠的就是名字——所以名字比图标要紧,给两行。
struct AttachmentDocumentTile: View {
    let name: String
    var size: CGFloat = 68

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 3)
        }
        .frame(width: size, height: size)
        .background(.fill.tertiary, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// 输入框上方那一排里的一张。
///
/// 缩略图之外一定要有一行字说识别到了什么:发出去的是**文字**不是图,只放一张缩略图的话,
/// 用户看不出这一步到底认到了没有,直到模型答非所问才发现。
struct AttachmentThumbnail: View {
    let draft: DraftAttachment
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        // 还在路上的那一格点不开:核对面板里会是一张空图加一个空编辑框,而他要核对的东西
        // 一秒之后才到。转圈本身已经说清了「等一下」。
        Button(action: { if !draft.isLoading { onOpen() } }) {
            VStack(alignment: .leading, spacing: 4) {
                thumbnail
                    .frame(width: 68, height: 68)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if draft.isRecognizing {
                            ZStack {
                                // 有图的时候压一层暗底,白圈才看得清;占位格底下本来就是空的,
                                // 再压一层只会变成一块黑。
                                if draft.preview != nil {
                                    Color.black.opacity(0.35)
                                    ProgressView().tint(.white)
                                } else {
                                    ProgressView()
                                }
                            }
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        }
                    }
                    // 这一张的原图要发出去。输入框上方那一行说的是总数,而单张是在核对面板里
                    // 翻的——不在格子上留个记号,他翻完回到这一排,屏幕上没有一个字变过。
                    .overlay(alignment: .bottomTrailing) {
                        if draft.sendsImage {
                            Image(systemName: "eye.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.black.opacity(0.5), in: .circle)
                                .padding(3)
                        }
                    }

                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(draft.failure == nil ? .secondary : Color.red)
                    .lineLimit(1)
                    .frame(width: 68, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    // 撑到 32:一颗 17pt 的图标按不中,而按错的后果是打开面板而不是删掉。
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .offset(x: 8, y: -8)
            .accessibilityLabel("移除这张照片")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(draft.documentName ?? "照片")，\(caption)"
            + (draft.sendsImage ? String(localized: "，原图会一起发出去") : ""))
        .accessibilityHint("打开可以核对和修改要发出去的文字")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let preview = draft.preview {
            Image(uiImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if draft.isLoading {
            // 还不知道是照片还是文件,所以这一格什么都不说,只留一个空底给上面那个圈。
            Rectangle().fill(.fill.tertiary)
        } else {
            AttachmentDocumentTile(name: draft.documentName ?? String(localized: "文件"))
        }
    }

    private var caption: String {
        // 「载入中」和「识别中」是两件事:前者是这张图还没读进来(相册在递、PDF 在渲染),
        // 后者是图已经在了、正在认字。合成一句的话,一份二十页的 PDF 会在「识别中」上停很久,
        // 而那时候根本还没开始识别。
        if draft.isLoading { return String(localized: "载入中…") }
        if draft.isRecognizing { return String(localized: "识别中…") }
        if draft.failure != nil { return String(localized: "读不出来") }
        guard draft.hasText else {
            return draft.isDocument ? String(localized: "没有正文") : String(localized: "没有文字")
        }
        let lines = draft.text.split(separator: "\n").count
        return draft.droppedLines > 0 ? String(localized: "\(lines) 行·已截断") : String(localized: "\(lines) 行")
    }
}

/// 发出去之前核对这一张。
///
/// **识别错一个小数点,在健康场景里不是「有点脏数据」。** 所以这段文字是可改的,而且改完
/// 发出去的就是他改的那一份。顺带也解决了截断那条:太长的时候他自己就能删掉不相关的几段。
struct AttachmentReviewView: View {
    let draft: DraftAttachment
    let onChangeText: (String) -> Void
    /// 这一张单独翻。整排一起翻的那颗在输入框上方(`ComposerBar.imageSendOffer`)——
    /// 一次拍三张菜让他点三下,是把一个决定拆成三份同样的劳动。
    ///
    /// nil 就是这个模型看不了图,那颗开关整个不出现:一颗按下去什么都不会改变的开关,
    /// 比没有这颗开关更糟。
    var onChangeSendsImage: ((Bool) -> Void)?
    /// 他设的是「每张都发原图」之类,可这个模型看不了图。
    ///
    /// **这一句必须有。** 没有它,他设过的那一档在这条会话里静静地不生效,而这一屏正是他
    /// 会来核对「发出去的到底是什么」的地方——上面写着「只发下面这段文字」,和他记得的设置
    /// 对不上,却没有一个字说是为什么。
    var visionUnavailableNote: String?
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var medicationDraft: MedicationDraft?
    @State private var savedMedication: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let preview = draft.preview {
                        Image(uiImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: 220)
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } else {
                        Label(draft.documentName ?? String(localized: "文件"), systemImage: "doc.text")
                            .lineLimit(2)
                    }
                } footer: {
                    // 这句话说的是**这一次到底会发生什么**,所以它跟着开关走。原来那句
                    // 「只发下面这段文字」在开了发图之后是假的,而这一屏的全部意义正是
                    // 让他在按发送之前看清发出去的是什么。
                    Text(footprint)
                }

                // **对任何一张读得出来的照片都开着**,认出字的也一样。默认那档不主动问它们
                // (`PhotoImagePolicy`),不等于他不许自己开——这一格正是「认不出字才发」
                // 写死之后固化掉的那一格。
                if let onChangeSendsImage, draft.canSendImage {
                    Section {
                        Toggle("让 Vana 直接看这张图", isOn: Binding(
                            get: { draft.sendsImage },
                            set: onChangeSendsImage
                        ))
                    } footer: {
                        // 两句话分开写:认不出字的那张,发图是**多给一件东西**;认出字的那张,
                        // 发图是**多交一份身份**,而文字已经够用了。说成同一句就是在劝他随手
                        // 把化验单发出去。
                        Text(draft.hasText
                            ? """
                                文字已经识别出来了，上面那段就够回答问题。原图上还有姓名、就诊号、\
                                医院和医生签名——真要发的话，它会一起发到你配置的模型服务上。
                                """
                            : """
                                本机一个字都没认出来。一顿饭、一处皮疹这类照片的信息本来就不是字，\
                                让模型直接看图才答得上——但那意味着这张照片本身会发到你配置的模型服务上。
                                """)
                    }
                }

                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .font(.callout)
                        .monospaced()
                } header: {
                    Text(draft.isDocument ? "文件里的文字" : "识别出的文字")
                } footer: {
                    Text(footer)
                }

                Section {
                    Button {
                        medicationDraft = MedicationDraft(recognizedText: text)
                    } label: {
                        Label("记入用药与补剂", systemImage: "pills")
                    }
                    .disabled(!draft.hasText)

                    Button(role: .destructive) {
                        onRemove()
                        dismiss()
                    } label: {
                        Label("不发这张", systemImage: "trash")
                    }
                    // Form 里 `.destructive` 只染文字,图标还跟着全局 tint 走——一个蓝色
                    // 垃圾桶配一行红字,看着像哪儿没画完。
                    .tint(.red)
                } footer: {
                    if let savedMedication {
                        Text("已记下「\(savedMedication)」。")
                    }
                }
            }
            .navigationTitle("核对识别结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            // 边改边回写。等到「完成」才回写的话,从上面滑下去关掉的那次修改会静静地丢掉,
            // 而他以为已经改好了。
            .onChange(of: text) { _, updated in onChangeText(updated) }
            .onAppear { text = draft.text }
            // 还在识别的时候就点进来了(那颗缩略图一直点得动)。不接这一下,识别完的文字
            // 落在 draft 上,而他眼前这个编辑框会一直空着——看起来就是没认出来。
            .onChange(of: draft.isRecognizing) { _, isRecognizing in
                guard !isRecognizing, text.isEmpty else { return }
                text = draft.text
            }
            .sheet(item: $medicationDraft) { editing in
                MedicationEditView(draft: editing, onSave: saveMedication)
            }
        }
    }

    /// 这一件到底有什么会离开这台手机。
    private var footprint: String {
        if draft.isDocument { return String(localized: "文件留在这台手机上，发给模型的只有下面这段文字。") }
        if draft.sendsImage {
            return String(localized: "这张照片本身会发到你配置的模型服务上。关掉下面那个开关，就只发识别出来的文字。")
        }
        let base = String(localized: "图片留在这台手机上，发给模型的只有下面这段文字。")
        // 他设过「每张都发原图」而这个模型看不了图时,上面那句和他记得的设置是对不上的。
        guard let visionUnavailableNote else { return base }
        return "\(base)\(visionUnavailableNote)"
    }

    private var footer: String {
        if let failure = draft.failure { return failure }
        guard draft.hasText else {
            if draft.sendsImage {
                return String(localized: "这张图里没认出文字，原图会随这句话一起发出去，让模型直接看。")
            }
            return draft.isDocument
                ? String(localized: "这份文件里没取到正文。里面如果是扫描件（整页都是图），先导出成 PDF 或者直接拍一张。")
                : String(localized: "这张图里没认出文字。Vana 现在只能读照片里的字——一顿饭、一处皮疹这类，可以打开上面那个开关让它直接看图。")
        }
        if draft.droppedLines > 0 {
            return String(localized: "太长了，后面 \(draft.droppedLines) 行没有带进来。删掉用不上的几段，再把要问的那几项留下。")
        }
        return draft.isDocument
            ? String(localized: "改成什么样，发出去的就是什么样。用不上的段落可以直接删掉。")
            : String(localized: "改成什么样，发出去的就是什么样。数值和单位值得对一眼。")
    }

    // MARK: - 记进用药表

    private func saveMedication(_ draft: MedicationDraft) {
        let item = draft.applied()
        Task {
            do {
                _ = try await MedicationStore.shared.add(item)
                savedMedication = item.name
                // 那句一般说明后台补,失败就空着——这条记录照常在。
                if item.brief.isEmpty {
                    let target = await MedicationStore.shared.item(named: item.name) ?? item
                    await MedicationBriefer.fill(target)
                }
            } catch {
                savedMedication = nil
                print("记入用药表失败：\(error.localizedDescription)")
            }
        }
    }
}

extension MedicationDraft {
    /// 拍药瓶 → 识别 → 落进用药表,是这个功能最值钱的一条流程,而那张表本来就缺一个快速录入
    /// 的入口。
    ///
    /// **只预填、不代填**:名字猜错了他当场就能改,而一条录错名字的用药记录会在往后每一次
    /// 建议里被读到——包括「他不能吃什么」那一组。
    init(recognizedText: String) {
        self.init(status: .ongoing)
        name = Self.guessedName(from: recognizedText)
        note = recognizedText
    }

    /// 猜个名字:第一行、去掉列分隔之后的第一格。
    ///
    /// 药瓶上最先被认出来的那一行几乎总是商品名(字最大,`RecognizedTextLayout` 又把它排在
    /// 最前面)。猜不准也无所谓——它落在一个可编辑的输入框里,不是直接存进表。
    static func guessedName(from text: String) -> String {
        let firstLine = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let firstCell = firstLine
            .components(separatedBy: RecognizedTextLayout.columnSeparator)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(firstCell.prefix(24))
    }
}

/// 气泡里那几张。缩略图在上,识别出来的文字收在一颗 chip 后面。
///
/// 文字**默认收起来**:一份化验单几十行,摊开在对话流里会把他自己问的那句话推到屏幕外面去。
/// 但它必须点得开——发出去的是这段字,而模型接下来说的每一句都建立在它上面。
struct MessageAttachmentsView: View {
    let attachments: [ChatAttachment]

    @State private var expanded: ChatAttachment.ID?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    Button {
                        expanded = expanded == attachment.id ? nil : attachment.id
                    } label: {
                        if let name = attachment.documentName {
                            AttachmentDocumentTile(name: name, size: 76)
                        } else {
                            AttachmentImageView(attachment: attachment)
                                .frame(width: 76, height: 76)
                                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                                // 原图真的发出去了的那几张要留下一个记号。发之前那一行提示
                                // 只在输入框上方存在几秒钟,而「这张照片交出去过」是他几个月
                                // 之后翻回来还该看得见的一件事。
                                .overlay(alignment: .bottomTrailing) {
                                    if attachment.sendsImage {
                                        Image(systemName: "eye.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.white)
                                            .padding(4)
                                            .background(.black.opacity(0.5), in: .circle)
                                            .padding(4)
                                    }
                                }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(attachment.sendsImage
                        ? "照片，原图已发给模型，点开看随附的文字"
                        : "\(attachment.documentName ?? String(localized: "照片"))，点开看发出去的文字")
                }
            }

            if let attachment = attachments.first(where: { $0.id == expanded }) {
                Text(attachment.hasText
                    ? attachment.text
                    : attachment.isDocument ? "这份文件里没有取到文字。"
                    : attachment.sendsImage ? "这张图里没有识别到文字，原图发给了模型。"
                    : "这张图里没有识别到文字。")
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.smooth(duration: 0.2), value: expanded)
    }
}
