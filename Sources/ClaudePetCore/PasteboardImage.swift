import AppKit

/// An image on the pasteboard, as bytes the board and Claude can read.
///
/// What puts the image there decides its type: a screenshot is PNG, a browser hands over PNG or
/// TIFF, and Deskflow (one keyboard, mouse and clipboard across machines) writes only BMP. The
/// board's web view reads PNG, TIFF, JPEG and GIF itself, and a BMP not at all — its paste then
/// did nothing — so the types are tried in turn and the first one that decodes wins.
public enum PasteboardImage {
    /// Types kept as they are: what the board and Claude read directly.
    static let asIs: [(type: String, mime: String)] = [
        ("public.png", "image/png"), ("public.jpeg", "image/jpeg"), ("com.compuserve.gif", "image/gif"),
    ]
    /// Types converted to PNG, before any other image type found on the pasteboard.
    static let converted = ["public.tiff", "com.microsoft.bmp"]
    /// What the board's web view turns into an image itself when it is pasted (an image file
    /// copied in Finder included).
    static let webReadable: Set<String> = Set(asIs.map(\.type) + ["public.tiff", "public.file-url"])

    /// The image on `pb` as (bytes, MIME type): PNG, JPEG or GIF as they are, anything else
    /// AppKit decodes (TIFF, BMP, HEIC …) as PNG. Nil when there is none.
    public static func read(_ pb: NSPasteboard) -> (data: Data, mime: String)? {
        let types = (pb.types ?? []).map(\.rawValue)
        for (type, mime) in asIs where types.contains(type) {
            if let d = pb.data(forType: .init(type)), NSBitmapImageRep(data: d) != nil { return (d, mime) }
        }
        let others = converted + types.filter { NSImage.imageTypes.contains($0) && !converted.contains($0) }
        var clear: Data?   // one that decodes to nothing but transparent pixels: the last resort
        for type in others where types.contains(type) {
            guard let d = pb.data(forType: .init(type)), let png = png(from: d) else { continue }
            if !png.clear { return (png.data, "image/png") }
            if clear == nil { clear = png.data }
        }
        return clear.map { ($0, "image/png") }
    }

    /// True when `pb` holds an image the board's web view would not see on a paste — only types
    /// it can't read, a BMP from Deskflow say. AppKit offers a TIFF made from such a BMP, but the
    /// web view goes by what the pasteboard's items really hold, so those are what count here.
    public static func needsHandingToWeb(_ pb: NSPasteboard) -> Bool {
        let held = Set((pb.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        return held.isDisjoint(with: webReadable) && read(pb) != nil
    }

    /// Image bytes in any type AppKit decodes, as PNG; `clear` when every pixel is transparent.
    /// A 32-bit BMP whose header names an alpha channel nobody filled in (all zeros) decodes that
    /// way: then it is decoded again without its alpha channel.
    static func png(from data: Data) -> (data: Data, clear: Bool)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        var out = rep
        var clear = rep.hasAlpha && allTransparent(rep)
        if clear, let opaque = bmpWithoutAlpha(data), let r = NSBitmapImageRep(data: opaque) {
            out = r
            clear = r.hasAlpha && allTransparent(r)
        }
        guard let png = out.representation(using: .png, properties: [:]) else { return nil }
        return (png, clear)
    }

    /// Every pixel's alpha is zero.
    static func allTransparent(_ rep: NSBitmapImageRep) -> Bool {
        guard let cg = rep.cgImage else { return false }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buf = ctx.data else { return false }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = buf.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 3, to: w * h * 4, by: 4) where px[i] != 0 { return false }
        return true
    }

    /// A BMP with its alpha mask cleared, so it decodes opaque; nil when it has no alpha mask.
    /// The mask sits at byte 66 (after the file header, the 40-byte info header and the red, green
    /// and blue masks): in a V4/V5 header, or right after a 40-byte one with BI_ALPHABITFIELDS.
    static func bmpWithoutAlpha(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 70, b[0] == 0x42, b[1] == 0x4D else { return nil }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[at + $1]) << (8 * $1) } }
        let header = u32(14), compression = u32(30)
        guard compression == 3 || compression == 6, header >= 56 || compression == 6 else { return nil }
        var out = b
        out.replaceSubrange(66..<70, with: [0, 0, 0, 0])
        return Data(out)
    }
}
