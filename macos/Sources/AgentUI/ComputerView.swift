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
    private let pointer: AgentPointer?
    private let pointerColorHex: String
    private let keepPointerVisible: Bool
    private let vncURL: URL?
    private let onLoadError: (String) -> Void
    private let onLoadingChange: (Bool) -> Void

    public init(
        vncURL: URL?,
        pointer: AgentPointer? = nil,
        pointerColor: Color = .purple,
        keepPointerVisible: Bool = false,
        onLoadError: @escaping (String) -> Void = { _ in },
        onLoadingChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.pointer = pointer
        self.pointerColorHex = Self.hex(pointerColor)
        self.keepPointerVisible = keepPointerVisible
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
        context.coordinator.show(pointer, colorHex: pointerColorHex, keep: keepPointerVisible, in: view)
    }

    static func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .purple
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    /// Places (and on first use creates) the arrow in the page. `x`, `y` are desktop pixels; the canvas's CSS box and its intrinsic size
    /// give the scale, so the arrow's tip lands on that pixel however noVNC is scaled or offset. Fades 8 s after the last move unless
    /// a task is running (`keep`).
    static func pointerScript(x: Int, y: Int, clicked: Bool, move: Bool, color: String, keep: Bool) -> String {
        """
        (function(){
          var c=document.querySelector('#noVNC_canvas')||document.querySelector('canvas'); if(!c) return;
          var r=c.getBoundingClientRect(), w=c.width||1280, h=c.height||800;
          var el=document.getElementById('shellhouse-ai-pointer');
          if(!el){
            el=document.createElement('div'); el.id='shellhouse-ai-pointer';
            el.style.cssText='position:fixed;left:0;top:0;width:0;height:0;pointer-events:none;z-index:2147483647;opacity:0;transition:transform .6s ease-in-out,opacity .4s;';
            el.innerHTML='<svg width="18" height="26" viewBox="0 0 12.5 20" style="position:absolute;left:0;top:0;overflow:visible;filter:drop-shadow(1px 2px 2px rgba(0,0,0,.4))"><path d="M0 0L0 17L4.2 13.2L7.2 20L10 18.8L7.2 12.2L12.5 12.2Z" stroke="#fff" stroke-width="1" stroke-linejoin="round"/></svg><div style="position:absolute;left:16px;top:20px;font:700 10px -apple-system,sans-serif;color:#fff;padding:1px 5px;border-radius:9px;">AI</div><div class="ring" style="position:absolute;left:-22px;top:-22px;width:44px;height:44px;border-radius:50%;opacity:0;box-sizing:border-box;border:3px solid;"></div>';
            document.body.appendChild(el);
          }
          var col='\(color)';
          el.querySelector('path').setAttribute('fill',col); el.children[1].style.background=col; el.querySelector('.ring').style.borderColor=col;
          if(\(move)){ el.style.transform='translate('+(r.left+\(x)*r.width/w)+'px,'+(r.top+\(y)*r.height/h)+'px)'; }
          el.style.opacity=1; clearTimeout(window.__shaiFade);
          if(!\(keep)){ window.__shaiFade=setTimeout(function(){el.style.opacity=0;},8000); }
          if(\(clicked)){ el.querySelector('.ring').animate([{transform:'scale(.3)',opacity:.95},{transform:'scale(1.6)',opacity:0}],{duration:600,easing:'ease-out'}); }
        })();
        """
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

        private var shownSequence = -1
        private var last: (AgentPointer, String, Bool)?

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChange(false)
            // A reloaded page lost the pointer element: draw it again.
            if let (pointer, colorHex, keep) = last { shownSequence = -1; show(pointer, colorHex: colorHex, keep: keep, in: webView) }
        }

        /// Draws the bot's pointer INSIDE the page, positioned from noVNC's own canvas (its real box and framebuffer size), so it cannot
        /// disagree with where the desktop is drawn: there is no second layer whose frame has to be matched to the page's.
        func show(_ pointer: AgentPointer?, colorHex: String, keep: Bool, in view: WKWebView) {
            guard let pointer else { return }
            last = (pointer, colorHex, keep)
            let moved = pointer.sequence != shownSequence
            shownSequence = pointer.sequence
            view.evaluateJavaScript(ComputerView.pointerScript(x: pointer.x, y: pointer.y, clicked: pointer.clicked && moved, move: moved, color: colorHex, keep: keep), completionHandler: nil)
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
    private let keepPointerVisible: Bool
    private let pointerColor: Color

    public init(state: State, pointer: AgentPointer? = nil, keepPointerVisible: Bool = false, pointerColor: Color = .purple, onLoadError: @escaping (String) -> Void = { _ in }) {
        self.state = state
        self.pointer = pointer
        self.keepPointerVisible = keepPointerVisible
        self.pointerColor = pointerColor
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
                    pointer: pointer,
                    pointerColor: pointerColor,
                    keepPointerVisible: keepPointerVisible,
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
