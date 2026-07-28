import AppKit

let src = "/Users/indincys/.codex/generated_images/019fa76a-7643-7600-8ebf-c93b48dd019e/call_xBKei35CD7QMEmt3tRBMp43P.png"
let out = CommandLine.arguments[1]
// 原图整体绘制的边长；大于底板 824 时，原图自带的圆角与阴影会被裁掉
let drawSize = Double(CommandLine.arguments[2]) ?? 940

guard let img = NSImage(contentsOfFile: src),
      let tiff = img.tiffRepresentation,
      let cg = NSBitmapImageRep(data: tiff)?.cgImage else { fatalError("load failed") }

let canvas = 1024.0, plate = 824.0, radius = 185.4
let inset = (canvas - plate) / 2

guard let ctx = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("context") }

ctx.interpolationQuality = .high
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

let plateRect = CGRect(x: inset, y: inset, width: plate, height: plate)
ctx.addPath(CGPath(roundedRect: plateRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
// 居中放大绘制，原图的白底铺满整个底板
ctx.draw(cg, in: CGRect(
    x: canvas / 2 - drawSize / 2,
    y: canvas / 2 - drawSize / 2,
    width: drawSize, height: drawSize
))

guard let result = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
else { fatalError("render") }
try! png.write(to: URL(fileURLWithPath: out))
print("已生成（原图绘制边长 \(Int(drawSize))）")
