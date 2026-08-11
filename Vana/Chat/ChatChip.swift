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

    /// 只有一个图标的那种:回复底下的复制和更多。
    ///
    /// 同一块材质、同一个圆角家族,只是收成了正圆——这一排原来是两个**裸图标**浮在那儿,
    /// 而这一屏上别的每一个可点的东西都带着这层底。少了它,那两颗既不像按钮,也和上面
    /// 几颗 chip 对不上;两条细线条挂在一段圆头圆脑的对话下面,看着就是硬的。
    ///
    /// 尺寸跟着 `inlineChipStyle`:画到 36,点得到 44。
    func iconChipStyle(tint: some ShapeStyle = .secondary) -> some View {
        self
            .font(.footnote)
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(.fill.quaternary, in: .circle)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}
