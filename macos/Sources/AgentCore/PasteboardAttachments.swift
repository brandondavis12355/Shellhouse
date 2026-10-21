import AppKit
import Foundation
import ImageIO

/// What a paste into the message bar should attach, read from the pasteboard. Text is left alone (the field pastes it itself);
/// files copied in Finder attach as files; a screenshot or a copied image attaches as a PNG. Files win over text because Finder puts
/// the file's name on the pasteboard as text too.
public enum PasteboardAttachments {
    public enum Item: Equatable {
        case files([URL])
        case image(Data)   // PNG
    }

    public static func item(from pasteboard: NSPasteboard) -> Item? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        if pasteboard.string(forType: .string)?.isEmpty == false { return nil }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = pasteboard.data(forType: type), let png = pngData(from: data) { return .image(png) }
        }
        return nil
    }

    /// Any image data as PNG, or nil if it isn't an image.
    public static func pngData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A Retina screenshot is megabytes of PNG, and a vision model reads at most a couple of thousand pixels anyway: anything
    /// larger than `maxDimension` on its long side is scaled down to that, same aspect ratio. Smaller images are returned as they are.
    public static func limited(_ png: Data, maxDimension: Int = 1_600) -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              max(w, h) > maxDimension else { return png }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxDimension]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return png }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return png }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : png
    }

    /// "Pasted image 2026-10-21 12.45.01.png", numbered when that name is taken.
    public static func fileName(at date: Date, existing: (String) -> Bool = { _ in false }) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Pasted image \(f.string(from: date))"
        var name = base + ".png", n = 2
        while existing(name) { name = "\(base) (\(n)).png"; n += 1 }
        return name
    }

    /// Saves a pasted image where it can be attached, and removes pasted images left over from earlier than `keepFor` seconds ago.
    public static func save(_ png: Data, in directory: URL, now: Date = Date(), keepFor: TimeInterval = 86_400) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for old in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = (try? old.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               now.timeIntervalSince(modified) > keepFor, old.lastPathComponent.hasPrefix("Pasted image ") {
                try? manager.removeItem(at: old)
            }
        }
        let name = fileName(at: now) { manager.fileExists(atPath: directory.appendingPathComponent($0).path) }
        let url = directory.appendingPathComponent(name)
        try limited(png).write(to: url, options: .atomic)
        return url
    }
}
