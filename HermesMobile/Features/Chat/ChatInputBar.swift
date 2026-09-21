import Speech
import SwiftUI

/// Assistance edits a draft only; sending remains a separate explicit action.
enum ComposerAssistance: String, CaseIterable {
    case summarize = "Summarize"
    case nextSteps = "Find next steps"

    func draft(existing: String, hasAttachments: Bool) -> String {
        let prompt: String
        switch self {
        case .summarize:
            prompt = hasAttachments ? "Summarize the attached material." : "Help me summarize this conversation."
        case .nextSteps:
            prompt = hasAttachments ? "Identify next steps from the attached material." : "Help me identify next steps."
        }
        return existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? prompt : existing + "\n\n" + prompt
    }
}

struct ChatInputBar: View {
    @Binding var text: String
    @Binding var pendingAttachments: [PendingAttachment]
    let isStreaming: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onStop: () -> Void
    let onAttach: () -> Void
    let onSlashCommand: (SlashCommand, String?) -> Void

    var commandCatalog: [SlashCommand] = SlashCommand.allBuiltIn
    var pinnedCommandIDs: [String] = []
    var allowsDictation = true

    @State private var speechService = LiveSpeechService()
    @State private var dictationBaseText = ""
    @State private var dictationError: String?
    @State private var showCommandPalette = false

    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !pendingAttachments.isEmpty
        let hasRunnableSlashCommand = isSlashMode && hasText && text.trimmingCharacters(in: .whitespacesAndNewlines) != "/" && !hasAttachments
        return hasRunnableSlashCommand || ((hasText || hasAttachments) && !isSlashMode)
    }

    private var isSlashMode: Bool {
        text.hasPrefix("/")
    }

    /// Parses the command and any trailing argument from the text field.
    private var parsedSlashInput: (command: String, argument: String?) {
        let raw = String(text.dropFirst()).lowercased()
        let parts = raw.split(separator: " ", maxSplits: 1)
        let cmd = parts.first.map(String.init) ?? raw
        let arg = parts.count > 1 ? String(parts[1]) : nil
        return (cmd, arg)
    }

    /// Uses the dynamic catalog from ChatStore (fetched from the Hermes host).
    /// Falls back to the built-in list if the catalog hasn't loaded yet.
    private var filteredCommands: [SlashCommand] {
        let query = parsedSlashInput.command.lowercased()
        let argument = parsedSlashInput.argument?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = commandCatalog.filter(\.showInAutocomplete)

        if query.isEmpty {
            return all.filter { $0.suggestedArgument == nil }
        }

        if let exact = all.first(where: { $0.name == query && $0.suggestedArgument == nil }), exact.acceptsArgument {
            let argumentSuggestions = all.filter { command in
                command.name == query
                    && command.suggestedArgument != nil
                    && (argument == nil
                        || argument!.isEmpty
                        || command.suggestedArgument!.lowercased().hasPrefix(argument!))
            }
            if !argumentSuggestions.isEmpty {
                return argumentSuggestions
            }
            return [exact]
        }

        return all.filter {
            $0.suggestedArgument == nil && $0.name.hasPrefix(query)
        }
    }

    private var displayedCommands: [SlashCommand] {
        if isSlashMode { return filteredCommands }
        return commandCatalog.filter { $0.suggestedArgument == nil || pinnedCommandIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: Design.Spacing.xs) {
            if (isSlashMode || showCommandPalette) && !displayedCommands.isEmpty {
                SlashCommandMenu(commands: displayedCommands, pinnedCommandIDs: pinnedCommandIDs) { command in
                    if showCommandPalette {
                        let suffix = command.suggestedArgument.map { " \($0)" }
                            ?? (command.acceptsArgument ? " " : "")
                        text = "/\(command.name)\(suffix)"
                        showCommandPalette = false
                        isFocused.wrappedValue = true
                        return
                    }
                    let arg = command.suggestedArgument ?? (command.acceptsArgument ? parsedSlashInput.argument : nil)
                    text = ""
                    showCommandPalette = false
                    onSlashCommand(command, arg)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let dictationError {
                Text(dictationError)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Colors.secondaryForeground)
                    .padding(.horizontal, Design.Spacing.md)
            }

            // Composer container
            VStack(spacing: 0) {
                // Attachment preview strip
                if !pendingAttachments.isEmpty {
                    attachmentPreviewStrip
                }

                // Text input area
                TextField(
                    speechService.isListening ? "Listening..." : "Reply to Hermes",
                    text: $text,
                    axis: .vertical
                )
                    .accessibilityIdentifier("chat.composer")
                    .accessibilityLabel("Reply to Hermes")
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Colors.foreground)
                    .lineLimit(1...5)
                    .focused(isFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        if canSend {
                            handlePrimaryAction()
                        }
                    }
                    .padding(.horizontal, Design.Spacing.md)
                    .padding(.top, pendingAttachments.isEmpty ? Design.Spacing.sm : Design.Spacing.xs)
                    .padding(.bottom, Design.Spacing.xs)

                // Bottom action bar
                HStack(spacing: Design.Spacing.xs) {
                    // + Attachment button
                    Button(action: onAttach) {
                        Image(systemName: "plus")
                            .font(.system(size: Design.Size.iconMedium, weight: .medium))
                            .foregroundStyle(Design.Colors.secondaryForeground)
                            .frame(minWidth: Design.Size.minTapTarget, minHeight: Design.Size.minTapTarget)
                            .background(Design.Colors.surface)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Add attachment")

                    assistanceMenu

                    Button {
                        showCommandPalette.toggle()
                    } label: {
                        Image(systemName: "command")
                            .font(.system(size: Design.Size.iconMedium, weight: .medium))
                            .foregroundStyle(showCommandPalette ? Design.Brand.accent : Design.Colors.secondaryForeground)
                            .frame(minWidth: Design.Size.minTapTarget, minHeight: Design.Size.minTapTarget)
                    }
                    .accessibilityLabel("Browse commands")

                    Spacer()

                    // Dictation mic button
                    if !isStreaming {
                        Button {
                            toggleDictation()
                        } label: {
                            Label(speechService.isListening ? "Stop" : "Dictate", systemImage: speechService.isListening ? "stop.fill" : "mic")
                                .font(.system(size: Design.Size.iconMedium, weight: .medium))
                                .foregroundStyle(speechService.isListening ? .red : Design.Colors.secondaryForeground)
                                .frame(minWidth: Design.Size.minTapTarget, minHeight: Design.Size.minTapTarget)
                                .background(speechService.isListening ? Design.Colors.surface : .clear)
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel(speechService.isListening ? "Stop dictation" : "Dictate text")
                        .accessibilityHint("Adds words to your draft. Review before sending.")
                        .disabled(!allowsDictation)
                    }

                    // Send / Stop button
                    actionButton
                }
                .padding(.horizontal, Design.Spacing.sm)
                .padding(.bottom, Design.Spacing.sm)
            }
            .background(Design.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: Design.CornerRadius.xxl))
            .padding(.horizontal, Design.Spacing.md)
            .padding(.bottom, Design.Spacing.md)
        }
        .animation(Design.Motion.quickResponse, value: isSlashMode)
        .animation(Design.Motion.quickResponse, value: isStreaming)
        .animation(Design.Motion.quickResponse, value: canSend)
        .onAppear {
            speechService.onTranscriptChange = { partialTranscript in
                text = mergedDictationText(partialTranscript)
            }
            speechService.onAutoStop = { finalTranscript in
                text = mergedDictationText(finalTranscript)
                dictationBaseText = ""
            }
        }
    }

    private var assistanceMenu: some View {
        Menu {
            Section("Prepare a draft") {
                ForEach(ComposerAssistance.allCases, id: \.self) { action in
                    Button(action.rawValue) {
                        text = action.draft(existing: text, hasAttachments: !pendingAttachments.isEmpty)
                        isFocused.wrappedValue = true
                    }
                }
            }
            Section("Voice and notes") {
                Text("Dictate adds text for review; it does not start a conversation.")
                Label("Live conversation — unavailable", systemImage: "waveform")
                Text("Host and input authorization is not connected yet.")
                Label("Take notes — unavailable here", systemImage: "note.text")
                Text("Note capture is not connected to this composer.")
            }
        } label: {
            Label("Assist", systemImage: "sparkles")
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Colors.secondaryForeground)
                .frame(minHeight: Design.Size.minTapTarget)
        }
        .disabled(isStreaming || speechService.isListening || isSlashMode)
        .accessibilityIdentifier("chat.assistance")
        .accessibilityHint("Prepare a draft to review, or check voice and notes availability.")
    }

    // MARK: - Attachment Preview Strip

    private var attachmentPreviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Design.Spacing.sm) {
                ForEach(pendingAttachments) { attachment in
                    attachmentThumbnail(attachment)
                }
            }
            .padding(.horizontal, Design.Spacing.md)
            .padding(.top, Design.Spacing.sm)
            .padding(.bottom, Design.Spacing.xxs)
        }
    }

    private func attachmentThumbnail(_ attachment: PendingAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbData = attachment.thumbnailData,
                   let uiImage = UIImage(data: thumbData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // File icon fallback
                    VStack(spacing: 4) {
                        Image(systemName: fileIcon(for: attachment.mimeType))
                            .font(.system(size: 20))
                            .foregroundStyle(Design.Colors.secondaryForeground)
                        Text(attachment.fileName)
                            .font(Design.Typography.caption)
                            .foregroundStyle(Design.Colors.secondaryForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Design.Colors.surface)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: Design.CornerRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Design.CornerRadius.sm)
                    .stroke(Design.Colors.divider, lineWidth: 1)
            )

            // Remove button
            Button {
                withAnimation(Design.Motion.quickResponse) {
                    pendingAttachments.removeAll { $0.id == attachment.id }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Design.Colors.foreground)
                    .background(Circle().fill(Design.Colors.background).padding(2))
            }
            .accessibilityLabel("Remove attachment \(attachment.fileName)")
            .offset(x: 6, y: -6)
        }
    }

    private func fileIcon(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    @ViewBuilder
    private var actionButton: some View {
        if isStreaming {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Design.Colors.foreground)
                    .frame(minWidth: Design.Size.minTapTarget, minHeight: Design.Size.minTapTarget)
                    .background(Design.Colors.surface)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Interrupt response")
            .accessibilityHint("Stops receiving this response. A running remote tool may continue.")
            .accessibilityIdentifier("chat.interrupt")
        } else if canSend {
            Button(action: handlePrimaryAction) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Design.Colors.background)
                    .frame(minWidth: Design.Size.minTapTarget, minHeight: Design.Size.minTapTarget)
                    .background(Design.Brand.accent)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Send message")
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Dictation

    private func toggleDictation() {
        guard allowsDictation else { return }
        dictationError = nil
        if speechService.isListening {
            speechService.stopListening()
            text = mergedDictationText(speechService.transcript)
            dictationBaseText = ""
        } else {
            Task {
                do {
                    dictationBaseText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await speechService.startListening()
                } catch {
                    dictationBaseText = ""
                    dictationError = "Dictation unavailable. You can keep typing. " + error.localizedDescription
                }
            }
        }
    }

    private func handlePrimaryAction() {
        if speechService.isListening {
            speechService.stopListening()
            text = mergedDictationText(speechService.transcript)
            dictationBaseText = ""
        }
        onSend()
    }

    private func mergedDictationText(_ transcript: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = dictationBaseText.trimmingCharacters(in: .whitespacesAndNewlines)

        if base.isEmpty { return trimmedTranscript }
        if trimmedTranscript.isEmpty { return base }
        return "\(base) \(trimmedTranscript)"
    }
}

/// Component-only preview: no container, persistence, host, sensors or transport.
/// The existing mock container still constructs live sensors, so do not use it here.
struct ChatComposerLab: View {
    @State private var text = ""
    @State private var attachments: [PendingAttachment] = []
    @State private var isStreaming = false
    @State private var notice = "Sample activity only. Nothing is sent or recorded."
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.md) {
            Text("Hermes · Component preview")
                .font(Design.Typography.headline)
            Text("Experimental composer lab. Temporary drafts are discarded when you leave. Connected chat, dictation, attachments and approvals are not available here.")
                .font(Design.Typography.footnote)
            Text(notice)
                .font(Design.Typography.caption)
            Toggle("Preview a response in progress", isOn: $isStreaming)
            ToolActivityRail(
                activities: [ToolActivity(label: "web_search", isActive: true)],
                isStreaming: isStreaming
            )
            Spacer()
            ChatInputBar(
                text: $text,
                pendingAttachments: $attachments,
                isStreaming: isStreaming,
                isFocused: $focused,
                onSend: { notice = "Preview only — draft was not sent." },
                onStop: { isStreaming = false },
                onAttach: { notice = "Attachment picker unavailable in this preview." },
                onSlashCommand: { _, _ in notice = "Commands unavailable in this preview." },
                commandCatalog: [],
                allowsDictation: false
            )
        }
        .padding(.top, Design.Spacing.md)
        .foregroundStyle(Design.Colors.foreground)
        .background(Design.Colors.background)
        .navigationTitle("Chat composer lab")
    }
}

#if DEBUG
#Preview("Base UI polish — no network or recording") {
    ChatComposerLab()
}
#endif
