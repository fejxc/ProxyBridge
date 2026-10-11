// 生成 ProxyBridge 应用图标（1024×1024 PNG）：蓝色圆角方块 + 白色双向箭头（⇄ 品牌母题）。
// 用法：swift tools/make_icon.swift <输出.png>
// 仅依赖系统 CoreGraphics/ImageIO（CLT 环境可运行）。

import Foundation
import CoreGraphics
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("用法: make_icon <output.png>\n".utf8))
    exit(1)
}
let outputURL = URL(fileURLWithPath: arguments[1])

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(2) }

// 背景：品牌蓝圆角方块（macOS 图标惯例：近满幅圆角）
let margin = CGFloat(size) * 0.02
let radius = CGFloat(size) * 0.225
let bgRect = CGRect(
    x: margin, y: margin,
    width: CGFloat(size) - margin * 2,
    height: CGFloat(size) - margin * 2
)
ctx.setFillColor(CGColor(red: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1))
ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.fillPath()

/// 画一枚白色粗箭头（参数均为画布比例 0–1；tip 为尖端，headBase 为箭头底边，tail 为尾部）。
func drawArrow(centerY: CGFloat, tailX: CGFloat, headBaseX: CGFloat, tipX: CGFloat, pointsLeft: Bool) {
    let w = CGFloat(size)
    let h = CGFloat(size)
    let thickness = h * 0.08
    let headHalf = h * 0.13
    let yC = h * centerY

    func X(_ fraction: CGFloat) -> CGFloat {
        let pixel = w * fraction
        return pointsLeft ? w - pixel : pixel
    }

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

    // 杆
    let shaft = CGRect(
        x: min(X(tailX), X(headBaseX)),
        y: yC - thickness / 2,
        width: abs(X(headBaseX) - X(tailX)),
        height: thickness
    )
    ctx.fill(shaft)

    // 头（三角）
    let head = CGMutablePath()
    head.move(to: CGPoint(x: X(tipX), y: yC))
    head.addLine(to: CGPoint(x: X(headBaseX), y: yC + headHalf))
    head.addLine(to: CGPoint(x: X(headBaseX), y: yC - headHalf))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.fillPath()
}

drawArrow(centerY: 0.63, tailX: 0.26, headBaseX: 0.63, tipX: 0.78, pointsLeft: true)  // 上行：远端 → 本地
drawArrow(centerY: 0.37, tailX: 0.26, headBaseX: 0.63, tipX: 0.78, pointsLeft: false) // 下行：本地 → 远端

guard let image = ctx.makeImage() else { exit(3) }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(4) }
do {
    try data.write(to: outputURL)
} catch {
    FileHandle.standardError.write(Data("写入失败：\(error)\n".utf8))
    exit(5)
}
print("图标已生成：\(outputURL.path)")
