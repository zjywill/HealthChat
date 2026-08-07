import SwiftUI

struct ChatView: View {
    @State private var model = ChatViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.messages) { message in
                        MessageBubble(message: message)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("HealthChat")
            .toolbar {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("问问你的健康数据…", text: $model.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.send() }
            Button {
                model.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(model.isReplying)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(message.toolNotes, id: \.self) { note in
                    Label(note, systemImage: "heart.text.square")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.text.isEmpty ? "…" : message.text)
            }
            .padding(10)
            .background(
                message.role == .user ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.fill.tertiary),
                in: RoundedRectangle(cornerRadius: 16)
            )
            if message.role == .assistant { Spacer(minLength: 48) }
        }
    }
}

#Preview {
    ChatView()
}
