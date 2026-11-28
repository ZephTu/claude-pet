#if canImport(AppKit)
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
    /// What the board's web view turns into an image itself when it is pasted (an image file
    /// copied in Finder included).
    static let webReadable: Set<String> = Set(asIs.map(\.type) + ["public.tiff", "public.file-url"])

    /// The image on `pb` as (bytes, MIME type): PNG, JPEG or GIF as they are, then the other
    /// types AppKit decodes (TIFF, BMP, HEIC …) as PNG — those the pasteboard's items really hold
    /// before those AppKit derives from them (the TIFF it offers for a BMP), so a BMP is decoded
    /// once, from itself. Last, whatever NSImage makes of it (a PDF). Nil when there is none.
    public static func read(_ pb: NSPasteboard) -> (data: Data, mime: String)? {
        let types = (pb.types ?? []).map(\.rawValue)
        for (type, mime) in asIs where types.contains(type) {
            if let d = pb.data(forType: .init(type)), NSBitmapImageRep(data: d) != nil { return (d, mime) }
        }
        let held = (pb.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
        var others: [String] = []
        for type in held + types where NSImage.imageTypes.contains(type) && !others.contains(type)
            && !asIs.contains(where: { $0.type == type }) && type != "com.adobe.pdf" { others.append(type) }
        var clear: Data?   // one that decodes to nothing but transparent pixels: the last resort
        for type in others {
            guard let d = pb.data(forType: .init(type)), let png = png(from: d) else { continue }
            if !png.clear { return (png.data, "image/png") }
            if clear == nil { clear = png.data }
        }
        if let clear { return (clear, "image/png") }
        if let tiff = NSImage(pasteboard: pb)?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return (png, "image/png")
        }
        return nil
    }

    /// The image to hand the board's web view on a paste, when it would see none itself: the
    /// pasteboard's items hold no type it reads (a BMP from Deskflow, say — AppKit offers a TIFF
    /// made from it, but the web view goes by what the items really hold) and no text either, so
    /// cells copied with a picture of them still paste as text. Nil otherwise.
    public static func forWeb(_ pb: NSPasteboard) -> (data: Data, mime: String)? {
        let held = Set((pb.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        guard !held.isEmpty, held.isDisjoint(with: webReadable), pb.string(forType: .string) == nil else { return nil }
        return read(pb)
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
    /// The mask is in a V3/V4/V5 header with BI_BITFIELDS, at byte 66 (after the file header, the
    /// 40-byte info header and the red, green and blue masks). ImageIO doesn't decode
    /// BI_ALPHABITFIELDS at all, so that one is left alone.
    static func bmpWithoutAlpha(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 70, b[0] == 0x42, b[1] == 0x4D else { return nil }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[at + $1]) << (8 * $1) } }
        let header = u32(14), compression = u32(30)
        guard compression == 3, header >= 56 else { return nil }
        var out = b
        out.replaceSubrange(66..<70, with: [0, 0, 0, 0])
        return Data(out)
    }
}
#endif
