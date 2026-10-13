import SwiftUI
import AgentCore

/// Settings › Fast model: the cheap tier for reply checks, small talk and parallel helpers.
struct ModelTiersSettingsSection: View {
    @State private var fastModel = ModelTiers.fastModel
    @State private var embeddingModel = ModelTiers.embeddingModel
    @State private var installed: [String] = []

    var body: some View {
        CollapsibleSection("Fast model", summary: fastModel.isEmpty ? "Same as each bot" : fastModel, storageKey: "fastModel") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A small model for the quick decisions around each reply (does this need an answer, is it small talk) "
                        + "and for the `ask_helpers` tool that lets a bot run sub-tasks in parallel. Each bot's own model still does "
                        + "the real work. For parallel helpers, Ollama needs OLLAMA_NUM_PARALLEL of 2 or more and room for a second "
                        + "model (OLLAMA_MAX_LOADED_MODELS) — see docs/MODEL_TIERS.md.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
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
            installed = ((try? await OllamaBackend().availableModels()) ?? []).sorted()
            await ModelTiers.autoConfigure()
            fastModel = ModelTiers.fastModel
            embeddingModel = ModelTiers.embeddingModel
            if embeddingModel.isEmpty, let pick = await ModelTiers.resolveEmbeddingModel() { embeddingModel = pick }
        }
    }
}

/// Settings › Context window: how much conversation each local-model request can hold.
struct ContextWindowSettingsSection: View {
    @AppStorage(OllamaBackend.contextWindowKey) private var window = OllamaBackend.defaultContextWindow

    var body: some View {
        CollapsibleSection("Context window", summary: "\(window / 1024)k tokens", storageKey: "contextWindow") {
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
