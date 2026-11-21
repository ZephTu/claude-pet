// 把豆包出的绿幕种子图做成皮肤的静态图：抠掉绿幕，九张用同一个裁剪框，缩到 384²。
//
//     swift scripts/skin-assets.swift <skin> <种子图目录>
//
// 种子图目录里每个姿势一张，文件名是姿势名（idle.png、awaiting-agent.jpeg……），
// 大小可以不一样，但必须都是正方形、构图一样（同一个提示词后缀出的图就是这样）。
// 输出 Resources/pet/skins/<skin>/assets/<姿势>.png。
//
// 九张共用一个裁剪框（各自角色范围的并集，再扩成正方形），而不是每张贴着自己的
// 边裁：那样站着的和坐着的会被放大成不同大小，切姿势时角色忽大忽小。
//
// 只在出素材时跑，不进 App。
import AppKit
import CoreGraphics

let poses = ["idle", "working", "waiting", "sleeping", "urgent", "finished",
             "reading", "compacting", "awaiting-agent"]
let work = 1536   // 先统一到这个边长再处理
let out = 384

let args = CommandLine.arguments
guard args.count == 3, args[1].range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
    print("usage: swift scripts/skin-assets.swift <skin> <seed-dir>"); exit(2)
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let dest = root.appendingPathComponent("Resources/pet/skins/\(args[1])/assets")
let source = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)

func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
}

/// work×work 的非预乘 RGBA，绿幕已抠、溢色已压。阈值跟 skin-frames.swift 的 keyed() 一样。
func keyed(_ url: URL) -> [Float] {
    guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("can't read \(url.path)"); exit(1)
    }
    if image.width != image.height { print("⚠ \(url.lastPathComponent) is not square: \(image.width)×\(image.height)") }
    var bytes = [UInt8](repeating: 0, count: work * work * 4)
    let ctx = CGContext(data: &bytes, width: work, height: work, bitsPerComponent: 8, bytesPerRow: work * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: work, height: work))
    var p = bytes.map { Float($0) / 255 }
    for i in stride(from: 0, to: p.count, by: 4) {
        let other = max(p[i], p[i + 2]), excess = p[i + 1] - other
        if excess > 0 { p[i + 1] = other }
        p[i + 3] = 1 - smooth(0.10, 0.32, excess)
    }
    return p
}

/// 不透明部分的范围（CG 坐标，原点在左下）。
func bounds(_ p: [Float]) -> CGRect {
    var minX = work, minY = work, maxX = -1, maxY = -1
    for y in 0..<work { for x in 0..<work where p[(y * work + x) * 4 + 3] > 0.5 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    // bytes 第一行是图的顶，CG 的 y 从底算
    return CGRect(x: minX, y: work - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

var pictures: [String: [Float]] = [:]
var union = CGRect.null
let files = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
for pose in poses {
    guard let file = files.first(where: { $0.deletingPathExtension().lastPathComponent == pose }) else {
        print("missing \(pose) in \(source.path)"); exit(1)
    }
    let p = keyed(file)
    let box = bounds(p)
    print(String(format: "%-15@ %@  figure %.0f×%.0f", pose, file.lastPathComponent, box.width, box.height))
    pictures[pose] = p
    union = union.union(box)
}

// 并集扩成正方形：水平居中，底边贴住脚（脚的位置在所有姿势里一致）。
let side = min(CGFloat(work), max(union.width, union.height) + 8)
var crop = CGRect(x: union.midX - side / 2, y: union.minY - 4, width: side, height: side)
crop.origin.x = min(max(crop.minX, 0), CGFloat(work) - side)
crop.origin.y = min(max(crop.minY, 0), CGFloat(work) - side)
print(String(format: "crop %.0f,%.0f %.0f² of %d² → %d²", crop.minX, crop.minY, side, work, out))

try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
for pose in poses {
    var p = pictures[pose]!
    // 预乘后建图，缩放才不会把绿幕色混进半透明边
    var bytes = [UInt8](repeating: 0, count: p.count)
    for i in stride(from: 0, to: p.count, by: 4) {
        let a = p[i + 3]
        for c in 0..<3 { p[i + c] *= a }
        for c in 0..<4 { bytes[i + c] = UInt8(min(max(p[i + c], 0), 1) * 255 + 0.5) }
    }
    let full = bytes.withUnsafeMutableBytes { buffer in
        CGContext(data: buffer.baseAddress, width: work, height: work, bitsPerComponent: 8, bytesPerRow: work * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    // cropping(to:) 的坐标原点在左上
    let cut = full.cropping(to: CGRect(x: crop.minX, y: CGFloat(work) - crop.maxY, width: side, height: side))!
    let ctx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(cut, in: CGRect(x: 0, y: 0, width: out, height: out))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: dest.appendingPathComponent("\(pose).png"))
}
print("wrote \(poses.count) pictures to \(dest.path)")
