import SwiftUI
import AgentCore

/// Settings › Accuracy: one switch per group of accuracy features. All on by default; the card collapses to a
/// one-line summary and remembers whether you left it open.
struct AccuracySettingsSection: View {
    @State private var tick = 0   // forces a refresh after a switch changes

    private func binding(_ feature: Reliability.Feature) -> Binding<Bool> {
        Binding(get: { _ = tick; return Reliability.isOn(feature) }, set: { Reliability.set(feature, $0); tick += 1 })
    }

    private var summary: String {
        _ = tick
        let on = Reliability.Feature.allCases.filter { Reliability.isOn($0) }.count
        let total = Reliability.Feature.allCases.count
        return on == total ? "All \(total) on" : "\(on) of \(total) on"
    }

    var body: some View {
        CollapsibleSection("Accuracy", summary: summary, symbol: "scope", storageKey: "accuracy") {
            Card {
                ForEach(Array(Reliability.Feature.allCases.enumerated()), id: \.element) { index, feature in
                    if index > 0 { CardDivider() }
                    ToggleRow(title: feature.title, subtitle: feature.detail, isOn: binding(feature))
                }
                CardDivider()
                SettingRow("Recommended settings", subtitle: "Turn every accuracy feature back on.") {
                    Button("Turn all on") { Reliability.resetAll(); tick += 1 }
                        .buttonStyle(.compactPill)
                        .disabled(Reliability.Feature.allCases.allSatisfy { Reliability.isOn($0) })
                }
            }
            SectionFooter("Safety rules, approvals and loop-breaking bug fixes are not affected by these switches.")
        }
    }
}
