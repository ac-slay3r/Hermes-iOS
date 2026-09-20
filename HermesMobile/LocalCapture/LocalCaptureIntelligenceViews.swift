import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Optional entry-point status; refresh checks availability only, never generates.
@MainActor
struct LocalCaptureIntelligenceCapabilityView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: LocalCaptureIntelligenceCapability
    private let provider: any LocalCaptureIntelligenceProviding

    init() { self.init(provider: LocalCaptureIntelligenceSystemProvider()) }

    init(provider: any LocalCaptureIntelligenceProviding) {
        self.provider = provider
        _status = State(initialValue: provider.capability())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("On-device AI review", systemImage: "sparkles")
                .font(.headline)
            Text(status.message).font(.subheadline)
            Text("Text only. Optional. No server or cloud fallback.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check availability") { status = provider.capability() }
        }
        .onAppear { status = provider.capability() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { status = provider.capability() }
        }
    }
}

/// Pass a value snapshot such as capture.text, never a binding to the original.
/// Showing the sheet does not generate; the Review button is the only start path.
@MainActor
struct LocalCaptureIntelligenceReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: LocalCaptureIntelligenceReviewModel
    @State private var draft: String
    @State private var copied = false

    init(text: String) {
        self.init(text: text, provider: LocalCaptureIntelligenceSystemProvider())
    }

    init(text: String, provider: any LocalCaptureIntelligenceProviding) {
        _draft = State(initialValue: text)
        _model = State(initialValue: LocalCaptureIntelligenceReviewModel(provider: provider))
    }

    private var inputIsValid: Bool {
        (try? LocalCaptureIntelligenceInput(text: draft)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Local capability") {
                    Text(model.capability.message)
                    Text("Apple's on-device model only. Nothing is sent to Hermes or a cloud model. Media files are not reviewed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Check availability") { model.refreshCapability() }
                }
                Section {
                    TextEditor(text: $draft)
                        .frame(minHeight: 140)
                        .accessibilityLabel("Text to review, copy of original")
                        .disabled(model.phase == .reviewing)
                    Text("\(draft.utf8.count) / \(LocalCaptureIntelligenceInput.maximumUTF8Bytes) UTF-8 bytes")
                        .font(.caption)
                    if !inputIsValid {
                        Text("Enter text or shorten this copy to 2,000 UTF-8 bytes. It will never be silently truncated.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Text to review")
                } footer: {
                    Text("This is a temporary copy. Editing it does not change the original capture. Only this text is given to the model.")
                }
                Section {
                    Button("Review on device") {
                        copied = false
                        model.start(text: draft)
                    }
                    .disabled(!model.capability.isAvailable || !inputIsValid || model.phase == .reviewing || scenePhase != .active)
                    phaseContent
                }
                if model.suggestions != nil {
                    Section {
                        Text("AI suggestions can be wrong. Check against your original. Nothing is saved, applied, scheduled or sent.")
                            .font(.caption)
                        TextField("Suggested title", text: suggestionBinding(\.title), axis: .vertical)
                        TextField("Short summary", text: suggestionBinding(\.summary), axis: .vertical)
                        if let suggestions = model.suggestions {
                            if suggestions.tasks.isEmpty { Text("No tasks suggested.").foregroundStyle(.secondary) }
                            ForEach(suggestions.tasks.indices, id: \.self) { index in
                                TextField("Proposed task \(index + 1)", text: taskBinding(index), axis: .vertical)
                            }
                        }
                        Button(copied ? "Copied — copy again" : "Copy suggestions (local clipboard)") {
                            copySuggestions()
                        }
                    } header: {
                        Text("Editable suggestions only")
                    } footer: {
                        Text("Suggestions disappear when this sheet closes or the app leaves the foreground. Explicit Copy uses a local-only clipboard item that expires after two minutes; other apps on this device may read it.")
                    }
                }
            }
            .navigationTitle("Review on device")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.cancel(message: "Review dismissed.")
                        dismiss()
                    }
                }
            }
        }
        .onAppear { model.refreshCapability() }
        .onChange(of: draft) { _, _ in
            copied = false
            model.cancel(message: "Text changed. Tap Review to review this version.")
        }
        .onDisappear { model.cancel(message: "Review dismissed.") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refreshCapability()
            } else {
                copied = false
                model.cancel(message: "Review cancelled because the app left the foreground.")
            }
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .idle:
            Text("Tap Review when you are ready. No analysis runs automatically.").font(.caption)
        case .reviewing:
            ProgressView("Reviewing on this device…")
            Button("Cancel review", role: .cancel) { model.cancel() }
        case .ready:
            Text("Suggestions ready — original unchanged.").font(.caption)
        case .unavailable(let message), .failed(let message), .cancelled(let message):
            Text(message).font(.subheadline)
        }
    }

    private func suggestionBinding(_ keyPath: WritableKeyPath<LocalCaptureIntelligenceSuggestions, String>) -> Binding<String> {
        Binding(
            get: { model.suggestions?[keyPath: keyPath] ?? "" },
            set: { model.suggestions?[keyPath: keyPath] = $0 }
        )
    }

    private func taskBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let result = model.suggestions, result.tasks.indices.contains(index) else { return "" }
                return result.tasks[index]
            },
            set: { value in
                guard var result = model.suggestions, result.tasks.indices.contains(index) else { return }
                result.tasks[index] = value
                model.suggestions = result
            }
        )
    }

    private func copySuggestions() {
        guard let result = model.suggestions else { return }
        let tasks = result.tasks.map { "• " + $0 }.joined(separator: "\n")
        let text = [result.title, result.summary, tasks].filter { !$0.isEmpty }.joined(separator: "\n\n")
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(120)
        ])
        copied = true
    }
}
