// 作者：huangxiaofeng
// 创建日期：2026-11-26
// 闲鱼助手的小鱼图形：应用图标与菜单栏图标共用同一份形状

import CoreGraphics

enum FishShape {
    /// 在 rect 内画一条朝左的鱼（身体 + 尾巴，眼睛镂空）。
    /// 形状定义在 0~1 的单位坐标里（y 轴向上），按 rect 等比缩放。
    static func draw(in ctx: CGContext, rect: CGRect, color: CGColor) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }

        let body = CGMutablePath()
        body.move(to: p(0.0, 0.5))
        body.addCurve(to: p(0.74, 0.5), control1: p(0.14, 0.86), control2: p(0.56, 0.86))
        body.addCurve(to: p(0.0, 0.5), control1: p(0.56, 0.14), control2: p(0.14, 0.14))
        body.closeSubpath()

        let tail = CGMutablePath()
        tail.move(to: p(0.66, 0.5))
        tail.addQuadCurve(to: p(1.0, 0.80), control: p(0.80, 0.64))
        tail.addQuadCurve(to: p(1.0, 0.20), control: p(0.86, 0.5))
        tail.addQuadCurve(to: p(0.66, 0.5), control: p(0.80, 0.36))
        tail.closeSubpath()

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color)
        ctx.addPath(body)
        ctx.fillPath()
        ctx.addPath(tail)
        ctx.fillPath()

        // 眼睛镂空
        let r = 0.055 * rect.width
        let eye = p(0.19, 0.57)
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: eye.x - r, y: eye.y - r, width: r * 2, height: r * 2))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
