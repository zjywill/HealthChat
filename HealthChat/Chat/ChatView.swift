import SwiftUI

struct ChatView: View {
    @State private var model = ChatViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if model.isLoadingConversation {
                            ProgressView("正在载入对话")
                                .padding(.top, 40)
                        } else if model.messages.isEmpty {
                            WelcomeCard(
                                setupGuidance: model.engineGuidance,
                                onSelectQuestion: model.send
                            )
                            .padding(.top, 24)
                        } else {
                            ForEach(model.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages) {
                    guard let id = model.messages.last?.id else { return }
                    if reduceMotion {
                        proxy.scrollTo(id, anchor: .bottom)
                    } else {
                        withAnimation(.smooth(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("HealthChat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                NavigationLink {
                    SettingsView(
                        canClearConversation: !model.messages.isEmpty && !model.isReplying,
                        onClearConversation: model.clearConversation
                    )
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
            .onAppear {
                model.refreshEngineAvailability()
            }
            .task {
                do {
                    try await HealthStore.shared.requestAuthorization()
                } catch {
                    print("HealthKit 授权请求失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("问问你的健康数据…", text: $model.input, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { model.send() }
                .accessibilityLabel("消息")

            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(
                model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isReplying
                    || model.isLoadingConversation
            )
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 52)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                ForEach(message.toolNotes, id: \.self) { note in
                    Label(note, systemImage: "heart.text.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(displayText)
                    .foregroundStyle(message.role == .user ? .white : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel(
                        message.text.isEmpty
                            ? "正在回复"
                            : message.text
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        message.role == .user
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }

            if message.role == .assistant {
                Spacer(minLength: 52)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var displayText: AttributedString {
        let text = message.text.isEmpty ? "…" : message.text
        guard message.role == .assistant else {
            return AttributedString(text)
        }
        return (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

private struct WelcomeCard: View {
    let setupGuidance: String?
    let onSelectQuestion: (String) -> Void

    private let questions = [
        ("moon.stars", "我最近一周睡得怎么样？"),
        ("figure.walk", "我这周的活动量够吗？"),
        ("heart.text.square", "结合最近数据，我的状态如何？")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.pink)
                    .accessibilityHidden(true)

                Text("从你的健康数据开始")
                    .font(.title2.weight(.semibold))

                Text("你可以直接询问步数、睡眠、静息心率、锻炼、体重和体脂趋势。HealthChat 只读取你授权的数据，不会修改健康记录。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("试着问")
                    .font(.headline)

                ForEach(questions, id: \.1) { icon, question in
                    Button {
                        onSelectQuestion(question)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)

                            Text(question)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)

                            Spacer(minLength: 8)

                            Image(systemName: "arrow.up")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("提问：\(question)")
                }
            }

            Label("健康分析仅供参考，不能替代专业医疗建议。", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let setupGuidance {
                Label(setupGuidance, systemImage: "gearshape")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    ChatView()
}
