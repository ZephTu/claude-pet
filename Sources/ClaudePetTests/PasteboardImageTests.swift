import AppKit
import ClaudePetCore

/// Reading a pasted image whatever type put it there (PasteboardImage), on private pasteboards.
enum PasteboardImageTests {
    static func run(_ t: Harness) {
        print("\n-- pasteboard images")

        // A 4×3 opaque picture: red 200, green 40·x, blue 90.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8,
                                   samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<4 { for y in 0..<3 { var p = [200, 40 * x, 90]; rep.setPixel(&p, atX: x, y: y) } }
        let png = rep.representation(using: .png, properties: [:])!
        let jpeg = rep.representation(using: .jpeg, properties: [:])!
        let tiff = rep.tiffRepresentation!
        let bmp = rep.representation(using: .bmp, properties: [:])!

        let pb = NSPasteboard(name: .init("ClaudePetTests-\(getpid())"))
        defer { pb.releaseGlobally() }
        func put(_ entries: [(String, Data)]) {
            pb.clearContents()
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: .init(type)) }
            pb.writeObjects([item])
        }
        func decoded(_ r: (data: Data, mime: String)?) -> NSBitmapImageRep? { r.flatMap { NSBitmapImageRep(data: $0.data) } }
        /// The stored samples at (x, 1), as (red, green, blue, alpha): no colour matching.
        func red(_ r: NSBitmapImageRep?, _ x: Int) -> (Int, Int, Int, Int)? {
            guard let r, r.bitsPerSample == 8, !r.bitmapFormat.contains(.alphaFirst) else { return nil }
            var p = [Int](repeating: 255, count: max(r.samplesPerPixel, 4))
            r.getPixel(&p, atX: x, y: 1)
            return (p[0], p[1], p[2], r.hasAlpha ? p[3] : 255)
        }

        put([("public.png", png)])
        var got = PasteboardImage.read(pb)
        t.check("a PNG (a screenshot) is kept as it is", got?.data == png && got?.mime == "image/png")
        t.check("… and left to the web view, which reads it itself", !(PasteboardImage.forWeb(pb) != nil))

        put([("public.jpeg", jpeg)])
        got = PasteboardImage.read(pb)
        t.check("a JPEG is kept as it is", got?.data == jpeg && got?.mime == "image/jpeg")

        put([("public.tiff", tiff)])
        got = PasteboardImage.read(pb)
        t.check("a TIFF (a browser's copied image) becomes a PNG of the same picture",
                got?.mime == "image/png" && decoded(got)?.pixelsWide == 4 && red(decoded(got), 2)! == (200, 80, 90, 255))
        t.check("… and is left to the web view", !(PasteboardImage.forWeb(pb) != nil))

        put([("com.microsoft.bmp", bmp)])
        got = PasteboardImage.read(pb)
        t.check("a BMP alone (Deskflow) becomes a PNG of the same picture",
                got?.mime == "image/png" && decoded(got)?.pixelsHigh == 3 && red(decoded(got), 3)! == (200, 120, 90, 255))
        t.check("… and is handed to the web view, which can't read a BMP", (PasteboardImage.forWeb(pb) != nil))

        put([("com.microsoft.bmp", bmp), ("public.png", png)])
        t.check("a BMP next to a PNG: the PNG is used, and the web view reads that",
                PasteboardImage.read(pb)?.data == png && !(PasteboardImage.forWeb(pb) != nil))

        // A 32-bit BMP whose V5 header names an alpha channel left all zeros: decoded as it says,
        // every pixel would be transparent (and black).
        let clearBMP = bmpV5(width: 4, height: 3, alpha: 0) { x, _ in (b: 90, g: UInt8(40 * x), r: 200) }
        put([("com.microsoft.bmp", clearBMP)])
        got = PasteboardImage.read(pb)
        t.check("a BMP with an empty alpha channel is read opaque, colours kept",
                red(decoded(got), 1).map { $0 == (200, 40, 90, 255) } == true)
        let halfBMP = bmpV5(width: 4, height: 3, alpha: 128) { _, _ in (b: 90, g: 40, r: 200) }
        put([("com.microsoft.bmp", halfBMP)])
        t.check("a BMP with a real alpha channel keeps it",
                red(decoded(PasteboardImage.read(pb)), 0).map { $0.3 == 128 } == true)

        put([("public.utf8-plain-text", Data("a\tb".utf8)), ("com.microsoft.bmp", bmp)])
        t.check("a BMP that comes with text (cells copied in Excel) pastes as text in the board",
                PasteboardImage.forWeb(pb) == nil)

        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 20, height: 10)
        let ctx = CGContext(consumer: CGDataConsumer(data: pdf)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil); ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(box); ctx.endPDFPage(); ctx.closePDF()
        put([("com.adobe.pdf", pdf as Data)])
        t.check("a PDF alone still becomes a picture", PasteboardImage.read(pb)?.mime == "image/png")

        pb.clearContents()
        pb.setString("just text", forType: .string)
        t.check("text alone is no image", PasteboardImage.read(pb) == nil && !(PasteboardImage.forWeb(pb) != nil))
    }

    /// A top-down 32-bit BMP with a V5 header and BI_BITFIELDS masks, alpha mask 0xFF000000.
    static func bmpV5(width w: Int, height h: Int, alpha: UInt8,
                      _ pixel: (Int, Int) -> (b: UInt8, g: UInt8, r: UInt8)) -> Data {
        func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func le16(_ v: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        var px: [UInt8] = []
        for y in 0..<h { for x in 0..<w { let p = pixel(x, y); px += [p.b, p.g, p.r, alpha] } }
        var info = le32(124) + le32(w) + le32(-h) + le16(1) + le16(32) + le32(3) + le32(px.count)
        info += le32(2835) + le32(2835) + le32(0) + le32(0)
        info += le32(0x00FF_0000) + le32(0x0000_FF00) + le32(0x0000_00FF) + le32(0xFF00_0000)
        info += Array("BGRs".utf8) + [UInt8](repeating: 0, count: 36 + 12) + le32(4) + le32(0) + le32(0) + le32(0)
        let offset = 14 + info.count
        return Data([0x42, 0x4D] + le32(offset + px.count) + le32(0) + le32(offset) + info + px)
    }
}
