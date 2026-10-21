import AgentCore
import SwiftUI
import WebKit

/// The agent's desktop, rendered by embedding the noVNC page that
/// `sandbox-manager`'s Docker backend already serves for each sandbox
/// (`SandboxHandle.metadata["vnc_url"]`).
///
/// Earlier versions of this file used `VZVirtualMachineView` to draw an
/// in-process `Virtualization.framework` VM directly, with no VNC chain at
/// all. That stopped being possible once the "computer" moved to a
/// Linux-hosted Docker container reached over an SSH tunnel (see
/// `RemoteSandboxManager`) — there is no local `VZVirtualMachine` object to
/// point a view at. `WKWebView` embedding noVNC is the direct replacement:
/// one extra network hop instead of zero, but no native VNC client dependency
/// either.
public struct ComputerView: NSViewRepresentable {
    private let vncURL: URL?
    private let onLoadError: (String) -> Void
    private let onLoadingChange: (Bool) -> Void

    public init(
        vncURL: URL?,
        onLoadError: @escaping (String) -> Void = { _ in },
        onLoadingChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.vncURL = vncURL
        self.onLoadError = onLoadError
        self.onLoadingChange = onLoadingChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onLoadError: onLoadError, onLoadingChange: onLoadingChange)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        // WKWebView paints its own background white until the page (and
        // its CSS) has something to show — that's the actual source of the
        // white flash on a new bot, not a gap in `ComputerPanel`'s own
        // "Connecting…" overlay: the overlay IS there underneath the whole
        // time, but a WKWebView is a layer-backed, compositor-level view
        // that paints over SwiftUI siblings in a ZStack regardless of
        // declared front-to-back order. Making it transparent, rather than
        // trying to out-order it, is the standard fix — recommended by
        // Apple's own WebKit engineers for exactly this "flash of white
        // before content loads" case. (`underPageBackgroundColor`, the
        // public equivalent, was tried here briefly on a hunch that this
        // KVC call was crashing the app — it wasn't, and that property
        // doesn't have the same effect anyway, so this reverted back.)
        view.setValue(false, forKey: "drawsBackground")
        load(vncURL, into: view)
        return view
    }

    public func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != vncURL.map(Self.withPointerDot) {
            load(vncURL, into: view)
        }
    }

    private func load(_ url: URL?, into view: WKWebView) {
        guard let url else { return }
        onLoadingChange(true)
        view.load(URLRequest(url: Self.withPointerDot(url)))
    }

    /// noVNC's "show dot when no cursor": if the server sends no pointer image (x11vnc started with `-noxfixes` does not), the
    /// viewer still marks where the pointer is, so a person can see where a bot is clicking. A real cursor shape from the server
    /// is drawn as it is and the dot stays out of the way.
    static func withPointerDot(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = parts.queryItems ?? []
        guard !items.contains(where: { $0.name == "show_dot" }) else { return url }
        items.append(URLQueryItem(name: "show_dot", value: "true"))
        parts.queryItems = items
        return parts.url ?? url
    }

    /// Surfaces load failures instead of leaving a silent black rectangle —
    /// a WKWebView that fails to reach the tunnel looks identical to noVNC's
    /// own "no video signal yet" black screen otherwise. Also reports
    /// loading start/end so `ComputerPanel` can show a "Connecting…" state
    /// instead of that same blank black rectangle while the page (and then
    /// noVNC's own handshake) is still in flight.
    public final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoadError: (String) -> Void
        private let onLoadingChange: (Bool) -> Void

        init(onLoadError: @escaping (String) -> Void, onLoadingChange: @escaping (Bool) -> Void) {
            self.onLoadError = onLoadError
            self.onLoadingChange = onLoadingChange
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChange(false)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
            onLoadError(error.localizedDescription)
        }

        public func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onLoadingChange(false)
            onLoadError(error.localizedDescription)
        }
    }
}

/// Where the bot last put the mouse, for the arrow drawn over the desktop. `sequence` changes with every move or click, so the same spot
/// clicked twice still shows twice.
public struct AgentPointer: Equatable {
    public var x: Int
    public var y: Int
    public var clicked: Bool
    public var sequence: Int
    public init(x: Int, y: Int, clicked: Bool, sequence: Int) { self.x = x; self.y = y; self.clicked = clicked; self.sequence = sequence }
}

/// An arrow cursor with an "AI" tag, drawn over the desktop pane at the bot's pointer, gliding between positions and rippling on a click,
/// then fading out after a few idle seconds. It is drawn by the app from what the tool results report, so it needs nothing from the VM
/// (the remote desktop sends no pointer image) and cannot be mistaken for your own mouse.
struct AgentPointerOverlay: View {
    let pointer: AgentPointer?
    @State private var visible = false
    @State private var rippling = false

    var body: some View {
        GeometryReader { geo in
            if let pointer {
                let rect = PointerMapping.fit(into: geo.size)
                let spot = PointerMapping.point(x: pointer.x, y: pointer.y, in: rect)
                ZStack(alignment: .topLeading) {
                    if pointer.clicked {
                        Circle().stroke(Color.orange, lineWidth: 3)
                            .frame(width: 44, height: 44)
                            .scaleEffect(rippling ? 1.6 : 0.3).opacity(rippling ? 0 : 0.95)
                            .position(x: 0, y: 0)
                            .id(pointer.sequence)
                    }
                    ArrowShape()
                        .fill(Color.black)
                        .overlay(ArrowShape().stroke(Color.white, lineWidth: 1.6))
                        .frame(width: 18, height: 26)
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 1, y: 2)
                    Text("AI")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple))
                        .offset(x: 16, y: 20)
                }
                .position(spot)
                .opacity(visible ? 1 : 0)
                .animation(.easeInOut(duration: 0.45), value: pointer.sequence)
                .animation(.easeOut(duration: 0.4), value: visible)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: pointer?.sequence) { _, _ in
            visible = true
            rippling = false
            withAnimation(.easeOut(duration: 0.6)) { rippling = true }
            let mark = pointer?.sequence
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if pointer?.sequence == mark { visible = false }
            }
        }
    }
}

/// The classic arrow, tip at the top left.
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 17), (4.2, 13.2), (7.2, 20), (10, 18.8), (7.2, 12.2), (12.5, 12.2)]
        let sx = rect.width / 12.5, sy = rect.height / 20
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + points[0].0 * sx, y: rect.minY + points[0].1 * sy))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: rect.minX + p.0 * sx, y: rect.minY + p.1 * sy)) }
        path.closeSubpath()
        return path
    }
}

/// Wraps ComputerView with the states a sandbox can actually be in, so the
/// user sees why there is no desktop rather than a black rectangle.
public struct ComputerPanel: View {
    public enum State {
        case noSandbox
        case booting(String)
        case running(vncURL: URL)
        case suspended
        case failed(String)
    }

    private let state: State
    private let onLoadError: (String) -> Void
    /// True from the moment a `.running` URL starts loading until the
    /// WKWebView's `didFinish`/`didFail` fires — see `ComputerView`'s
    /// `onLoadingChange`. Reset per-URL by the `.onChange` below, since a
    /// reconnect to a new `vncURL` should show "Connecting…" again too.
    @State private var isConnecting = true

    private let pointer: AgentPointer?

    public init(state: State, pointer: AgentPointer? = nil, onLoadError: @escaping (String) -> Void = { _ in }) {
        self.state = state
        self.pointer = pointer
        self.onLoadError = onLoadError
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay { if case .running = state { AgentPointerOverlay(pointer: pointer) } }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if case .running = state {
                HStack(spacing: 12) {
                    Spacer()
                    Text("Click inside to take control")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .noSandbox:
            placeholder(
                icon: "desktopcomputer",
                title: "No computer running",
                detail: "Start a task and one will be created."
            )

        case .booting(let id):
            VStack(spacing: 10) {
                ProgressView()
                Text("Starting \(id)…")
                    .font(.title3)
                Text("A fresh sandbox container takes a couple of seconds to start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .running(let vncURL):
            ZStack {
                ComputerView(
                    vncURL: vncURL,
                    onLoadError: onLoadError,
                    onLoadingChange: { isConnecting = $0 }
                )
                if isConnecting {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Connecting…")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    // Opaque, not just an overlay tint — otherwise this
                    // reads as a flash of the same "blank black" state this
                    // exists to replace, just with a spinner glued on top.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            }
            .onChange(of: vncURL) { _, _ in isConnecting = true }

        case .suspended:
            placeholder(
                icon: "pause.circle",
                title: "Computer suspended",
                detail: "Its container is paused. Resuming restores open windows and processes."
            )

        case .failed(let message):
            placeholder(
                icon: "exclamationmark.triangle",
                title: "Computer unavailable",
                detail: message
            )
        }
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }
}
