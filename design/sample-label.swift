// README のスクリーンショット(docs/screenshot.png)に使う、架空の宅配伝票の画像を作る。
// 使い方: swiftc design/sample-label.swift -o /tmp/sample-label && (cd <作業フォルダ> && /tmp/sample-label)  → label.jpg
// 撮り方は .claude/skills/pixwash/SKILL.md の「README のスクリーンショット」を参照

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// 架空の宅配伝票を段ボールの上に置いた「写真風」の画像。実在の住所・会社・人名は使わない
let W = 1200, H = 1600
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// 上下を反転して、左上が原点の座標で描く
ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

// 段ボール: 茶色 + 縦の筋 + 細かいざらつき
ctx.setFillColor(color(0.74, 0.58, 0.40)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
var rng = SystemRandomNumberGenerator()
for x in stride(from: 0, to: W, by: 3) {
    let v = CGFloat.random(in: -0.03...0.03, using: &rng)
    ctx.setFillColor(color(0.74 + v, 0.58 + v, 0.40 + v, 0.6)); ctx.fill(CGRect(x: x, y: 0, width: 3, height: H))
}
for _ in 0..<40000 {
    let v = CGFloat.random(in: -0.08...0.08, using: &rng)
    ctx.setFillColor(color(0.74 + v, 0.58 + v, 0.40 + v, 0.35))
    ctx.fill(CGRect(x: CGFloat.random(in: 0..<CGFloat(W)), y: CGFloat.random(in: 0..<CGFloat(H)), width: 2, height: 2))
}
// 上から照らしたような明るさのむら
let grad = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.12), color(0, 0, 0, 0.18)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: CGFloat(W), y: CGFloat(H)), options: [])

// 伝票(少し傾けて、影を付ける)
let label = CGRect(x: 150, y: 260, width: 900, height: 1080)
ctx.saveGState()
ctx.translateBy(x: label.midX, y: label.midY); ctx.rotate(by: -0.025); ctx.translateBy(x: -label.midX, y: -label.midY)
ctx.setShadow(offset: CGSize(width: 10, height: 14), blur: 24, color: color(0, 0, 0, 0.45))
ctx.setFillColor(color(0.98, 0.98, 0.96)); ctx.fill(label)
ctx.setShadow(offset: .zero, blur: 0, color: nil)

func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, bold: Bool = false, gray: CGFloat = 0.12) {
    let font = CTFontCreateWithName((bold ? "HiraginoSans-W6" : "HiraginoSans-W3") as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color(gray, gray, gray)])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    // CoreText は下が原点なので、その行だけ上下を戻して描く
    ctx.translateBy(x: x, y: y); ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}
func box(_ r: CGRect, width: CGFloat = 3) { ctx.setStrokeColor(color(0.2, 0.35, 0.6)); ctx.setLineWidth(width); ctx.stroke(r) }

let x0 = label.minX + 50
text("お届け先", x0, label.minY + 80, size: 34, bold: true, gray: 0.15)
box(CGRect(x: x0 - 20, y: label.minY + 105, width: 840, height: 400))
text("〒000-0000", x0, label.minY + 170, size: 40)
text("架空県サンプル市見本町 1-2-3", x0, label.minY + 240, size: 44)
text("テストハイツ 101", x0, label.minY + 305, size: 44)
text("山田 太郎 様", x0, label.minY + 410, size: 72, bold: true)
text("TEL 000-0000-0000", x0, label.minY + 480, size: 38)

text("ご依頼主", x0, label.minY + 600, size: 30, bold: true, gray: 0.15)
box(CGRect(x: x0 - 20, y: label.minY + 620, width: 840, height: 210), width: 2)
text("〒000-0001 架空県例示市見本町 4-5-6", x0, label.minY + 680, size: 32)
text("サンプル商店", x0, label.minY + 740, size: 36)
text("TEL 000-0000-0001", x0, label.minY + 800, size: 30)

// 品名とバーコード風の縞(読めない架空のもの)
text("品名: 雑貨", x0, label.minY + 900, size: 34)
for i in 0..<70 where i % 3 != 0 {
    ctx.setFillColor(color(0.1, 0.1, 0.1)); ctx.fill(CGRect(x: x0 + CGFloat(i) * 11, y: label.minY + 940, width: CGFloat(3 + (i * 7) % 5), height: 90))
}
ctx.restoreGState()

let image = ctx.makeImage()!
let out = NSMutableData()
let d = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
CGImageDestinationFinalize(d)
try! (out as Data).write(to: URL(fileURLWithPath: "label.jpg"))
print("ok")
