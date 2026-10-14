import SwiftUI
import AppKit
import AgentCore

/// An image a bot posted (`post_screenshot`), shown in the message bubble. Click for the full size.
struct ChatImageView: View {
    let imageID: String
    @State private var image: NSImage?
    @State private var showingFull = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(440, image.size.width), maxHeight: 340, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                    .onTapGesture { showingFull = true }
                    .help("Click to view full size")
                    .sheet(isPresented: $showingFull) { FullImageSheet(image: image) }
            } else {
                Label("Image unavailable", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: imageID) {
            guard let url = ChatImageStore.url(for: imageID) else { return }
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }
}

private struct FullImageSheet: View {
    let image: NSImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).interpolation(.high)
            }
            .frame(minWidth: 600, idealWidth: min(1200, image.size.width + 40), minHeight: 400, idealHeight: min(900, image.size.height + 40))
            HStack {
                Text("\(Int(image.size.width)) × \(Int(image.size.height))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy image") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
