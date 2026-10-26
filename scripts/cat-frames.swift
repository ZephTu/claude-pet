// 把 Seedance 生成的绿幕视频抽帧、抠像，拼成 App 用的帧图集和清单。
//
//     scripts/cat-frames.sh <videoDir> [sheetDir] [outDir]
//
// 直接跑 `swift scripts/cat-frames.swift` 也行，但那是不优化的解释执行，抠几千帧
// 要等很久；cat-frames.sh 先用 -O 编译一次。
//
// 一个视频是 scripts/cat-sheets.json 里的一张「表」：上中下三只猫，每只按秒数切成
// 几段（循环、小动作、过渡）。视频文件名就是表名，比如 calm.mp4、to-working.mp4。
// 缺哪个视频就少哪几段，App 里那几个姿势继续用静止图。
//
// 输出 outDir/<clip>.jpg + <clip>.a.png（每段一组 8 列的图集，颜色和透明度分开）
// 和 outDir/frames.js。每次都按 videoDir 全量重建：目录里删掉的视频，它的图集和
// 清单条目也一起没了。
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: cat-frames <videoDir> [sheetDir] [outDir]")
    exit(2)
}
let videoDir = URL(fileURLWithPath: args[1])
let sheetDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "art/seedance/sheets")
let outDir = URL(fileURLWithPath: args.count > 3 ? args[3] : "Resources/pet/skins/cat/frames")
let assets = URL(fileURLWithPath: "Resources/pet/skins/cat/assets")

/// 每帧的边长。画布在屏幕上是 120pt，Retina 下正好 240px，再大是白占内存。
let size = 240
/// 抽帧和播放的帧率。12fps 对手绘风格够顺，而且一段 5 秒的循环刚好塞进 64 格。
let fps = 12.0
let columns = 8
/// 一张图集最多 64 帧（1920×1920）。超出的按时间均匀抽稀，等于整体加速。
let maxFrames = 64
/// 过渡最多 1.5 秒：状态已经变了，猫还在慢慢走过去，信号就晚了。
let maxTransitionFrames = 18
/// 段与段的分界在标称秒数前后这么多秒里找最像种子图的那一帧。模型不会准点
/// 回到初始姿势，切在它真正回来的那一帧，循环才接得上。
let snapWindow = 1.0

// ---- 表 ----------------------------------------------------------------------

struct Spec: Decodable {
    struct Sheet: Decodable { let name: String; let duration: Double; let rows: [Row] }
    struct Row: Decodable { let from: String; let to: String; let segments: [Segment] }
    struct Segment: Decodable { let name: String?; let kind: String; let end: Double }
    let sheets: [Sheet]
}
let spec = try JSONDecoder().decode(
    Spec.self, from: Data(contentsOf: URL(fileURLWithPath: "scripts/cat-sheets.json")))

/// 三只猫的框（归一化，左上角原点），来自 cat-seeds.swift 写的 layout.json。
let boxes: [CGRect] = {
    guard let data = try? Data(contentsOf: sheetDir.appendingPathComponent("layout.json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = json["rows"] as? [[Double]], rows.count == 3
    else { print("no layout.json in \(sheetDir.path) — run scripts/cat-seeds.swift first"); exit(1) }
    return rows.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
}()

// ---- 一帧：裁、缩、抠 -------------------------------------------------------

/// 非预乘的 RGBA，0...1。抠像和混合都在这上面做，最后才预乘写出。
struct Frame {
    var pixels: [Float]
    func difference(_ other: Frame) -> Float {
        var sum: Float = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[i + 3], b = other.pixels[i + 3]
            sum += abs(a - b) + abs(pixels[i] * a - other.pixels[i] * b)
                + abs(pixels[i + 1] * a - other.pixels[i + 1] * b)
        }
        return sum / Float(pixels.count / 4)
    }
    func blended(toward other: Frame, by t: Float) -> Frame {
        var out = self
        for i in 0..<pixels.count { out.pixels[i] = pixels[i] + (other.pixels[i] - pixels[i]) * t }
        return out
    }
}

/// 背景的主色通道：绿幕是 1，蓝幕是 2。从第一帧的四条边上量，不信文件名。
func keyChannel(of image: CGImage) -> Int {
    let pixels = rgba(image, width: 64, height: 64)
    var sums = [Float](repeating: 0, count: 3)
    for y in 0..<64 { for x in 0..<64 where x == 0 || y == 0 || x == 63 || y == 63 {
        for c in 0..<3 { sums[c] += pixels[(y * 64 + x) * 4 + c] }
    } }
    return sums[1] >= sums[2] ? 1 : 2
}

func rgba(_ image: CGImage, width: Int, height: Int, crop: CGRect? = nil) -> [Float] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let source = crop.flatMap { image.cropping(to: $0) } ?? image
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    return bytes.map { Float($0) / 255 }
}

/// 绿幕：「绿得比红和蓝都多多少」就是背景的程度。橘色、白色、黑色这个值都 ≤ 0，
/// 阴影是暗绿，照样算背景，所以模型自己加的投影会被一起抠掉。
/// 抠完再去溢色：边缘残留的绿压回 max(R, B)，否则猫会描一圈绿边。
func key(_ image: CGImage, channel: Int, art: CGRect) -> Frame {
    let w = image.width, h = image.height
    let box = CGRect(x: art.minX * Double(w), y: art.minY * Double(h),
                     width: art.width * Double(w), height: art.height * Double(h)).integral
    // 先在两倍尺寸上抠，再缩到目标尺寸，边缘的半透明才是平滑的。
    let big = size * 2
    var p = rgba(image, width: big, height: big, crop: box)
    let other2 = channel == 1 ? 2 : 1  // 红永远是另一个
    for i in stride(from: 0, to: p.count, by: 4) {
        let k = p[i + channel], other = max(p[i], p[i + other2])
        let excess = k - other
        let alpha = 1 - smooth(0.10, 0.32, excess)
        if excess > 0 { p[i + channel] = other }
        p[i + 3] = alpha
        // 半透明的白字（水印）压在绿幕上：抠完是浅灰、半透明。猫身上不会有这种
        // 像素——白毛挨着背景的地方永远隔着一圈黑描边——所以按像素直接去掉，
        // 碰到 z 或耳朵的水印也跑不掉。
        let hi = max(p[i], p[i + 1], p[i + 2]), lo = min(p[i], p[i + 1], p[i + 2])
        if alpha < 0.9 && lo > 0.55 && hi - lo < 0.12 { p[i + 3] = 0 }
    }
    dropWatermark(&p, side: big)
    return Frame(pixels: downsample(p, from: big, to: size))
}

/// 豆包会在画面上打一行半透明的「豆包AI生成」，位置还会变。落在绿幕上的那部分
/// 抠完是一小块孤立的浅灰：不跟猫身相连、几乎没有颜色、偏亮。按这三条把它去掉。
/// 头顶的 z 也是孤立的小块，但它是蓝的，不会被误伤；压在猫身上的水印去不掉。
/// 顺带去掉另一种孤立小块：大半透明的（见下）。
func dropWatermark(_ p: inout [Float], side: Int) {
    // 水印淡入淡出时只剩一层几乎透明的灰；连通域要从这么淡的像素算起，不然它
    // 被切成没人管的碎边，在屏幕上留一道影子。写图集时 0.03 以下才会归零。
    let faint: Float = 0.03
    var seen = [Bool](repeating: false, count: side * side)
    for start in 0..<(side * side) where !seen[start] && p[start * 4 + 3] > faint {
        var stack = [start], blob: [Int] = []
        seen[start] = true
        while let i = stack.popLast() {
            blob.append(i)
            let x = i % side, y = i / side
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                let n = ny * side + nx
                if !seen[n] && p[n * 4 + 3] > faint { seen[n] = true; stack.append(n) }
            }
        }
        guard blob.count < side * side / 50 else { continue }
        var saturation: Float = 0, light: Float = 0, opacity: Float = 0
        for i in blob {
            opacity += p[i * 4 + 3]
            let r = p[i * 4], g = p[i * 4 + 1], b = p[i * 4 + 2]
            let hi = max(r, g, b), lo = min(r, g, b)
            saturation += hi > 0 ? (hi - lo) / hi : 0
            light += hi
        }
        let n = Float(blob.count)
        // 第二种：大半透明的孤立小块。模型让 z 淡出时会把它抹成一团半透明的
        // 影子，看着像脏东西；实心的 z 不受影响，只是消失得干脆些。
        if (saturation / n < 0.18 && light / n > 0.5) || opacity / n < 0.6 {
            for i in blob { p[i * 4 + 3] = 0 }
        }
    }
}

func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

/// 2×2 盒式缩小，按 alpha 加权，透明像素的颜色不会把边缘拖暗。
func downsample(_ p: [Float], from big: Int, to small: Int) -> [Float] {
    var out = [Float](repeating: 0, count: small * small * 4)
    for y in 0..<small { for x in 0..<small {
        var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
        for dy in 0..<2 { for dx in 0..<2 {
            let i = ((y * 2 + dy) * big + x * 2 + dx) * 4
            let a = p[i + 3]
            acc.0 += p[i] * a; acc.1 += p[i + 1] * a; acc.2 += p[i + 2] * a; acc.3 += a
        } }
        let o = (y * small + x) * 4
        if acc.3 > 0 {
            out[o] = acc.0 / acc.3; out[o + 1] = acc.1 / acc.3; out[o + 2] = acc.2 / acc.3
        }
        out[o + 3] = acc.3 / 4
    } }
    return out
}

// ---- 一段：抽帧、修剪、接缝 -------------------------------------------------

/// 整个视频抽成三行帧序列，每行一只猫。
func rows(of url: URL, expected: Double) async throws -> (rows: [[Frame]], scale: Double) {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.appliesPreferredTrackTransform = true

    var out: [[Frame]] = [[], [], []]
    var channel = 1
    var t = 0.0
    while t < duration - 0.5 / fps {
        let (image, _) = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600))
        if t == 0 {
            channel = keyChannel(of: image)
            let aspect = Double(image.width) / Double(image.height)
            if abs(aspect - 9.0 / 16.0) > 0.02 {
                print("  warning: \(image.width)×\(image.height) is not 9:16 — the cats will be cut wrong")
            }
        }
        for row in 0..<3 { out[row].append(key(image, channel: channel, art: boxes[row])) }
        t += 1 / fps
    }
    // 表里的秒数按视频实际时长等比换算：生成成了 10 秒的 5 秒表，切点跟着拉长。
    if abs(duration - expected) > 0.3 {
        print(String(format: "  warning: %.1fs long, the sheet says %.0fs — cut points scaled to match", duration, expected))
    }
    return (out, duration / expected)
}

/// 种子图本身作为一帧，用来找猫回到初始姿势的那一刻。
func still(_ pose: String) -> Frame {
    guard let image = NSImage(contentsOf: assets.appendingPathComponent("\(pose).png"))?
        .cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { print("no still for \(pose)"); exit(1) }
    var p = rgba(image, width: size, height: size)
    // rgba() 画出来是预乘的，Frame 要的是非预乘。
    for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] > 0 {
        for c in 0..<3 { p[i + c] /= p[i + 3] }
    }
    return Frame(pixels: p)
}

/// 窗口里 distance 最小的那一帧。
func nearest(_ count: Int, around index: Int, within radius: Int, distance: (Int) -> Float) -> Int {
    let lo = max(1, index - radius), hi = min(count - 2, index + radius)
    guard lo <= hi else { return min(max(index, 0), count - 1) }
    return (lo...hi).min { distance($0) < distance($1) }!
}

/// 去掉开头和结尾一动不动的帧。模型常在首尾帧附近停半秒，过渡里那半秒就是延迟。
func trimStill(_ frames: [Frame]) -> [Frame] {
    // 压缩噪点本身就有 ~0.007（合成视频实测：首帧是关键帧，跟后面每帧都差这么多），
    // 真正开始动的时候这个数一两帧内就过 0.02。
    let still: Float = 0.012
    var start = 0, end = frames.count - 1
    while start < end - 1, frames[start + 1].difference(frames[0]) < still { start += 1 }
    while end > start + 1, frames[end - 1].difference(frames[frames.count - 1]) < still { end -= 1 }
    return Array(frames[start...end])
}

/// 均匀抽稀到 limit 帧，保留首尾。
func resample(_ frames: [Frame], to limit: Int) -> [Frame] {
    guard frames.count > limit, limit > 1 else { return frames }
    return (0..<limit).map { frames[Int((Double($0) * Double(frames.count - 1) / Double(limit - 1)).rounded())] }
}

/// 循环的接缝。首尾帧都是同一张种子图，但模型很少画得一模一样：最后一帧和第一帧
/// 几乎相同就丢掉（不然那一帧会停顿），再把末尾几帧渐渐混向第一帧。
func closeLoop(_ frames: [Frame]) -> [Frame] {
    var out = frames
    if out.count > 2, out[out.count - 1].difference(out[0]) < 0.01 { out.removeLast() }
    // 两帧就够：真视频首尾差的多是头的位置，混得越久，重影的帧越多。
    let tail = min(2, out.count / 4)
    for k in 0..<tail {
        let i = out.count - tail + k
        out[i] = out[i].blended(toward: out[0], by: Float(k + 1) / Float(tail + 1))
    }
    return out
}

/// 一段写成两张图：颜色是 JPEG（预乘在黑底上），透明度是灰度 PNG。
///
/// 全塞进一张 RGBA PNG 不行：视频压缩的噪点让 PNG 几乎压不动，一段 5 秒循环
/// 3~4MB，整套三十段就是上百 MB。颜色交给有损的 JPEG，透明度单独存——它只有
/// 一圈边缘不是 0 或 1，PNG 压它压得很好。两张在着色器里合回去。
func writeAtlas(_ frames: [Frame], color: URL, alpha: URL) throws -> (columns: Int, rows: Int) {
    let cols = min(columns, frames.count)
    let rows = (frames.count + cols - 1) / cols
    let width = cols * size, height = rows * size
    var rgb = [UInt8](repeating: 0, count: width * height * 4)
    var mask = [UInt8](repeating: 0, count: width * height)
    for (n, frame) in frames.enumerated() {
        let ox = (n % cols) * size, oy = (n / cols) * size
        for y in 0..<size { for x in 0..<size {
            let s = (y * size + x) * 4, d = (oy + y) * width + ox + x
            var a = min(max(frame.pixels[s + 3], 0), 1)
            if a < 0.03 { a = 0 } else if a > 0.97 { a = 1 }
            for c in 0..<3 { rgb[d * 4 + c] = UInt8(min(max(frame.pixels[s + c], 0), 1) * a * 255 + 0.5) }
            rgb[d * 4 + 3] = 255
            mask[d] = UInt8(a * 255 + 0.5)
        } }
    }
    let colorCtx = CGContext(data: &rgb, width: width, height: height, bitsPerComponent: 8,
                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let maskCtx = CGContext(data: &mask, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    try write(colorCtx.makeImage(), to: color, type: .jpeg,
              options: [kCGImageDestinationLossyCompressionQuality: 0.88])
    try write(maskCtx.makeImage(), to: alpha, type: .png, options: [:])
    return (cols, rows)
}

func write(_ image: CGImage?, to url: URL, type: UTType, options: [CFString: Any]) throws {
    guard let image,
          let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, image, options as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

// ---- 循环表：按动作本身切，不按秒数切 -----------------------------------------

/// 豆包这类只给首帧的工具不照提示词里的秒数走：让它「0-5 秒睡觉，5-10 秒翻身」，
/// 它可能第 3 秒就站起来伸懒腰了。所以循环表不信秒数，看猫自己：
///
/// 1. 找「休息姿势」：跟其他帧中位距离最小的那一帧。大部分时间猫都在原姿势上，
///    所以它就是模型画出来的原姿势——比种子图本身准，种子图的画风跟模型不一样。
/// 2. 离休息姿势很远的连续一段就是一个小动作，两头延伸到最接近休息姿势的那一帧。
/// 3. 剩下最长的那段安静时间里，找首尾最像的一对帧当循环。
///
/// 开头 0.4 秒不要：那是种子图本身，下一帧画风就换成模型的了，会闪一下。
struct Auto {
    var loop: ClosedRange<Int>
    var loopSeam: Float
    var fidgets: [(range: ClosedRange<Int>, seam: Float)]
}

func autoSegment(_ frames: [Frame]) -> Auto? {
    let skip = Int(0.4 * fps)
    let all = Array(skip..<frames.count)
    guard all.count > Int(2 * fps) else { return nil }
    let probe = all.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
    let rest = probe.min { a, b in
        func spread(_ i: Int) -> Float {
            let d = probe.map { frames[i].difference(frames[$0]) }.sorted()
            return d[d.count / 2]
        }
        return spread(a) < spread(b)
    }!
    let away = frames.map { $0.difference(frames[rest]) }

    // 离休息姿势超过 moving 的帧算在动，前后相隔不到半秒的两段算同一个动作。
    let moving: Float = 0.25
    var runs: [ClosedRange<Int>] = []
    for i in all where away[i] > moving {
        if let last = runs.last, i - last.upperBound <= Int(0.5 * fps) {
            runs[runs.count - 1] = last.lowerBound...i
        } else {
            runs.append(i...i)
        }
    }
    // 两头各往外找 1.5 秒，停在最像休息姿势的那一帧上。
    let reach = Int(1.5 * fps)
    var moves = runs.map { run -> ClosedRange<Int> in
        let left = (max(skip, run.lowerBound - reach)...run.lowerBound).min { away[$0] < away[$1] }!
        let right = (run.upperBound...min(frames.count - 1, run.upperBound + reach)).min { away[$0] < away[$1] }!
        return left...right
    }
    moves.removeAll { $0.count < Int(0.8 * fps) }

    // 最长的安静段。
    var quiet: [ClosedRange<Int>] = []
    var cursor = skip
    for move in moves {
        if move.lowerBound - cursor > 1 { quiet.append(cursor...(move.lowerBound - 1)) }
        cursor = move.upperBound + 1
    }
    if frames.count - 1 - cursor > 1 { quiet.append(cursor...(frames.count - 1)) }
    guard let calm = quiet.max(by: { $0.count < $1.count }), calm.count >= Int(1.5 * fps) else { return nil }

    // 循环：首尾最像的一对，长度 1.5 秒到一张图集装得下为止；差不多像的里挑最长的。
    var pairs: [(a: Int, b: Int, d: Float)] = []
    for a in calm { for b in calm where b - a >= Int(1.5 * fps) && b - a <= maxFrames {
        pairs.append((a, b, frames[a].difference(frames[b])))
    } }
    let best = pairs.map(\.d).min()!
    let pick = pairs.filter { $0.d <= best + 0.02 }.max { $0.b - $0.a < $1.b - $1.a }!

    // 小动作接在循环的第一帧后面播，也回到它，所以两头都跟它比。
    let anchor = frames[pick.a]
    let fidgets = moves.map { move -> (ClosedRange<Int>, Float) in
        let s = (max(skip, move.lowerBound - 6)...move.lowerBound).min {
            frames[$0].difference(anchor) < frames[$1].difference(anchor) }!
        let e = (move.upperBound...min(frames.count - 1, move.upperBound + 6)).min {
            frames[$0].difference(anchor) < frames[$1].difference(anchor) }!
        return (s...e, max(frames[s].difference(anchor), frames[e].difference(anchor)))
    }
    return Auto(loop: pick.a...pick.b, loopSeam: pick.d, fidgets: fidgets)
}

var manifest: [String: [String: Any]] = [:]
var looped = Set<String>()

func emit(_ name: String, kind: String, pose: String, from: String, slice: [Frame], seam: Float) throws {
    var list: [Frame]
    switch kind {
    case "transition": list = resample(trimStill(slice), to: maxTransitionFrames)
    default: list = closeLoop(resample(Array(slice.dropLast()), to: maxFrames))
    }
    guard !list.isEmpty else { print("  skip \(name): no frames"); return }
    let file = "\(name).jpg", mask = "\(name).a.png"
    let grid = try writeAtlas(list, color: outDir.appendingPathComponent(file),
                              alpha: outDir.appendingPathComponent(mask))
    var entry: [String: Any] = [
        "file": file, "alpha": mask, "kind": kind, "pose": pose,
        "frames": list.count, "columns": grid.columns,
    ]
    if kind == "transition" { entry["from"] = from }
    if kind == "loop" { looped.insert(pose) }
    manifest[name] = entry
    // 接缝分：片段首尾帧跟它该接上的那一帧差多少。整只猫换了姿势是 0.7 上下；
    // 豆包真视频里呼吸、尾巴、飘着的 z 就有 0.05，肉眼看是同一帧。0.10 以上
    // （眼睛一睁一闭这种）接上去才看得出一跳。
    let warn: Float = 0.10
    print(String(format: "  %-28@ %-10@ %2d frames  %.2fs  seam %.3f%@", name as NSString,
                 kind as NSString, list.count, Double(list.count) / fps,
                 seam, (seam > warn ? "  ⚠ 接缝明显，考虑重抽" : "") as NSString))
}

// ---- 全量重建 ---------------------------------------------------------------

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for stale in (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
where ["png", "jpg", "js"].contains(stale.pathExtension) {
    try FileManager.default.removeItem(at: stale)
}

for sheet in spec.sheets {
    let url = ["mp4", "mov", "m4v"].map { videoDir.appendingPathComponent("\(sheet.name).\($0)") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    guard let url else { print("\(sheet.name): no video yet"); continue }
    print("\(sheet.name):")
    let (rows, scale) = try await rows(of: url, expected: sheet.duration)

    for (r, row) in sheet.rows.enumerated() {
        let frames = rows[r]
        guard frames.count > 2 else { continue }

        if row.segments.allSatisfy({ $0.kind == "loop" || $0.kind == "fidget" }) {
            guard let cut = autoSegment(frames),
                  let loopName = row.segments.first(where: { $0.kind == "loop" })?.name
            else { print("  \(row.from): no calm stretch long enough for a loop — regenerate"); continue }
            try emit(loopName, kind: "loop", pose: row.from, from: "",
                     slice: Array(frames[cut.loop]), seam: cut.loopSeam)
            // 动作比表里写的多，就把多出来的也留下：第二个叫 <名字>2，以此类推。
            let base = row.segments.first(where: { $0.kind == "fidget" })?.name ?? "\(row.from)@move"
            for (n, fidget) in cut.fidgets.enumerated() {
                try emit(n == 0 ? base : "\(base)\(n + 1)", kind: "fidget", pose: row.from, from: "",
                         slice: Array(frames[fidget.range]), seam: fidget.seam)
            }
            continue
        }
        // 拿什么当「回到原位」的标准：起点姿势用这段视频自己的第一帧——它就是种子图
        // 经过模型和压缩之后的样子，跟原图逐像素比会差出 0.05 左右的底噪，跟它比
        // 才是 0。终点姿势视频里没有现成的，只能跟原图比，再扣掉同样的底噪。
        let offset = frames[0].difference(still(row.from))
        func distance(_ i: Int, _ pose: String) -> Float {
            pose == row.from ? frames[i].difference(frames[0])
                             : max(0, frames[i].difference(still(pose)) - offset)
        }
        // 分界点：先按秒数换成帧号，再吸附到最像种子图的那一帧。过渡之后的分界
        // 吸附到它的终点姿势，其余吸附到起点姿势。
        var cuts = [0]
        var passedTransition = false
        for segment in row.segments.dropLast() {
            if segment.kind == "transition" { passedTransition = true }
            let index = Int((segment.end * scale * fps).rounded())
            let pose = passedTransition ? row.to : row.from
            cuts.append(max(cuts.last! + 1,
                            nearest(frames.count, around: index, within: Int(snapWindow * fps)) { distance($0, pose) }))
        }
        // 最后一刀也要找。有尾帧约束时最后一帧就是种子图，找到的就是它；豆包这类
        // 只能给首帧的，模型多半回不到原位，就在最后 1.5 秒里挑最像的一帧收尾，
        // 后面的扔掉。
        let tail = Int(1.5 * fps)
        let end = frames.indices.suffix(tail + 1).filter { $0 > cuts.last! }
            .min { distance($0, row.to) < distance($1, row.to) }
        cuts.append(end ?? frames.count - 1)

        for (i, segment) in row.segments.enumerated() {
            guard segment.kind != "skip", let name = segment.name else { continue }
            let slice = Array(frames[cuts[i]...min(cuts[i + 1], frames.count - 1)])
            let pose = segment.kind == "transition" ? row.to : row.from
            let start = segment.kind == "transition" ? row.from : pose
            let seam = max(distance(cuts[i], start), distance(min(cuts[i + 1], frames.count - 1), pose))
            try emit(name, kind: segment.kind, pose: pose, from: row.from, slice: slice, seam: seam)
        }
    }
}

let body = try JSONSerialization.data(
    withJSONObject: ["size": size, "fps": fps, "clips": manifest],
    options: [.prettyPrinted, .sortedKeys])
let script = "// Generated by scripts/cat-frames.swift — do not edit.\nwindow.CAT_FRAMES = "
    + String(decoding: body, as: UTF8.self) + ";\n"
try script.write(to: outDir.appendingPathComponent("frames.js"), atomically: true, encoding: .utf8)

let poses = Set(spec.sheets.flatMap { $0.rows.flatMap { [$0.from, $0.to] } })
let missing = poses.subtracting(looped).sorted()
if !missing.isEmpty {
    print("no loop yet for: \(missing.joined(separator: ", ")) — those poses stay on the still picture")
}
print("wrote \(manifest.count) clips to \(outDir.path)")
