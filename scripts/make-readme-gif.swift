// README 的动图：把猫的真实帧按一段"工作日"串起来，下面配一行字说明当前状态。
// 直接读 App 用的那套 sprite sheet（frames.js 描述格子），所以 README 里看到的
// 就是桌面上的那只猫，循环、过渡、小动作都是同一批帧。
//
// 用法（仓库根目录）：swift scripts/make-readme-gif.swift [out.gif]
// 只在出图时跑，不进 App。macOS 没有 ffmpeg，ImageIO 自带 GIF 编码就够。
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: "Resources/pet/skins/cat/frames")
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
              ? CommandLine.arguments[1] : "docs/images/cat.gif")

// 帧尺寸（缩放后）和底部说明条的高度。
let side = 180
let caption = 30
let fps = 12.0

// (clip, 播几遍, 说明)。"~a>b" 是从 a 的最后一帧淡到 b 的第一帧。
// 说明为 nil 的段沿用上一段的字。
let story: [(String, Int, String?)] = [
    ("sleeping", 1, "everything is done"),
    ("sleeping_to_working", 1, "a session starts"),
    ("working", 1, "working"),
    ("working_to_waiting", 1, "wants your approval"),
    ("waiting", 1, nil),
    ("waiting_to_urgent", 1, "ignored for a minute"),
    ("urgent", 1, nil),
    // 没有 urgent→working 的过渡片，App 在这里是短暂淡入淡出，这里照做。
    ("~urgent>working", 1, "approved — back to work"),
    ("working", 1, nil),
    ("working_to_finished", 1, "turn finished"),
    ("finished@dance", 1, nil),
    ("finished_to_idle", 1, "idle"),
    ("idle_to_sleeping", 1, "everything is done"),
]

// frames.js 是 `window.CAT_FRAMES = {...};`，取出 JSON 部分。
let js = try! String(contentsOf: root.appending(path: "frames.js"), encoding: .utf8)
let json = js[js.firstIndex(of: "{")!...js.lastIndex(of: "}")!]
let meta = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
let cell = meta["size"] as! Int
let clips = meta["clips"] as! [String: [String: Any]]

func image(_ name: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(root.appending(path: name) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

/// 一个 clip 的全部帧，按 alpha 图抠出来、铺在白底上。
func frames(of clip: String) -> [CGImage] {
    guard let c = clips[clip] else { fatalError("no clip \(clip)") }
    let color = image(c["file"] as! String)
    let alpha = image(c["alpha"] as! String)
    let columns = c["columns"] as! Int
    return (0..<(c["frames"] as! Int)).map { i in
        let rect = CGRect(x: (i % columns) * cell, y: (i / columns) * cell, width: cell, height: cell)
        // 灰度 alpha 图当遮罩：白=不透明。CGImage 的 mask 语义相反，所以用 masking(_:)
        // 需要一张"真正的"遮罩图；这里直接用灰度图做 clip 更简单。
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.saveGState()
        ctx.clip(to: box, mask: alpha.cropping(to: rect)!)
        ctx.draw(color.cropping(to: rect)!, in: box)
        ctx.restoreGState()
        return ctx.makeImage()!
    }
}

/// 两个 pose 之间没有过渡片时的淡入淡出，跟 App 一样大约半秒。
func blend(_ pair: [String]) -> [CGImage] {
    let a = frames(of: pair[0]).last!, b = frames(of: pair[1]).first!
    return (1...6).map { i in
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        ctx.draw(a, in: box)
        ctx.setAlpha(Double(i) / 6)
        ctx.draw(b, in: box)
        return ctx.makeImage()!
    }
}

func compose(_ cat: CGImage, _ text: String) -> CGImage {
    let w = side, h = side + caption
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(cat, in: CGRect(x: 0, y: caption, width: side, height: side))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(white: 0.3, alpha: 1),
        .paragraphStyle: style,
    ]
    (text as NSString).draw(in: CGRect(x: 0, y: 7, width: w, height: 20), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

var sequence: [CGImage] = []
var label = ""
for (clip, times, text) in story {
    if let text { label = text }
    let cat = clip.hasPrefix("~") ? blend(clip.dropFirst().split(separator: ">").map(String.init))
                                  : frames(of: clip)
    for _ in 0..<times { sequence += cat.map { compose($0, label) } }
}

func write(_ sequence: [CGImage], to out: URL) {
    let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString,
                                               sequence.count, nil)!
    CGImageDestinationSetProperties(dest, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
    ] as CFDictionary)
    for frame in sequence {
        CGImageDestinationAddImage(dest, frame, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]
        ] as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { fatalError("finalize failed") }
    print("wrote \(out.path) — \(sequence.count) frames, \(String(format: "%.1f", Double(sequence.count) / fps))s")
}

write(sequence, to: out)

// 第二张：每个 pose 偶尔做的小动作（fidget）并排放。fidget 从 loop 的第一帧出发、
// 回到 loop 的第一帧，所以短的那几个后面补上本 pose 的 loop，大家一起循环不跳帧。
let moves: [(String, String, String)] = [
    ("idle@yawn", "idle", "idle: yawns"),
    ("working@think", "working", "working: thinks"),
    ("compacting@sigh", "compacting", "compacting: sighs"),
    ("awaiting-agent@doze", "awaiting-agent", "agent: dozes"),
    ("waiting@tap", "waiting", "wants you: taps"),
    ("urgent@jump", "urgent", "ignored: jumps"),
    ("finished@dance", "finished", "finished: dances"),
    ("reading", "reading", "reading"),
]
let cellSide = 120, cellCaption = 22, perRow = 4
let tracks = moves.map { (fidget, pose, _) -> [CGImage] in frames(of: fidget) }
let loops = moves.map { frames(of: $0.1) }
let length = tracks.map(\.count).max()!
let rows = (moves.count + perRow - 1) / perRow
let grid = (0..<length).map { t -> CGImage in
    let w = cellSide * perRow, h = (cellSide + cellCaption) * rows
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(white: 0.3, alpha: 1),
        .paragraphStyle: style,
    ]
    for (i, move) in moves.enumerated() {
        let track = tracks[i], loop = loops[i]
        let frame = t < track.count ? track[t] : loop[(t - track.count) % loop.count]
        let x = (i % perRow) * cellSide
        let y = h - (i / perRow + 1) * (cellSide + cellCaption)
        ctx.draw(frame, in: CGRect(x: x, y: y + cellCaption, width: cellSide, height: cellSide))
        (move.2 as NSString).draw(in: CGRect(x: x, y: y + 5, width: cellSide, height: 16),
                                  withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}
write(grid, to: out.deletingLastPathComponent().appending(path: "cat-moves.gif"))
