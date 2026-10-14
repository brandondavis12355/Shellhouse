import SwiftUI
import AgentCore

/// "Create and paste in new skills" — App Settings, not per-bot, because
/// the skill library itself (bundled + user-added) is shared across every
/// bot; `BotSettingsTab`'s own "Skills" `DisclosureGroup` is just per-bot
/// toggles onto whatever's in this same list.
struct SkillsSettingsSection: View {
    /// Existing bots' own `availableSkills` are only ever loaded once, at
    /// `init` — this is how a newly-added skill actually reaches them
    /// without waiting for a relaunch. See `Bot.refreshAvailableSkills`.
    var onChanged: () -> Void = {}

    @State private var skills: [Skill] = []
    @State private var isAdding = false
    /// Set while editing an existing user skill in place, rather than
    /// creating a new one — `save()` then overwrites this same id instead
    /// of slugifying `newName` into a fresh one, so renaming a skill while
    /// editing doesn't orphan a second file under the old name. `nil` for
    /// a from-scratch "New skill…".
    @State private var editingSkillID: String?
    @State private var newName = ""
    @State private var newDescription = ""
    @State private var newBody = ""
    @State private var errorMessage: String?

    @State private var installPackage = ""
    @State private var installSkillFilter = ""
    @State private var isInstalling = false
    @State private var installStatus: String?

    /// Collapsed by default — there are 40+ bundled skills, and this whole
    /// section otherwise dominates App Settings before you've even looked
    /// at anything else in it.
    @State private var isListExpanded = false
    @State private var isUserListExpanded = false
    @State private var isBuiltInListExpanded = false

    private var userSkills: [Skill] { skills.filter { SkillLibrary.isUserSkill(id: $0.id) } }
    private var builtInSkills: [Skill] { skills.filter { !SkillLibrary.isUserSkill(id: $0.id) } }

    var body: some View {
        CollapsibleSection("Skills", summary: "\(skills.count) skills", symbol: "book.closed", storageKey: "skills") {
            HStack {
                Spacer()
                Spacer()
                Button(isAdding ? "Cancel" : "New skill…") {
                    if isAdding {
                        isAdding = false
                        resetForm()
                    } else {
                        editingSkillID = nil
                        isAdding = true
                    }
                }
                .buttonStyle(.compactPill)
                .padding(.trailing, 4)
            }
            Card {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playbooks a bot can load with its use_skill tool. Built-in ones ship with the app; anything "
                + "added here is saved on this Mac and available to every bot.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if skills.isEmpty {
                Text("No skills found.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                DisclosureGroup("Show \(skills.count) skills", isExpanded: $isListExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !userSkills.isEmpty {
                            DisclosureGroup("Your skills (\(userSkills.count))", isExpanded: $isUserListExpanded) {
                                skillRows(userSkills)
                            }
                        }
                        DisclosureGroup("Built-in (\(builtInSkills.count))", isExpanded: $isBuiltInListExpanded) {
                            skillRows(builtInSkills)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            if isAdding {
                Divider().overlay(Theme.hairline)

                Text(editingSkillID != nil ? "Edit skill" : "New skill").font(.system(size: 15, weight: .semibold))

                TextField("Name (e.g. \"Weekly report\")", text: $newName)
                    .themedField()
                TextField("One-line description, shown in the skill index", text: $newDescription)
                    .themedField()

                Text("Paste the skill's instructions below:")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextEditor(text: $newBody)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(height: 140)
                    .themedEditor()

                if let errorMessage {
                    Text(errorMessage).font(.system(size: 13)).foregroundStyle(Theme.destructive)
                }

                HStack {
                    Spacer()
                    Button(editingSkillID != nil ? "Save changes" : "Save") { save() }
                        .buttonStyle(.primaryPill)
                        .disabled(
                            newName.trimmingCharacters(in: .whitespaces).isEmpty
                                || newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }

            Divider().overlay(Theme.hairline)

            Text("Install from skills.sh").font(.system(size: 15, weight: .semibold))
            Text("Uses `npx skills@latest` (the vercel-labs/skills ecosystem — npmjs.com/package/skills, an "
                + "external, third-party package) to pull down and import a published skill. Needs Node.js.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack {
                TextField("Package, e.g. \"vercel-labs/agent-skills\" or \"notion\"", text: $installPackage)
                    .themedField()
                    .disabled(isInstalling)
                TextField("Skill name (optional — blank installs all)", text: $installSkillFilter)
                    .themedField()
                    .frame(width: 180)
                    .disabled(isInstalling)
                Button(isInstalling ? "Installing…" : "Install") { Task { await installFromRegistry() } }
                    .disabled(isInstalling || installPackage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if isInstalling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Running npx skills@latest — first run downloads the CLI itself, can take a moment.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            if let installStatus {
                Text(installStatus).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(16)
            }
        }
        .task { refresh() }
    }

    private func installFromRegistry() async {
        isInstalling = true
        installStatus = nil
        let result = await SkillInstaller.install(package: installPackage, skill: installSkillFilter)
        isInstalling = false
        switch result {
        case .success(let names):
            installStatus = "Installed: \(names.joined(separator: ", "))"
            installPackage = ""
            installSkillFilter = ""
            refresh()
            onChanged()
        case .failure(let error):
            installStatus = error.localizedDescription
        }
    }

    private func refresh() {
        skills = SkillLibrary.loadAll()
    }

    /// One row per skill — shared between the "Your skills" and
    /// "Built-in" sub-groups so the two lists stay visually identical
    /// apart from which one actually gets edit/delete buttons.
    @ViewBuilder
    private func skillRows(_ list: [Skill]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list) { skill in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(skill.name).font(.system(size: 13, weight: .semibold))
                        if !skill.description.isEmpty {
                            Text(skill.description).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    // Built-in skills ship inside the signed app bundle —
                    // there's nowhere for an edit or a delete to write to,
                    // so neither button exists for them at all, rather
                    // than showing one that would just fail.
                    if SkillLibrary.isUserSkill(id: skill.id) {
                        Button { edit(skill) } label: { Image(systemName: "pencil.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        Button { delete(skill) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    /// Populates the form from an existing user skill's raw content —
    /// frontmatter stripped back out into `newName`/`newDescription` (see
    /// `stripFrontmatter`) so those fields stay the actual source of
    /// truth on save, rather than silently-inert text next to a body that
    /// already carries its own (unedited) frontmatter.
    private func edit(_ skill: Skill) {
        editingSkillID = skill.id
        newName = skill.name
        newDescription = skill.description
        newBody = stripFrontmatter(skill.content)
        isAdding = true
    }

    private func stripFrontmatter(_ content: String) -> String {
        guard content.hasPrefix("---") else { return content }
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3 else { return content }
        return parts[2...].joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !body.isEmpty else { return }

        // If what was pasted already has its own `---` frontmatter (a
        // whole skill file copied in as-is) — only possible when creating
        // fresh, since editing always strips frontmatter into the Name/
        // Description fields above — keep it verbatim rather than
        // wrapping it in a second one built from those fields.
        let content = body.hasPrefix("---") ? body : "---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)"
        // Editing overwrites the SAME id even if the name changed —
        // otherwise renaming while editing would silently create a second
        // file under the new slug and orphan the original.
        let id = editingSkillID ?? SkillLibrary.slugify(name)

        do {
            try SkillLibrary.saveUserSkill(id: id, content: content)
            isAdding = false
            editingSkillID = nil
            resetForm()
            refresh()
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ skill: Skill) {
        try? SkillLibrary.deleteUserSkill(id: skill.id)
        if editingSkillID == skill.id {
            isAdding = false
            editingSkillID = nil
            resetForm()
        }
        refresh()
        onChanged()
    }

    private func resetForm() {
        editingSkillID = nil
        newName = ""
        newDescription = ""
        newBody = ""
        errorMessage = nil
    }
}
