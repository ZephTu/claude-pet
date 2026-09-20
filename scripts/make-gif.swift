// 把连拍的 PNG 裁剪后编成 animated GIF。macOS 上没有 ffmpeg / imagemagick，
// 但 ImageIO 自带 GIF 编码，够用。只在出图时跑，不进 App。
import AppKit
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 8 else {
    print("usage: makegif <framesDir> <out.gif> <x> <y> <w> <h> <delaySeconds> [scale]")
    exit(2)
}
let dir = URL(fileURLWithPath: a[1]), out = URL(fileURLWithPath: a[2])
let crop = CGRect(x: Double(a[3])!, y: Double(a[4])!, width: Double(a[5])!, height: Double(a[6])!)
let delay = Double(a[7])!
let scale = a.count > 8 ? Double(a[8])! : 1.0

let files = (try! FileManager.default.contentsOfDirectory(atPath: dir.path))
    .filter { $0.hasSuffix(".png") }.sorted()
guard !files.isEmpty else { print("no frames"); exit(1) }

guard let dest = CGImageDestinationCreateWithURL(
    out as CFURL, UTType.gif.identifier as CFString, files.count, nil) else { exit(1) }
CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
] as CFDictionary)

let size = CGSize(width: crop.width * scale, height: crop.height * scale)
for name in files {
    guard
        let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(name) as CFURL, nil),
        let full = CGImageSourceCreateImageAtIndex(src, 0, nil),
        let cut = full.cropping(to: crop),
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { print("bad frame \(name)"); exit(1) }
    // GIF 的透明只有 1 bit，半透明边缘会变成硬锯齿，所以先铺白底，
    // 跟 README 的浅色背景一致。
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: size))
    ctx.interpolationQuality = .high
    ctx.draw(cut, in: CGRect(origin: .zero, size: size))
    guard let framed = ctx.makeImage() else { exit(1) }
    CGImageDestinationAddImage(dest, framed, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(dest) else { print("finalize failed"); exit(1) }
print("wrote \(out.path) — \(files.count) frames")
