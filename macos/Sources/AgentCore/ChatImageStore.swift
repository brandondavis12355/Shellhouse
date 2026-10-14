import Foundation
import ImageIO

/// Images bots post into chats (`post_screenshot`), kept as files in the app's data folder and referenced from
/// messages by id, so transcripts stay small.
public enum ChatImageStore {
    public static let maxBytes = 10_000_000

    private static var directory: URL {
        let dir = AppData.url("chat-images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saves `data` if it really is an image (PNG, JPEG, GIF or WebP); returns its id.
    public static func save(_ data: Data) -> String? {
        guard data.count <= maxBytes, let ext = imageExtension(of: data) else { return nil }
        let id = UUID().uuidString + "." + ext
        do {
            try data.write(to: directory.appendingPathComponent(id), options: .atomic)
            return id
        } catch {
            return nil
        }
    }

    /// The file for an id from `save`; nil for anything that isn't one of ours (no paths smuggled in).
    public static func url(for id: String) -> URL? {
        guard id.range(of: #"^[0-9A-F-]{36}\.(png|jpg|gif|webp)$"#, options: .regularExpression) != nil else { return nil }
        let url = directory.appendingPathComponent(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What kind of image the bytes are, judged by decoding them, not by a filename.
    public static func imageExtension(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String? else { return nil }
        switch type {
        case "public.png": return "png"
        case "public.jpeg": return "jpg"
        case "com.compuserve.gif": return "gif"
        case "org.webmproject.webp": return "webp"
        default: return nil
        }
    }
}
