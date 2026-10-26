// 把猫的每张贴图铺到纯色底上，做成给 Seedance 图生视频用的首帧/尾帧。
//
//     swift scripts/cat-seeds.swift [outDir] [green|blue]
//
// 输出 outDir/<pose>.png（1024²）和 outDir/layout.json。猫没有铺满画布：四周
// 留了空，抬手、伸懒腰这类动作才有地方去，模型也不会因为贴边而自己重新构图。
// layout.json 记下猫在画布里的位置，cat-frames.swift 抽帧时按它裁回来，所以
// 视频里的猫和现在 App 里的猫大小、脚的位置都对得上。
//
// 只在出素材时跑，不进 App。
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Resources/pet/skins/cat/assets")
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "art/seedance/seeds")
let background = args.count > 2 ? args[2] : "green"

// 抠像用的底色。纯绿离橘猫、黑卫衣、灰电脑都最远；纯蓝是备选，猫身上同样没有。
let key: CGColor = background == "blue"
    ? CGColor(red: 0, green: 0.28, blue: 1, alpha: 1)
    : CGColor(red: 0, green: 1, blue: 0, alpha: 1)

let canvas = 1024
// 猫占 82%，水平居中，脚底停在 94%：头顶和两侧留出举手的空间，脚下留一点
// 给模型画落地，不至于一动就出画。
let art = CGRect(x: 92, y: 124, width: 840, height: 840)

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let context = CIContext()
let poses = try FileManager.default.contentsOfDirectory(atPath: assets.path)
    .filter { $0.hasSuffix(".png") }.sorted()

for file in poses {
    guard let source = CIImage(contentsOf: assets.appendingPathComponent(file)) else {
        print("cannot read \(file)"); exit(1)
    }
    // Lanczos 而不是双线性：原图只有 384²，放大两倍多，边缘糊了模型会照着糊。
    let scale = art.width / source.extent.width
    let scaled = source.applyingFilter("CILanczosScaleTransform", parameters: [
        kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1,
    ])
    // CoreImage 的 y 轴朝上，所以 art 的 y 要从底边量。
    let placed = scaled.transformed(by: CGAffineTransform(
        translationX: art.minX, y: CGFloat(canvas) - art.maxY))
    let flat = placed.composited(over: CIImage(color: CIColor(cgColor: key))
        .cropped(to: CGRect(x: 0, y: 0, width: canvas, height: canvas)))
    guard let image = context.createCGImage(flat, from: flat.extent),
          let dest = CGImageDestinationCreateWithURL(
              out.appendingPathComponent(file) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { print("cannot write \(file)"); exit(1) }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("seed \(file)")
}

let layout: [String: Any] = [
    "canvas": canvas,
    "background": background,
    // 归一化的猫框，左上角为原点，抽帧时直接乘视频的宽高。
    "art": [art.minX, art.minY, art.width, art.height].map { $0 / CGFloat(canvas) },
]
try JSONSerialization.data(withJSONObject: layout, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("layout.json"))
print("layout \(out.appendingPathComponent("layout.json").path)")
