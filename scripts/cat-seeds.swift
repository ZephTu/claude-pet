// 按 scripts/cat-sheets.json 出给 Seedance 的首帧/尾帧和提示词。
//
//     swift scripts/cat-seeds.swift [outDir] [green|blue]
//
// 一个视频里上、中、下三行各一只猫，各做各的动作，所以视频数是片段数的三分之一。
// 每个视频输出 outDir/<name>-first.png、<name>-last.png（1080×1920，9:16）和
// <name>.txt（整段提示词，直接复制）。还有 outDir/layout.json，记下三只猫各自在
// 画布里的位置，cat-frames.swift 抽帧时按它裁回来——裁出来的猫和 App 里现在的
// 猫大小、脚的位置都对得上。
//
// 只在出素材时跑，不进 App。
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Resources/pet/skins/cat/assets")
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "art/seedance/sheets")
let background = args.count > 2 ? args[2] : "green"

// 抠像用的底色。纯绿离橘猫、黑卫衣、灰电脑都最远；纯蓝是备选，猫身上同样没有。
let key: CGColor = background == "blue"
    ? CGColor(red: 0, green: 0.28, blue: 1, alpha: 1)
    : CGColor(red: 0, green: 1, blue: 0, alpha: 1)

struct Spec: Decodable {
    struct Sheet: Decodable { let name: String; let duration: Int; let rows: [Row] }
    struct Row: Decodable { let from: String; let to: String; let action: String }
    let canvas: [Int]
    let common: String
    let sheets: [Sheet]
}
let spec = try JSONDecoder().decode(
    Spec.self, from: Data(contentsOf: root.appendingPathComponent("scripts/cat-sheets.json")))
let width = spec.canvas[0], height = spec.canvas[1]

// 每行高 640。猫是 560² 的正方形，水平居中，上下各留 40：举手、蹦跳有地方去，
// 相邻两只猫的框之间隔着 80，谁的耳朵也伸不进别人的框。
let rowHeight = height / 3
let side = rowHeight - 80
let boxes = (0..<3).map { row in
    CGRect(x: (width - side) / 2, y: row * rowHeight + 40, width: side, height: side)
}

/// 循环第一帧的抠图，cat-frames.swift 切循环时存的。过渡的首尾帧优先用它：
/// 过渡要接上的是循环，不是原图。
let anchors = out.deletingLastPathComponent().appendingPathComponent("anchors")

func picture(_ pose: String, anchored: Bool) -> URL {
    let anchor = anchors.appendingPathComponent("\(pose).png")
    return anchored && FileManager.default.fileExists(atPath: anchor.path)
        ? anchor : assets.appendingPathComponent("\(pose).png")
}

func sheet(_ poses: [String], anchored: Bool = false) throws -> CGImage {
    var image = CIImage(color: CIColor(cgColor: key))
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    for (row, pose) in poses.enumerated() {
        guard let source = CIImage(contentsOf: picture(pose, anchored: anchored)) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "\(pose).png"])
        }
        // Lanczos 而不是双线性：原图只有 384²，放大后边缘糊了模型会照着糊。
        let box = boxes[row]
        let scaled = source.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: box.width / source.extent.width, kCIInputAspectRatioKey: 1,
        ])
        // CoreImage 的 y 轴朝上，所以要从底边量。
        image = scaled.transformed(by: CGAffineTransform(
            translationX: box.minX, y: CGFloat(height) - box.maxY)).composited(over: image)
    }
    return CIContext().createCGImage(image, from: image.extent)!
}

func write(_ image: CGImage, _ name: String) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let place = ["上方", "中间", "下方"]
for item in spec.sheets {
    // 循环表的首尾帧是原图：循环本身就是从这里切出来的。过渡表用循环的第一帧。
    let transition = item.rows.contains { $0.from != $0.to }
    try write(try sheet(item.rows.map(\.from), anchored: transition), "\(item.name)-first.png")
    try write(try sheet(item.rows.map(\.to), anchored: transition), "\(item.name)-last.png")
    let lines = item.rows.enumerated().map { "\(place[$0.offset])的猫：\($0.element.action)" }
    // 只能给首帧的工具（豆包）不保证结尾回到原位，只能在提示词里把话说死；
    // 有尾帧的工具这句也无害。
    let back = item.rows.allSatisfy { $0.from == $0.to }
        ? "视频最后一秒三只猫都回到和第一帧完全相同的姿势、位置和大小。\n" : ""
    let prompt = "画面上、中、下三行各有一只小猫，三只猫同时做各自不同的动作，共\(item.duration)秒。\n"
        + lines.joined(separator: "\n") + "\n" + back + spec.common + "\n"
    try prompt.write(to: out.appendingPathComponent("\(item.name).txt"), atomically: true, encoding: .utf8)
    print("\(item.name): \(item.duration)s  \(item.rows.map { "\($0.from)→\($0.to)" }.joined(separator: " | "))")
}

let layout: [String: Any] = [
    "background": background,
    // 三只猫的框，归一化、左上角为原点，抽帧时直接乘视频的宽高。
    "rows": boxes.map { [$0.minX / CGFloat(width), $0.minY / CGFloat(height),
                         $0.width / CGFloat(width), $0.height / CGFloat(height)] },
]
try JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("layout.json"))
print("wrote \(spec.sheets.count) sheets to \(out.path)")
