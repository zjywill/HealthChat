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
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                thumbnail
                    .frame(width: 68, height: 68)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if draft.isRecognizing {
                            ZStack {
                                Color.black.opacity(0.35)
                                ProgressView().tint(.white)
                            }
                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
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
        .accessibilityLabel("\(draft.documentName ?? "照片")，\(caption)")
        .accessibilityHint("打开可以核对和修改要发出去的文字")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let preview = draft.preview {
            Image(uiImage: preview)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            AttachmentDocumentTile(name: draft.documentName ?? "文件")
        }
    }

    private var caption: String {
        if draft.isRecognizing { return "识别中…" }
        if draft.failure != nil { return "读不出来" }
        guard draft.hasText else { return draft.isDocument ? "没有正文" : "没有文字" }
        let lines = draft.text.split(separator: "\n").count
        return draft.droppedLines > 0 ? "\(lines) 行·已截断" : "\(lines) 行"
    }
}

/// 发出去之前核对这一张。
///
/// **识别错一个小数点,在健康场景里不是「有点脏数据」。** 所以这段文字是可改的,而且改完
/// 发出去的就是他改的那一份。顺带也解决了截断那条:太长的时候他自己就能删掉不相关的几段。
struct AttachmentReviewView: View {
    let draft: DraftAttachment
    let onChangeText: (String) -> Void
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
                        Label(draft.documentName ?? "文件", systemImage: "doc.text")
                            .lineLimit(2)
                    }
                } footer: {
                    Text(draft.isDocument
                        ? "文件留在这台手机上，发给模型的只有下面这段文字。"
                        : "图片留在这台手机上，发给模型的只有下面这段文字。")
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

    private var footer: String {
        if let failure = draft.failure { return failure }
        guard draft.hasText else {
            return draft.isDocument
                ? "这份文件里没取到正文。里面如果是扫描件（整页都是图），先导出成 PDF 或者直接拍一张。"
                : "这张图里没认出文字。Vana 现在只能读照片里的字，看不了图像本身——一顿饭、一处皮疹这类还得用文字描述。"
        }
        if draft.droppedLines > 0 {
            return "太长了，后面 \(draft.droppedLines) 行没有带进来。删掉用不上的几段，再把要问的那几项留下。"
        }
        return draft.isDocument
            ? "改成什么样，发出去的就是什么样。用不上的段落可以直接删掉。"
            : "改成什么样，发出去的就是什么样。数值和单位值得对一眼。"
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
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(attachment.documentName ?? "照片")，点开看发出去的文字")
                }
            }

            if let attachment = attachments.first(where: { $0.id == expanded }) {
                Text(attachment.hasText
                    ? attachment.text
                    : (attachment.isDocument ? "这份文件里没有取到文字。" : "这张图里没有识别到文字。"))
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
