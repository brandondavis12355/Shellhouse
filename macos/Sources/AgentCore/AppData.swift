import Foundation

/// Where the app keeps its own data: `~/Library/Application Support/AICompute`
/// (inside the app's sandbox container when sandboxed).
///
/// The folder keeps its pre-rename name on purpose: renaming it would strand
/// every existing install's bots, transcripts, audit log and SSH key.
public enum AppData {
    public static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AICompute", isDirectory: true)
    }

    /// A subdirectory of `root`, e.g. `url("audit")`. Not created here.
    public static func url(_ subdirectory: String) -> URL {
        root.appendingPathComponent(subdirectory, isDirectory: true)
    }
}
