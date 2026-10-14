import SwiftUI
import AgentCore

/// Settings › Fast model: the cheap tier for reply checks, small talk and parallel helpers.
struct ModelTiersSettingsSection: View {
    @State private var fastModel = ModelTiers.fastModel
    @State private var embeddingModel = ModelTiers.embeddingModel
    @State private var installed: [String] = []
    @AppStorage(ModelTiers.fastProviderKey) private var provider = "ollama"
    @AppStorage(ModelTiers.fastRemoteBaseURLKey) private var remoteBaseURL = ""
    @AppStorage(ModelTiers.fastRemoteModelKey) private var remoteModel = ""
    @State private var apiKeyInput = ""
    @State private var keySaved = false
    @State private var keyError: String?

    var body: some View {
        CollapsibleSection("Fast model", summary: summary, symbol: "hare", storageKey: "fastModel") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A small model for the quick decisions around each reply (does this need an answer, is it small talk) "
                        + "and for the `ask_helpers` tool that lets a bot run sub-tasks in parallel. Each bot's own model still does "
                        + "the real work. For parallel helpers, Ollama needs OLLAMA_NUM_PARALLEL of 2 or more and room for a second "
                        + "model (OLLAMA_MAX_LOADED_MODELS) — see docs/MODEL_TIERS.md.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Picker("Runs on", selection: $provider) {
                        Text("Local (Ollama)").tag("ollama")
                        Text("Remote (OpenAI-compatible)").tag("remote")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if provider == "remote" {
                        remoteFields
                    } else {
                    HStack {
                        Picker("Fast model", selection: $fastModel) {
                            Text("None (use each bot's model)").tag("")
                            ForEach(installed, id: \.self) { Text($0).tag($0) }
                            if !fastModel.isEmpty && !installed.contains(fastModel) { Text(fastModel).tag(fastModel) }
                        }
                        .labelsHidden()
                        .onChange(of: fastModel) { _, new in ModelTiers.fastModel = new }
                        if let suggestion = ModelTiers.suggestedFastModel(from: installed), fastModel.isEmpty {
                            Button("Use \(suggestion)") { fastModel = suggestion }
                        }
                    }
                    }
                    HStack {
                        Text("Memory embeddings").font(.system(size: 13)).foregroundStyle(.secondary)
                        Picker("Memory embedding model", selection: $embeddingModel) {
                            Text("None (keywords only)").tag("")
                            ForEach(ModelTiers.embeddingModels(from: installed), id: \.self) { Text($0).tag($0) }
                            if !embeddingModel.isEmpty && !installed.contains(embeddingModel) { Text(embeddingModel).tag(embeddingModel) }
                        }
                        .labelsHidden()
                        .onChange(of: embeddingModel) { _, new in ModelTiers.embeddingModel = new }
                    }
                    Text("Lets bots find notes by meaning (\"the github tool\" finds the note about gh). Notes are indexed in the background; "
                        + "the model stays loaded only for a few minutes after use.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .padding(16)
            }
        }
        .task {
            keySaved = ((try? await SecretStore().list()) ?? []).contains { $0.name == ModelTiers.fastRemoteAPIKeySecretName }
            installed = ((try? await OllamaBackend().availableModels()) ?? []).sorted()
            await ModelTiers.autoConfigure()
            fastModel = ModelTiers.fastModel
            embeddingModel = ModelTiers.embeddingModel
            if embeddingModel.isEmpty, let pick = await ModelTiers.resolveEmbeddingModel() { embeddingModel = pick }
        }
    }
}

extension ModelTiersSettingsSection {
    private var summary: String {
        if provider == "remote" { return ModelTiers.fastUsesRemote ? "remote · \(remoteModel)" : "remote · not set up" }
        return fastModel.isEmpty ? "Same as each bot" : fastModel
    }

    @ViewBuilder
    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Presets").font(.caption).foregroundStyle(.secondary)
                Button("Google Gemini") {
                    remoteBaseURL = OpenAICompatibleBackend.geminiBaseURL
                    if remoteModel.isEmpty { remoteModel = "gemini-3.8-flash" }
                }
                Button("OpenAI") { remoteBaseURL = "https://api.openai.com/v1" }
                Spacer()
            }
            TextField("Base URL (https://…)", text: $remoteBaseURL).themedField()
            TextField("Model id (e.g. gemini-3.8-flash)", text: $remoteModel).themedField()
            HStack {
                SecureField(keySaved ? "API key saved — type a new one to replace it" : "API key", text: $apiKeyInput)
                    .themedField()
                    .onSubmit(saveKey)
                Button("Save key", action: saveKey).disabled(apiKeyInput.isEmpty)
            }
            if let keyError { Text(keyError).font(.caption).foregroundStyle(.red) }
            Text(ModelTiers.fastUsesRemote
                 ? "Reply checks, the approval reviewer, quick replies, helpers and lesson reviews use this model for every bot. "
                    + "Each bot's own model still does the real work. Those prompts include parts of the chat, so they go to this provider."
                 : "Needs an https base URL and a model id. Until then, the fast tier stays local.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            do {
                try await SecretStore().put(name: ModelTiers.fastRemoteAPIKeySecretName, value: key, notes: "Fast model API key")
                apiKeyInput = ""; keySaved = true; keyError = nil
            } catch {
                keyError = "Couldn't save the key to the Keychain: \(error.localizedDescription)"
            }
        }
    }
}

/// Settings › Context window: how much conversation each local-model request can hold.
struct ContextWindowSettingsSection: View {
    @AppStorage(OllamaBackend.contextWindowKey) private var window = OllamaBackend.defaultContextWindow

    var body: some View {
        CollapsibleSection("Context window", summary: "\(window / 1024)k tokens", symbol: "text.alignleft", storageKey: "contextWindow") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Context window", selection: $window) {
                        ForEach(OllamaBackend.contextWindowChoices, id: \.self) { Text("\($0 / 1024)k tokens").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("How much of a conversation each request to a local model can hold. Bigger means bots keep more detail "
                        + "before older history is summarized, but Ollama reserves memory for it on every parallel slot "
                        + "(roughly this × OLLAMA_NUM_PARALLEL), and changing it reloads the model once. Bots summarize their "
                        + "history automatically at about two-thirds full. Match your Ollama server's OLLAMA_CONTEXT_LENGTH if you set one.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }
}

/// Settings › Model sharing: how many requests the bots send the local model at once, and who goes first.
struct ModelSchedulingSettingsSection: View {
    @AppStorage(ModelScheduler.slotsKey) private var slots = ModelScheduler.defaultSlots

    var body: some View {
        CollapsibleSection("Model sharing", summary: slots == 0 ? "off" : "\(slots) at a time", symbol: "person.3.sequence", storageKey: "modelScheduling") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Requests at once", selection: $slots) {
                        ForEach(ModelScheduler.slotChoices, id: \.self) { Text($0 == 0 ? "Off" : "\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: slots) { _, _ in Task { await ModelScheduler.shared.settingsChanged() } }
                    Text("How many requests the bots send your local model at once. When more bots want it, the next free "
                        + "turn goes to the bot that needs it most: one you're waiting on in a 1:1 chat, then bots with goal "
                        + "steps ready to work and goal owners with work to review, then bots with open tasks and the busiest "
                        + "ones lately. Waiting also raises a bot's turn, so nobody is left out. Fewer at once makes each "
                        + "reply faster; Off sends everything straight to the model in arrival order.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }
}

/// A token-budget field with an Unlimited switch ("unlimited" is saved as the text, so it round-trips).
struct TokenLimitField: View {
    @Binding var text: String
    var width: CGFloat = 110

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Unlimited", isOn: Binding(
                get: { Bot.isUnlimited(text) },
                set: { text = $0 ? "unlimited" : "200000" }
            ))
            .toggleStyle(.checkbox)
            .help("No token budget for a run. The iteration and time limits and the loop guards still stop a runaway run.")
            if !Bot.isUnlimited(text) {
                TextField("200000", text: $text).themedField().frame(width: width)
            }
        }
    }
}
