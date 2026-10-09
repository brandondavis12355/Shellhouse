import SwiftUI
import AgentCore

/// The create-group sheet — name plus an up-to-6 member picker. Deliberately
/// no draft-object dance like `startNewBotDraft`'s: creating a
/// `GroupChatSession` has no expensive boot step, so there's nothing to
/// defer — `onCreate` just builds and adds it directly.
struct CreateGroupChatView: View {
    let allBots: [Bot]
    var onCreate: (String, [String]) -> Void
    var onCancel: () -> Void

    @State private var name = ""
    @State private var memberIDs: [String] = []

    var body: some View {
        SheetScaffold(title: "New group chat", onClose: onCancel) {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Name")
                Card {
                    TextField("Group name", text: $name)
                        .themedField()
                        .padding(16)
                }

                SectionLabel("Members (\(memberIDs.count)/\(GroupChatSession.maxMembers))")
                if allBots.isEmpty {
                    Card {
                        SettingRow("Add a bot first", subtitle: "A group chat needs existing bots as members.", titleColor: .secondary)
                    }
                } else {
                    Card {
                        ForEach(Array(allBots.enumerated()), id: \.element.id) { index, bot in
                            let isMember = memberIDs.contains(bot.id)
                            if index > 0 { CardDivider() }
                            HStack(spacing: 12) {
                                BotAvatar(colorHex: bot.colorHex, style: AvatarStyle(rawValue: bot.avatarStyle) ?? .blob, size: 28)
                                Text(bot.name).font(.system(size: 16))
                                Spacer(minLength: 12)
                                Toggle("", isOn: Binding(
                                    get: { isMember },
                                    set: { on in
                                        if on, memberIDs.count < GroupChatSession.maxMembers { memberIDs.append(bot.id) }
                                        else if !on { memberIDs.removeAll { $0 == bot.id } }
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(Theme.positive)
                                .disabled(!isMember && memberIDs.count >= GroupChatSession.maxMembers)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(minHeight: 50)
                        }
                    }
                }
            }
        } footer: {
            SheetFooter {
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Create") { onCreate(name.isEmpty ? "New Group" : name, memberIDs) }
                    .buttonStyle(.primaryPill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(memberIDs.isEmpty)
            }
        }
        .frame(width: 480, height: 560)
    }
}
