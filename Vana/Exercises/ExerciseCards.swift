import SwiftUI

/// 回复下面那排动作卡。
///
/// **默认收起,只露图和名字。** 同附件那条(「一份化验单几十行,摊开会把他自己问的那句话
/// 推到屏幕外面去」):三个动作的完整步骤铺开有大半屏,而用户此刻多半是先扫一眼图确认
/// 「哦是这个动作」。要照着做的时候再点开。
struct ExerciseCardList: View {
    let moves: [ExerciseMove]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(moves) { move in
                ExerciseCard(move: move)
            }
        }
    }
}

private struct ExerciseCard: View {
    let move: ExerciseMove

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                header
            }
            .buttonStyle(.plain)

            if isExpanded {
                details
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        // 展开动画挂在会动的那个视图上,不用 withAnimation 全局扫一遍——
        // 那一下会把闭包式 destination 的 NavigationLink 丢掉(`MedicationDetailView` 踩过)。
        .animation(.snappy(duration: 0.22), value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ExerciseFigure(move: move)
                .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 3) {
                Text(move.zh)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text(move.part)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(move.gear)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
        }
        .padding(12)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isExpanded ? "收起步骤" : "展开步骤")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(move.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(step)
                            .font(.subheadline)
                    }
                }
            }
            labelled(String(localized: "要领"), move.cue, tint: .green)
            // 禁忌那一行永远显示,不折叠在更深的一层里。它是这张卡上唯一一句可能拦住伤害的话。
            labelled(String(localized: "什么情况别做"), move.avoid, tint: .orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled(_ title: String, _ text: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// 图。两张时交叉淡入——两态本来就是同一个动作的起止,一张静图说不出方向。
///
/// 关掉动效时并排显示两张:那时候「会动」本来就不是可用的信息通道,而两张并排仍然说得清
/// 先后。素材是白底的,所以图这一层永远垫一块白,深色模式下也不让它糊成一团。
private struct ExerciseFigure: View {
    let move: ExerciseMove

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.white)
            content.padding(4)
        }
        .accessibilityElement()
        .accessibilityLabel("\(move.zh)的动作图示")
    }

    @ViewBuilder
    private var content: some View {
        let names = move.imageNames
        if names.count > 1 && !reduceMotion {
            TimelineView(.periodic(from: .now, by: 1.3)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 1.3)
                figure(names[step % names.count])
                    .id(step % names.count)
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))
            }
        } else if names.count > 1 {
            HStack(spacing: 2) {
                ForEach(names, id: \.self) { figure($0) }
            }
        } else if let name = names.first {
            figure(name)
        }
    }

    private func figure(_ name: String) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
    }
}
