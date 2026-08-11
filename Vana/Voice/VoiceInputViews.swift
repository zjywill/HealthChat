import SwiftUI
import UIKit

/// 输入框旁边那颗「按住说话」。
///
/// **按住,不是点一下切换。** 点一下开始、再点一下结束的那种,用户永远要记着自己现在是不是
/// 在录;而按住说话的那几秒里,手指本身就是状态显示。松手就结束,这一点不会有第二种理解。
///
/// **手指划开就是取消**,和微信一样。这个 app 里松手也只是把字填进输入框、不发送,所以取消
/// 的代价本来就不高;但一个按住说话的按钮如果吃掉「划开」这个动作,对已经形成肌肉记忆的人
/// 来说就是坏的。
struct VoiceInputButton: View {
    var isListening: Bool
    @Binding var isCancelling: Bool
    let onPress: () -> Void
    /// 松手。`cancelled` 为 true 表示手指划开了,这一段不要了。
    let onRelease: (_ cancelled: Bool) -> Void

    /// 手指离开按钮这么远就算划开了。
    private static let cancelDistance: CGFloat = 72

    @State private var isPressing = false

    var body: some View {
        Image(systemName: isCancelling ? "xmark" : "mic.fill")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(isListening ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: 34, height: 34)
            .background(background, in: Circle())
            .scaleEffect(isListening ? 1.12 : 1)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .animation(.smooth(duration: 0.18), value: isListening)
            .animation(.smooth(duration: 0.18), value: isCancelling)
            .gesture(press)
            .accessibilityLabel("按住说话")
            .accessibilityHint("按住说话，松开把识别出来的文字填进输入框，不会直接发送")
            // VoiceOver 下按住不放是做不到的,给一条能点的动作:开始 / 结束各按一次。
            .accessibilityAction(named: isListening ? "结束说话" : "开始说话") {
                if isListening {
                    onRelease(false)
                } else {
                    onPress()
                }
            }
    }

    private var background: AnyShapeStyle {
        if isCancelling {
            AnyShapeStyle(Color(.systemRed))
        } else if isListening {
            AnyShapeStyle(Color.accentColor)
        } else {
            AnyShapeStyle(.fill.tertiary)
        }
    }

    /// `minimumDistance: 0` 才是「按下就开始」:用 `LongPressGesture` 的话前半秒是死的,
    /// 而用户按下去的那一刻就已经在说话了。
    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressing {
                    isPressing = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onPress()
                }
                let distance = hypot(value.translation.width, value.translation.height)
                let cancelling = distance > Self.cancelDistance
                if cancelling != isCancelling {
                    isCancelling = cancelling
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .onEnded { _ in
                isPressing = false
                let cancelled = isCancelling
                isCancelling = false
                onRelease(cancelled)
            }
    }
}

/// 录音时输入框上方那一条:波形 + 一句话说清松手会发生什么。
///
/// 波形画的是**刚才这一秒的音量**,不是一段装饰动画。理由和附件那一排显示「识别到了多少行」
/// 一样:用户得看得出这一步到底收到声音了没有——没收到的时候(蒙着麦克风、外放正在响)
/// 一条不动的直线是唯一的线索,而一段永远在动的假动画会把它盖掉。
struct VoiceLevelStrip: View {
    var level: Float
    var isCancelling: Bool

    /// 留多长一段历史。20 格 × 50ms ≈ 刚才那一秒。
    private static let barCount = 20

    @State private var history: [Float] = Array(repeating: 0, count: VoiceLevelStrip.barCount)

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(isCancelling ? AnyShapeStyle(Color(.systemRed)) : AnyShapeStyle(Color.accentColor))
                        .frame(width: 3, height: 4 + CGFloat(value) * 20)
                }
            }
            .frame(height: 24)
            .animation(.linear(duration: 0.05), value: history)

            Text(isCancelling ? "松开取消" : "松开填进输入框，不会直接发送")
                .font(.footnote)
                .foregroundStyle(isCancelling ? AnyShapeStyle(Color(.systemRed)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .onChange(of: level, initial: true) { _, newValue in
            history.removeFirst()
            history.append(newValue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在听")
    }
}
