import SwiftUI
import AgentCore

/// Setup for the experimental smolagents engine (docs/SMOLAGENTS.md): where
/// sandboxes can reach the Mac's token-gated model proxy.
struct AgentEngineSettingsSection: View {
    @State private var config = SmolAgentsService.shared.config
    @State private var status: String?

    private var addressValid: Bool { SmolAgentsService.Config.isPrivateIPv4(config.sandboxAddress) }

    var body: some View {
        CollapsibleSection("Agent engine (experimental)", summary: SmolAgentsService.Config.isPrivateIPv4(config.sandboxAddress) ? "\(config.sandboxAddress):\(config.proxyPort)" : "Not set up", symbol: "shippingbox", storageKey: "agentEngine") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Lets a bot run on smolagents inside its own sandbox. The sandbox reaches your Mac's local models only through a "
                        + "loopback proxy exposed over the existing SSH connection, with a one-run token; no model credentials enter the sandbox. "
                        + "Needs `GatewayPorts clientspecified` on the Linux host's sshd, and a sandbox image built with the runner.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    TextField("Docker bridge address on the Linux host (e.g. 172.18.0.1)", text: $config.sandboxAddress)
                        .themedField()
                    if !config.sandboxAddress.isEmpty && !addressValid {
                        Text("Must be a private IPv4 address (10.x, 172.16–31.x or 192.168.x). Wildcards and public addresses are refused.")
                            .font(.system(size: 12)).foregroundStyle(Theme.warning)
                    }
                    TextField("Address sandboxes use, if different (e.g. egress-proxy in allowlist mode)", text: $config.sandboxVisibleHost)
                        .themedField()
                    HStack {
                        Text("Proxy port").font(.system(size: 14))
                        TextField("18434", value: $config.proxyPort, format: .number.grouping(.never))
                            .themedField().frame(width: 100)
                        Spacer()
                        Button("Save & reconnect") { save() }.disabled(!config.isConfigured)
                    }
                    if let status { Text(status).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .padding(16)
            }
        }
    }

    private func save() {
        SmolAgentsService.shared.config = config
        let host = HostSettingsStore.load()
        AppDelegate.shared?.tunnel.reconfigure(.init(
            host: host.host, user: host.user, managerSocketPath: host.managerSocketPath,
            reverseForwards: SmolAgentsService.reverseForwards()
        ))
        status = "Saved. The tunnel is reconnecting with the model proxy forward (\(config.sandboxAddress):\(config.proxyPort))."
    }
}
