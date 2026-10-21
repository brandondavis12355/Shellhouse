import AgentCore
import AppKit
import SwiftUI

/// Cmd+V with a screenshot (or an image, or files copied in Finder) on the pasteboard attaches it to the message, like the paperclip does.
/// Text is left to the field, so ordinary pasting is unchanged. A screenshot is saved (scaled down if it's very large) as "Pasted image …"
/// in a temporary folder and attached from there; it reaches the model as an image the same way a picked image does.
struct PasteIntoMessageBar: ViewModifier {
    let bot: Bot
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let window = event.window, window.isKeyWindow, window.sheetParent == nil, window.attachedSheet == nil,
                  let item = PasteboardAttachments.item(from: .general) else { return event }
            MainActor.assumeIsolated { attach(item) }
            return nil   // handled: the field must not also try to paste it
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    @MainActor private func attach(_ item: PasteboardAttachments.Item) {
        switch item {
        case .files(let urls):
            bot.addAttachments(urls)
        case .image(let png):
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shellhouse-pasted", isDirectory: true)
            if let url = try? PasteboardAttachments.save(png, in: folder) { bot.addAttachments([url]) }
        }
    }
}

extension View {
    /// Cmd+V attaches a pasted screenshot, image or file to this bot's next message.
    func pastesAttachments(into bot: Bot) -> some View { modifier(PasteIntoMessageBar(bot: bot)) }
}

/// A small picture of a pasted or picked image, in place of the generic icon.
struct AttachmentThumbnail: View {
    let url: URL
    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "photo").font(.caption)
        }
    }
}
