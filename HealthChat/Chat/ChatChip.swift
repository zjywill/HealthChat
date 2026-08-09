import SwiftUI

extension View {
    /// 对话流里那种 chip 的外观:思考过程、工具调用、记住了什么。
    ///
    /// **不用玻璃**,这是条边界:玻璃的意思是「这一层浮在内容上面」。输入区和 toolbar 浮着,
    /// 所以是玻璃;这些 chip 跟着对话一起滚,给它们上玻璃那句话就不成立了,一屏会变成
    /// 到处是反光。
    ///
    /// 画到 36 高,点得到 44——两颗 chip 之间看着还是紧的,但手指按哪儿都算数。
    func inlineChipStyle(tint: some ShapeStyle = .secondary) -> some View {
        self
            .font(.footnote)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(.fill.quaternary, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.rect)
    }
}
