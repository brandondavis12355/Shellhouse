import UniformTypeIdentifiers
import AppKit
import SwiftUI
import AgentCore

// MARK: - Sidebar visibility (shared with the detail headers)

/// Lets a detail screen's header toggle the sidebar and know whether it is
/// showing (the window's traffic lights float over the top-left corner, so a
/// header that ends up there must leave room for them).
struct SidebarControl {
    var isVisible = true
    var toggle: () -> Void = {}
}

private struct SidebarControlKey: EnvironmentKey {
    static let defaultValue = SidebarControl()
}

extension EnvironmentValues {
    var sidebarControl: SidebarControl {
        get { self[SidebarControlKey.self] }
        set { self[SidebarControlKey.self] = newValue }
    }
}

// MARK: - Cards and rows

/// A rounded group of rows on the canvas — the "grouped inset list" of the
/// reference screens. Put `CardDivider()` between rows.
struct Card<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

struct CardDivider: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, inset)
    }
}

/// Small gray caption above a card ("Bot", "Routines").
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small gray note under a card ("Group Chats can have up to 6 members.").
struct SectionFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row of a card: a title (+ optional subtitle) on the left, anything on
/// the right.
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var titleColor: Color = .primary
    private let trailing: Trailing

    init(_ title: String, subtitle: String? = nil, titleColor: Color = .primary, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.titleColor = titleColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(titleColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

extension SettingRow where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, titleColor: Color = .primary) {
        self.init(title, subtitle: subtitle, titleColor: titleColor) { EmptyView() }
    }
}

/// A row with a green switch on the right.
struct ToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.positive)
        }
    }
}

/// A row with a pop-up menu of choices on the right.
struct PickerRow<Value: Hashable>: View {
    let title: String
    var subtitle: String?
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        SettingRow(title, subtitle: subtitle) {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// A card row that expands inline: title + summary on the header, `content`
/// below when open.
struct ExpandableCard<Content: View>: View {
    let title: String
    var summary: String?
    var symbol: String?
    private let storageKey: String
    private let startsExpanded: Bool
    private let content: Content

    /// The same outlined, collapsible group as `CollapsibleSection` (so every expandable part of the app looks
    /// alike), with its contents on one card. `storageKey` defaults to the title.
    init(_ title: String, summary: String? = nil, symbol: String? = nil, storageKey: String? = nil,
         startsExpanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.storageKey = storageKey ?? "card." + title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.startsExpanded = startsExpanded
        self.content = content()
    }

    var body: some View {
        CollapsibleSection(title, summary: summary, symbol: symbol, storageKey: storageKey, startsExpanded: startsExpanded) {
            Card {
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Message arrival

extension AnyTransition {
    /// How a new chat message enters: fades in while rising and settling into place.
    static var messageArrival: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.97, anchor: .bottom)),
            removal: .opacity
        )
    }
}

/// Styled bubble text, built once per distinct string instead of on every redraw while
/// scrolling (the highlighter is a regex pass over the whole message).
enum StyledTextCache {
    private final class Box { let value: AttributedString; init(_ value: AttributedString) { self.value = value } }
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 600
        return cache
    }()

    static func value(for key: String, make: () -> AttributedString) -> AttributedString {
        if let hit = cache.object(forKey: key as NSString) { return hit.value }
        let value = make()
        cache.setObject(Box(value), forKey: key as NSString)
        return value
    }
}

/// Animates rows that arrive after a chat is already showing, not the initial load of its
/// history. With Reduce Motion on, a short fade only.
struct MessageArrivalAnimation<Value: Equatable>: ViewModifier {
    let value: Value
    @State private var ready = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(ready ? Motion.pick(Motion.settle, reduceMotion: reduceMotion) : nil, value: value)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ready = true } }
    }
}

extension View {
    /// See `MessageArrivalAnimation`. `value` changes when a message is added (e.g. the count).
    func animatesMessageArrival<Value: Equatable>(_ value: Value) -> some View {
        modifier(MessageArrivalAnimation(value: value))
    }
}

/// A whole settings section that folds into one row: its title, a short live summary and a chevron.
/// Expanded, the section's own cards show below that row. Remembers per section whether it was
/// left open.
struct CollapsibleSection<Content: View>: View {
    let title: String
    var summary: String?
    var symbol: String?
    @AppStorage private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content

    init(_ title: String, summary: String? = nil, symbol: String? = nil, storageKey: String, startsExpanded: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self._isExpanded = AppStorage(wrappedValue: startsExpanded, "settings.section.\(storageKey).expanded")
        self.content = content()
    }

    /// Open, the header and everything in it share one outlined group, with the contents indented under a tinted
    /// rail, so it's plain which settings belong to which section (and where the next section starts).
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.pick(Motion.smooth, reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 22)
                    }
                    Text(title).font(.system(size: 15, weight: isExpanded ? .semibold : .regular))
                    Spacer(minLength: 8)
                    if let summary, !isExpanded {
                        Text(summary).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapse" : "Expand")
            if isExpanded {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(alignment: .top, spacing: 0) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent.opacity(0.45)).frame(width: 3)
                        .padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 0) { content }
                        .padding(.leading, 10)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .background(Theme.card.opacity(isExpanded ? 0.45 : 1), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(isExpanded ? Theme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
        }
        .padding(.top, 10)
    }
}

/// A heading over a group of settings sections ("Models", "Safety"…), with a short line on what's in it.
struct SettingsGroupHeader: View {
    let title: String
    let symbol: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.system(size: 17, weight: .bold))
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 26)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Buttons

/// Press feedback without any chrome.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }

    /// Settles in on press and lifts a touch on hover.
    struct PressableBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : (hovering && isEnabled ? 1.04 : 1)))
                .opacity(configuration.isPressed ? 0.75 : 1)
                .brightness(hovering && isEnabled && !configuration.isPressed ? 0.04 : 0)
                .animation(Motion.pick(Motion.settle, reduceMotion: reduceMotion), value: configuration.isPressed)
                .animation(Motion.pick(Motion.quick, reduceMotion: reduceMotion), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// The app's default text button: a soft pill. `.primary` is the white call to
/// action; a `.destructive` role turns the text red.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case secondary, primary }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, compact: compact)
    }

    struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let destructive = configuration.role == .destructive
            configuration.label
                .font(.system(size: compact ? 13 : 14, weight: .medium))
                .foregroundStyle(foreground(destructive: destructive))
                .padding(.horizontal, compact ? 11 : 15)
                .padding(.vertical, compact ? 5 : 8)
                .background(Capsule().fill(background(destructive: destructive)))
                .brightness(hovering && isEnabled && !configuration.isPressed ? 0.05 : 0)
                .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
                .contentShape(Capsule())
                .animation(Motion.pick(Motion.settle, reduceMotion: reduceMotion), value: configuration.isPressed)
                .animation(Motion.pick(Motion.quick, reduceMotion: reduceMotion), value: hovering)
                .animation(Motion.pick(Motion.quick, reduceMotion: reduceMotion), value: isEnabled)
                .onHover { hovering = $0 }
        }

        private func foreground(destructive: Bool) -> Color {
            if destructive { return Theme.destructive }
            return kind == .primary ? Theme.onPrimary : .primary
        }

        private func background(destructive: Bool) -> Color {
            kind == .primary && !destructive ? Theme.primaryFill : Theme.chip
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var primaryPill: PillButtonStyle { PillButtonStyle(kind: .primary) }
    static var compactPill: PillButtonStyle { PillButtonStyle(compact: true) }
}

/// Translucent circle with a glyph — the header and sidebar icon buttons.
struct GlassCircleLabel: View {
    let systemName: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.glass))
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Circle())
    }
}

struct GlassCircleButton: View {
    let systemName: String
    var size: CGFloat = 40
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) { GlassCircleLabel(systemName: systemName, size: size) }
            .buttonStyle(PressableButtonStyle())
            .help(help)
    }
}

/// The header button that shows or hides the sidebar (the desktop stand-in for
/// the reference screens' back chevron).
struct SidebarToggleButton: View {
    @Environment(\.sidebarControl) private var sidebar

    var body: some View {
        GlassCircleButton(
            systemName: sidebar.isVisible ? "sidebar.left" : "sidebar.right",
            help: sidebar.isVisible ? "Hide the sidebar" : "Show the sidebar",
            action: sidebar.toggle
        )
    }
}

/// A "⋯" menu styled like the other glass circles.
struct GlassCircleMenu<Content: View>: View {
    var systemName = "ellipsis"
    var size: CGFloat = 40
    var help = ""
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: { GlassCircleLabel(systemName: systemName, size: size) }
            .menuStyle(.button)
            .buttonStyle(PressableButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help)
    }
}

// MARK: - Fields

private struct ThemedFieldModifier: ViewModifier {
    var onCard: Bool
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(onCard ? Theme.chip : Theme.card, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
    }
}

extension View {
    /// Rounded filled text field. `onCard` picks the fill that contrasts with
    /// the surface it sits on (a card, or the bare canvas).
    func themedField(onCard: Bool = true) -> some View {
        modifier(ThemedFieldModifier(onCard: onCard))
    }

    /// Fill + padding for a `TextEditor`.
    func themedEditor(onCard: Bool = true) -> some View {
        self
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(onCard ? Theme.chip : Theme.card, in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
    }
}

// MARK: - Pills and chips

/// A bot's role, shown next to its name: small gray rounded rectangle.
struct RolePill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A sent file, shown under a message: type tile, filename with a dimmed
/// extension, and what kind of file it is.
struct AttachmentCard: View {
    let filename: String
    let isImage: Bool

    private var ext: String { (filename as NSString).pathExtension }
    private var base: String { (filename as NSString).deletingPathExtension }

    private var title: AttributedString {
        var name = AttributedString(base)
        if !ext.isEmpty {
            var suffix = AttributedString(".\(ext)")
            suffix.foregroundColor = .secondary
            name += suffix
        }
        return name
    }

    private var kind: String {
        if isImage { return "Image" }
        return ext.isEmpty ? "File" : "\(ext.uppercased()) file"
    }

    var body: some View {
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .medium)).lineLimit(1)
                Text(kind).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.chip)
            if ["md", "markdown"].contains(ext.lowercased()) {
                Text("M↓").font(.system(size: 15, weight: .bold)).foregroundStyle(.secondary)
            } else {
                Image(systemName: isImage ? "photo" : "doc.text")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
    }
}

// MARK: - Composer

/// The rounded input pill: your field on the left, actions on the right.
struct ComposerPill<Field: View, Actions: View>: View {
    let field: Field
    let actions: Actions

    init(@ViewBuilder field: () -> Field, @ViewBuilder actions: () -> Actions) {
        self.field = field()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 48pt minimum: a 36pt action button with 6pt above and below is
            // exactly centered on a single line, and stays pinned to the bottom
            // edge (still 6pt in) as the field grows to several lines.
            field
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.leading, 18)
            HStack(spacing: 6) { actions }
                .padding(.trailing, 6)
                .padding(.bottom, 6)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.composerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.composerRadius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// White circle with an up arrow — send (or queue).
struct SendCircleButton: View {
    var isEnabled: Bool
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.onPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.primaryFill))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
    }
}

/// Gray circle with a stop square — halts the current run.
struct StopCircleButton: View {
    var help = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.destructive)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.chip))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }
}

// MARK: - Chat chrome

/// The row across the top of a conversation: round buttons at the edges and a
/// pill in the middle.
struct ChatTopBar<Leading: View, Center: View, Trailing: View>: View {
    @Environment(\.sidebarControl) private var sidebar
    let leading: Leading
    let center: Center
    let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder center: () -> Center, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        // Each slot is wrapped so it is exactly ONE child for the layout, however many views the caller passes.
        TopBarLayout(gap: 12) {
            HStack(spacing: 10) { leading }.fixedSize()
            HStack(spacing: 0) { center }
            HStack(spacing: 10) { trailing }.fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        // The window's traffic lights float over the top-left corner when the
        // sidebar (which normally sits there) is hidden.
        .padding(.leading, sidebar.isVisible ? 0 : 70)
    }
}

/// Leading controls at the left edge, trailing controls at the right edge, and the centered title
/// in the space between. The title stays truly centered while there is room; when there isn't it
/// slides and shrinks (its text truncates) so it can never overlap a button.
struct TopBarLayout: Layout {
    var gap: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let lead = subviews[0].sizeThatFits(.unspecified)
        let trail = subviews[2].sizeThatFits(.unspecified)
        let center = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? (lead.width + trail.width + center.width + gap * 2)
        return CGSize(width: width, height: max(lead.height, center.height, trail.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else {
            // Never pile everything at the origin: lay unexpected children out left to right.
            var x = bounds.minX
            for view in subviews {
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + gap
            }
            return
        }
        let lead = subviews[0].sizeThatFits(.unspecified)
        let trail = subviews[2].sizeThatFits(.unspecified)
        let leadGap = lead.width > 0 ? gap : 0
        let trailGap = trail.width > 0 ? gap : 0
        let available = max(0, bounds.width - lead.width - trail.width - leadGap - trailGap)

        let ideal = subviews[1].sizeThatFits(.unspecified)
        let centerWidth = min(ideal.width, available)
        let centerSize = subviews[1].sizeThatFits(ProposedViewSize(width: centerWidth, height: bounds.height))

        // Ideal spot: centered in the whole bar. Clamp it into the free span between the buttons.
        let freeMin = bounds.minX + lead.width + leadGap
        let freeMax = bounds.maxX - trail.width - trailGap - centerSize.width
        let centered = bounds.midX - centerSize.width / 2
        let x = min(max(centered, freeMin), max(freeMin, freeMax))

        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: centerSize.width, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }
}

/// The centered capsule in a conversation header: avatar(s) and a name.
struct HeaderPill<Leading: View>: View {
    let title: String
    var help = ""
    var action: (() -> Void)?
    let leading: Leading

    init(title: String, help: String = "", action: (() -> Void)? = nil, @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.help = help
        self.action = action
        self.leading = leading()
    }

    var body: some View {
        Button { action?() } label: {
            // Widest form that fits wins: avatars + name, then name alone, then a truncated name.
            ViewThatFits(in: .horizontal) {
                capsule(showLeading: true, truncate: false)
                capsule(showLeading: false, truncate: false)
                capsule(showLeading: false, truncate: true)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(action == nil)
        .help(help)
    }

    private func capsule(showLeading: Bool, truncate: Bool) -> some View {
        HStack(spacing: 8) {
            if showLeading { leading }
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: !truncate, vertical: false)
        }
        .padding(.leading, showLeading ? 8 : 18)
        .padding(.trailing, 18)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(Capsule().fill(Theme.glass))
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// Fades whatever scrolls up under the header, like the reference screens.
struct TopFade: ViewModifier {
    var height: CGFloat = 22
    func body(content: Content) -> some View {
        content.mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: height)
                Color.black
            }
        )
    }
}

extension View {
    func topFade(_ height: CGFloat = 22) -> some View { modifier(TopFade(height: height)) }
}

/// A centered, secondary, tappable one-liner in the transcript ("Ran
/// run_shell…", "Messaged ⬡ Obsidian"). Optionally expands to show `detail`.
struct TranscriptNote<Icon: View, Detail: View>: View {
    let label: String
    var showsChevron = false
    var isExpanded = false
    var action: () -> Void
    let icon: Icon
    let detail: Detail

    init(label: String, showsChevron: Bool = false, isExpanded: Bool = false, action: @escaping () -> Void,
         @ViewBuilder icon: () -> Icon, @ViewBuilder detail: () -> Detail) {
        self.label = label
        self.showsChevron = showsChevron
        self.isExpanded = isExpanded
        self.action = action
        self.icon = icon()
        self.detail = detail()
    }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 6) {
                    icon
                    Text(label).font(.system(size: 14))
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded { detail }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Group avatar cluster

/// The group-chat emblem: members' avatars in a loose 2×2 cluster. Up to four are drawn;
/// with more, a small "+1" / "+2" badge sits on the bottom-right corner. It rebuilds
/// itself whenever the member list (or a member's look) changes.
struct AvatarCluster: View {
    let members: [Bot]
    var size: CGFloat = 96

    static let maxShown = 4
    private var shown: [Bot] { Array(members.prefix(Self.maxShown)) }
    private var overflow: Int { max(0, members.count - Self.maxShown) }

    /// Cell centers as fractions of `size`, for how many avatars are drawn.
    private var slots: [CGPoint] {
        switch shown.count {
        case 0: return []
        case 1: return [CGPoint(x: 0.5, y: 0.5)]
        case 2: return [CGPoint(x: 0.28, y: 0.5), CGPoint(x: 0.72, y: 0.5)]
        case 3: return [CGPoint(x: 0.27, y: 0.27), CGPoint(x: 0.73, y: 0.27), CGPoint(x: 0.5, y: 0.73)]
        default: return [CGPoint(x: 0.27, y: 0.27), CGPoint(x: 0.73, y: 0.27), CGPoint(x: 0.27, y: 0.73), CGPoint(x: 0.73, y: 0.73)]
        }
    }

    private var cell: CGFloat {
        switch shown.count {
        case 1: return size * 0.8
        case 2: return size * 0.58
        default: return size * 0.56
        }
    }

    /// Changes whenever someone joins/leaves, the order changes, or a member's avatar/color is edited.
    private var signature: String {
        shown.map { "\($0.id):\($0.avatarStyle):\($0.colorHex)" }.joined(separator: ",") + "+\(overflow)"
    }

    var body: some View {
        ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, bot in
                if index < slots.count {
                    BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: cell)
                        .position(x: slots[index].x * size, y: slots[index].y * size)
                }
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: max(11, size * 0.14), weight: .bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, size * 0.07)
                    .padding(.vertical, size * 0.03)
                    .background(Capsule().fill(Theme.chip))
                    .overlay(Capsule().strokeBorder(Theme.bg, lineWidth: 2))
                    .position(x: size * 0.86, y: size * 0.9)
            }
        }
        .frame(width: size, height: size)
        .id(signature)
    }
}


// MARK: - Sheets

/// Modal chrome shared by every sheet: round close button at the top-left, a
/// centered title, scrolling content on the black canvas, and an optional
/// action footer.
struct SheetScaffold<Content: View, Footer: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var subtitle: String?
    /// Overrides what the close button does (e.g. Cancel on a draft).
    var onClose: (() -> Void)?
    private let content: Content
    private let footer: Footer

    init(title: String, subtitle: String? = nil, onClose: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 1) {
                    Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                HStack {
                    GlassCircleButton(systemName: "xmark", help: "Close") { (onClose ?? { dismiss() })() }
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView { content.padding(.horizontal, 16).padding(.bottom, 16) }
                .topFade(10)

            footer
        }
        .background(Theme.bg)
        .buttonStyle(.pill)
        .tint(Theme.accent)
    }
}

extension SheetScaffold where Footer == EmptyView {
    init(title: String, subtitle: String? = nil, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, onClose: onClose, content: content) { EmptyView() }
    }
}

/// Bottom bar of a sheet: actions right-aligned.
struct SheetFooter<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        HStack(spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
    }
}

/// Small caption under a chat message saying when it was sent. Hover for the
/// full date. See `MessageTime` for the format.
struct MessageTimestamp: View {
    let date: Date

    var body: some View {
        Text(MessageTime.label(for: date))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .help(MessageTime.full(for: date))
    }
}

/// Save panel for an exported transcript (Markdown, readable as plain text).
@MainActor
func saveTranscript(_ text: String, suggestedName: String) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
    panel.nameFieldStringValue = suggestedName
    panel.canCreateDirectories = true
    panel.begin { response in
        guard response == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save the transcript"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// Debug-mode message editing. The row tracks hover and owns the right-click menu; the bubble itself draws
/// the buttons beside its own edge (`editButtonsBeside`), so they never overlap neighbouring rows.
struct MessageEditActions {
    var visible: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
}

private struct MessageEditActionsKey: EnvironmentKey {
    static let defaultValue: MessageEditActions? = nil
}

extension EnvironmentValues {
    var messageEditActions: MessageEditActions? {
        get { self[MessageEditActionsKey.self] }
        set { self[MessageEditActionsKey.self] = newValue }
    }
}

struct EditableMessage: ViewModifier {
    let enabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .environment(\.messageEditActions, MessageEditActions(visible: hovering, onEdit: onEdit, onDelete: onDelete))
                .onHover { hovering = $0 }
                .contextMenu {
                    Button("Edit message…", action: onEdit)
                    Button("Delete message", role: .destructive, action: onDelete)
                }
        } else {
            content
        }
    }
}

/// The pencil and trash buttons, centred on the bubble's outer edge: to the left of your own messages, to the
/// right of everyone else's. Drawn outside the bubble's frame, so they take no layout space.
struct EditButtonsBeside: ViewModifier {
    let leading: Bool
    @Environment(\.messageEditActions) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: leading ? .leading : .trailing) {
            if let actions {
                HStack(spacing: 2) {
                    Button(action: actions.onEdit) { Image(systemName: "pencil") }.help("Edit message")
                    Button(role: .destructive, action: actions.onDelete) { Image(systemName: "trash") }.help("Delete message")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .fixedSize()
                .alignmentGuide(leading ? .leading : .trailing) { d in leading ? d.width + 8 : -8 }
                .opacity(actions.visible ? 1 : 0)
                .allowsHitTesting(actions.visible)
                .animation(Motion.pick(Motion.quick, reduceMotion: reduceMotion), value: actions.visible)
            }
        }
    }
}

extension View {
    func editableMessage(enabled: Bool, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        modifier(EditableMessage(enabled: enabled, onEdit: onEdit, onDelete: onDelete))
    }

    func editButtonsBeside(leading: Bool) -> some View {
        modifier(EditButtonsBeside(leading: leading))
    }
}

/// The text being edited, for `MessageEditSheet`.
struct MessageEdit: Identifiable {
    let id: String
    var text: String
}

struct MessageEditSheet: View {
    @State var edit: MessageEdit
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit message").font(.system(size: 15, weight: .semibold))
            TextEditor(text: $edit.text)
                .font(.system(size: 14))
                .frame(minWidth: 480, minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            Text("Bots see the edited text from their next turn on.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(edit.text); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(edit.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
    }
}

// MARK: - Motion

/// The app's motion, in one place so every transition feels like the same product: soft, unhurried,
/// never bouncy. With Reduce Motion on, everything falls back to a short fade.
enum Motion {
    /// Content changing place: chat switches, sections opening, cards arriving.
    static let smooth = Animation.smooth(duration: 0.34)
    /// Small state changes: selection, hover, badges, text swaps.
    static let quick = Animation.smooth(duration: 0.2)
    /// Things that should feel physical: press feedback, cards settling in.
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.88)
    static let reduced = Animation.easeOut(duration: 0.15)

    static func pick(_ animation: Animation, reduceMotion: Bool) -> Animation { reduceMotion ? reduced : animation }
}

/// `.animation(Motion.x, value:)` that respects Reduce Motion.
struct MotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(Motion.pick(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }
}

extension AnyTransition {
    /// A card or banner arriving from below and leaving the same way.
    static var cardArrival: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.98, anchor: .bottom)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
        )
    }

    /// One pane replacing another (switching chats).
    static var paneSwap: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.992)), removal: .opacity)
    }
}

/// Marks the very end of a transcript's content. Scrolling to it (rather than to the last message) always
/// lands on the true bottom, whatever the last row's height turns out to be.
enum TranscriptEnd {
    static let id = "transcript-end"

    /// Put after the last message, inside the scrolled content.
    static var marker: some View { Color.clear.frame(height: 1).id(id) }
}

/// A new message glides into view. Deferred one run-loop turn so the new row is laid out first; scrolling to
/// the end marker (outside the lazy list) keeps the animation from stuttering on estimated row heights.
@MainActor
func scrollToEnd(_ proxy: ScrollViewProxy) {
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    DispatchQueue.main.async {
        withAnimation(Motion.pick(.smooth(duration: 0.45), reduceMotion: reduce)) { proxy.scrollTo(TranscriptEnd.id, anchor: .bottom) }
    }
}

/// Opens a transcript already sitting at its newest message. A lazy list keeps refining its row heights for
/// a few frames after it first appears, so one scroll can land short (a blank pane, or a few messages up).
/// This scrolls to the end marker while that settles, keeps the list invisible until it's in place, then
/// fades it in.
struct SettlesAtBottom: ViewModifier {
    let proxy: ScrollViewProxy
    let hasMessages: Bool
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(settled || !hasMessages ? 1 : 0)
            .onAppear {
                guard hasMessages else { settled = true; return }
                for delay in [0.0, 0.03, 0.08, 0.16, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        var instant = Transaction(); instant.disablesAnimations = true
                        withTransaction(instant) { proxy.scrollTo(TranscriptEnd.id, anchor: .bottom) }
                        if delay >= 0.16, !settled {
                            withAnimation(Motion.pick(Motion.quick, reduceMotion: reduceMotion)) { settled = true }
                        }
                    }
                }
            }
    }
}

extension View {
    func settlesAtBottom(_ proxy: ScrollViewProxy, hasMessages: Bool) -> some View {
        modifier(SettlesAtBottom(proxy: proxy, hasMessages: hasMessages))
    }
}
