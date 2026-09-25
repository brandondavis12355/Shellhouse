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
        if view.url != vncURL {
            load(vncURL, into: view)
        }
    }

    private func load(_ url: URL?, into view: WKWebView) {
        guard let url else { return }
        onLoadingChange(true)
        view.load(URLRequest(url: url))
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

    public init(state: State, onLoadError: @escaping (String) -> Void = { _ in }) {
        self.state = state
        self.onLoadError = onLoadError
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
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
