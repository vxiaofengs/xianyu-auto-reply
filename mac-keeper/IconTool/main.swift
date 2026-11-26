// 作者：huangxiaofeng
// 创建日期：2026-11-26
// 生成闲鱼助手的应用图标：输出 AppIcon.iconset（各尺寸 PNG），再由 iconutil 打成 .icns
//
// 用法：icontool <输出的 .iconset 目录>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// 以 1024 画布绘制
func drawIcon(_ ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 底板：投影 + 青绿渐变
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.28))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x0B8FA0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [rgb(0x3EDC9B), rgb(0x0B8FA0)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    // 顶部一层柔光
    let gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // 小鱼
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: rgb(0x055A66, 0.35))
    FishShape.draw(in: ctx, rect: CGRect(x: 222, y: 290, width: 580, height: 580), color: rgb(0xFFFFFF))
    ctx.restoreGState()

    // 右下角对勾徽章：表示自动发货 / 在线守护
    let center = CGPoint(x: 712, y: 300)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0x000000, 0.25))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: center.x - 112, y: center.y - 112, width: 224, height: 224))
    ctx.restoreGState()

    ctx.setFillColor(rgb(0x16B68A))
    ctx.fillEllipse(in: CGRect(x: center.x - 88, y: center.y - 88, width: 176, height: 176))

    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: center.x - 44, y: center.y + 2))
    ctx.addLine(to: CGPoint(x: center.x - 10, y: center.y - 32))
    ctx.addLine(to: CGPoint(x: center.x + 46, y: center.y + 34))
    ctx.strokePath()
}

func renderPNG(size: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "icontool", code: 1)
    }
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(ctx)
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icontool", code: 2)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icontool", code: 3) }
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("用法：icontool <输出的 .iconset 目录>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try renderPNG(size: base, to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(size: base * 2, to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
