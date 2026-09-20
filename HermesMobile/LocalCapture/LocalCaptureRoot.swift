import SwiftUI
import AVFoundation
import VisionKit

struct LocalCaptureRoot: View {
    @State private var store: LocalCaptureStore?
    @State private var activity = LocalCaptureActivity()
    @State private var audio = LocalCaptureAudio()
    @State private var failure: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var intakeFailure: String?
    @State private var inboxRoute = LocalInboxRoute.shared
    @State private var pendingIntake = false
    @State private var presentInboxAfterImport = false

    var body: some View {
        Group {
            if let store {
                LocalCaptureLibrary(store: store, audio: audio, activity: activity,
                                    openInbox: { queueIntake(presentInbox: true) }, close: close)
            }
            else {
                NavigationStack {
                    ContentUnavailableView {
                        Label("Local captures unavailable", systemImage: "lock.doc")
                    } description: {
                        Text(failure ?? "Opening protected storage…")
                        Text("Unlock your device and retry. Existing files will not be reset.")
                    } actions: {
                        Button("Retry opening captures", action: retryOpen)
                    }
                    .toolbar { rootDoneToolbar }
                }
            }
        }
        .tint(Design.Brand.accent)
        .background(Design.Colors.background.ignoresSafeArea())
        .task {
            open()
            queueIntake(presentInbox: false)
            receiveInboxRequest(inboxRoute.requestID)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                open()
                queueIntake(presentInbox: false)
                receiveInboxRequest(inboxRoute.requestID)
            } else if phase == .background || audio.isRecording || audio.playingID != nil {
                audio.stop()
            }
        }
        .onChange(of: inboxRoute.requestID) { _, id in receiveInboxRequest(id) }
        .onChange(of: activity.blocksInbox) { _, blocked in if !blocked { importIntake() } }
        .safeAreaInset(edge: .top) {
            if let intakeFailure {
                VStack {
                    Text(intakeFailure).font(.caption)
                    Button("Retry local inbox import") { queueIntake(presentInbox: false) }
                }.padding().background(.regularMaterial)
            }
        }
        .sheet(isPresented: $inboxRoute.isPresented) {
            NavigationStack {
                List {
                    Text("Local inbox · On this device only. Share one text item or HTTP/HTTPS link, preview, then Save. Shortcuts saves require confirmation. Links are never fetched.")
                    if let intakeFailure { Text(intakeFailure) }
                    Button("Retry importing shared items") { queueIntake(presentInbox: true) }
                    if let store {
                        ForEach(store.captures.filter { $0.kind == .note && !$0.isArchived }) { capture in
                            NavigationLink(capture.title) {
                                ScrollView { Text(verbatim: capture.text).textSelection(.enabled).padding() }
                                    .navigationTitle(capture.title)
                            }
                        }
                    }
                }
                .navigationTitle("Local inbox")
                .toolbar { Button("Done") { inboxRoute.isPresented = false } }
            }
        }
        .interactiveDismissDisabled(activity.blocksDismiss)
        .onDisappear {
            inboxRoute.isPresented = false
            audio.stop()
        }
    }

    @ToolbarContentBuilder private var rootDoneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: close)
                .foregroundStyle(Design.Brand.accent)
                .disabled(activity.blocksDismiss)
        }
    }

    private func open() {
        guard store == nil else { return }
        do { store = try LocalCaptureStore(); failure = nil }
        catch { failure = error.localizedDescription }
    }

    private func receiveInboxRequest(_ id: Int) {
        guard store != nil else { return }
        guard inboxRoute.consumeRequest(id) else { return }
        queueIntake(presentInbox: true)
    }

    private func queueIntake(presentInbox: Bool) {
        pendingIntake = true
        presentInboxAfterImport = presentInboxAfterImport || presentInbox
        if presentInbox { activity.hasPendingInboxRequest = true }
        importIntake()
    }

    private func importIntake() {
        guard pendingIntake, let current = store else { return }
        guard !activity.blocksInbox else { return }
        pendingIntake = false
        activity.isIntakeWorking = true
        defer { activity.isIntakeWorking = false }
        var reportedFailure: String?
        do {
            try LocalIntakeImporter.drain(queue: LocalIntakeQueue(), root: current.root)
        } catch { reportedFailure = error.localizedDescription }
        // Even a partial batch may have committed. Publish only a fully validated snapshot
        // into this same store so open editors never retain a discarded store instance.
        do {
            try current.refresh()
        } catch {
            reportedFailure = [reportedFailure, error.localizedDescription].compactMap { $0 }.joined(separator: " ")
        }
        intakeFailure = reportedFailure
        if presentInboxAfterImport {
            presentInboxAfterImport = false
            activity.hasPendingInboxRequest = false
            inboxRoute.isPresented = true
        }
    }

    private func retryOpen() {
        open()
        guard store != nil else { return }
        queueIntake(presentInbox: false)
        receiveInboxRequest(inboxRoute.requestID)
    }

    private func close() {
        guard !activity.blocksDismiss else { return }
        audio.stop()
        inboxRoute.isPresented = false
        dismiss()
    }
}

private struct LocalCaptureLibrary: View {
    @Environment(\.scenePhase) private var scenePhase
    let store: LocalCaptureStore
    let audio: LocalCaptureAudio
    let activity: LocalCaptureActivity
    let openInbox: () -> Void
    let close: () -> Void
    @State private var editor: LocalCapture?
    @State private var deleting: LocalCapture?
    @State private var picker: PickerChoice?
    @State private var errorMessage: String?
    @State private var pendingImages: [Data] = []
    @State private var pendingKind: LocalCapture.Kind = .photo
    @State private var recognizing = false
    @State private var preparingCamera = false
    @State private var query = LocalCaptureLibraryQuery()
    @State private var checklist: LocalCapture?
    @State private var discardingPendingImages = false
    @State private var recognitionTask: Task<Void, Never>?
    @State private var lifecycleID = UUID()

    private var visibleCaptures: [LocalCapture] { query.apply(to: store.captures) }
    private var captureBusy: Bool {
        audio.isRecording || audio.isStarting || recognizing || audio.transcribingID != nil
    }
    private var mediaBusy: Bool { captureBusy || audio.playingID != nil || preparingCamera }
    private var controlsDisabled: Bool {
        mediaBusy || picker != nil || editor != nil || checklist != nil || deleting != nil
            || !pendingImages.isEmpty || activity.isStoragePresented || activity.isStorageWorking
            || activity.isIntakeWorking
    }

    private struct PickerChoice: Identifiable {
        let id = UUID()
        let source: LocalImagePicker.Source
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("On this device only", systemImage: "iphone.gen3")
                    Text("No Hermes connection, pairing, or automatic uploads. App-private captures are excluded from backup; deleting the app removes them. Explicit Files exports use your chosen destination.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Open local inbox", systemImage: "tray", action: openInbox)
                        .disabled(controlsDisabled)
                    Text("Share one plain-text item or HTTP/HTTPS link from another app, preview, then Save. Shortcuts: Save text to local inbox (confirmation required) or Open local inbox. No link fetching or agent connection.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("Storage & backup") {
                        LocalCaptureStorageView(store: store, activity: activity).onAppear { audio.stopPlayback() }
                    }
                        .disabled(controlsDisabled)
                        .accessibilityIdentifier("capture.storage")
                }
                Section("Capture") {
                    Button("New text note", systemImage: "square.and.pencil") {
                        do { editor = try store.create(kind: .note, title: "New note"); syncActivity() }
                        catch { errorMessage = error.localizedDescription }
                    }.disabled(controlsDisabled)
                    Button("Take photo", systemImage: "camera") { prepareCamera(document: false) }
                        .disabled(controlsDisabled)
                    Button("Import photo", systemImage: "photo") {
                        guard pendingImages.isEmpty else { errorMessage = "Save the pending import first."; return }
                        picker = PickerChoice(source: .library)
                        syncActivity()
                    }.disabled(controlsDisabled)
                    Text("The system photo picker may download an iCloud original you select. OCR and storage stay on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Scan document", systemImage: "doc.viewfinder") { prepareCamera(document: true) }
                        .disabled(controlsDisabled)
                    if audio.isRecording {
                        Label("Microphone recording", systemImage: "mic.fill")
                            .foregroundStyle(.red).accessibilityLabel("Microphone is recording")
                        Button("Stop recording", systemImage: "stop.circle.fill") { audio.stop(); syncActivity() }
                            .tint(.red).accessibilityIdentifier("capture.stopRecording")
                    } else {
                        Button(audio.isStarting ? "Requesting microphone…" : "Record voice", systemImage: "mic") {
                            activity.isMediaBusy = true
                            Task { await audio.start(store: store); syncActivity() }
                        }.disabled(controlsDisabled)
                    }
                }
                if !pendingImages.isEmpty {
                    Section("Unsaved import") {
                        Text("Saving failed. These images remain in memory while this screen is open.")
                        Button("Retry saving import") { saveImages() }
                        Button("Discard pending import", role: .destructive) { discardingPendingImages = true }
                    }
                }
                Section("Library filters") {
                    Picker("Show", selection: $query.scope) {
                        ForEach(LocalCaptureLibraryScope.allCases, id: \.self) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }.pickerStyle(.menu).accessibilityIdentifier("capture.scope")
                    Picker("Kind", selection: $query.kind) {
                        Text("All kinds").tag(Optional<LocalCapture.Kind>.none)
                        ForEach(LocalCapture.Kind.allCases, id: \.self) { kind in
                            Text(kind.rawValue.capitalized).tag(Optional(kind))
                        }
                    }.pickerStyle(.menu).accessibilityIdentifier("capture.kind")
                    if !query.text.isEmpty || query.kind != nil || query.scope != .active {
                        Button("Reset library filters") { query = LocalCaptureLibraryQuery() }
                    }
                }
                Section(query.scope == .archived ? "Archived captures" : "Saved captures") {
                    if visibleCaptures.isEmpty {
                        Text(store.captures.isEmpty ? "Your notes, photos, scans, and recordings will appear here." : "No captures match these filters. Archived captures are shown only in Archived.")
                    }
                    ForEach(visibleCaptures) { capture in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { editor = capture; syncActivity() } label: {
                                VStack(alignment: .leading) {
                                    Text(capture.title.isEmpty ? "Untitled capture" : capture.title).font(.headline)
                                    Text(capture.kind.rawValue.capitalized + " · " + capture.createdAt.formatted()).font(.caption)
                                    if !capture.text.isEmpty { Text(capture.text).lineLimit(2) }
                                }
                            }.accessibilityLabel("Review \(capture.title)")
                                .disabled(controlsDisabled)
                            if capture.kind == .voice {
                                HStack {
                                    Button(audio.playingID == capture.id ? "Stop playback" : "Play recording") {
                                        if audio.playingID == capture.id { audio.stopPlayback() }
                                        else { audio.play(capture, store: store) }
                                        syncActivity()
                                    }
                                    Button("Transcribe offline") {
                                        activity.isMediaBusy = true
                                        Task { await audio.transcribe(capture, store: store); syncActivity() }
                                    }
                                        .disabled(controlsDisabled)
                                }.disabled(controlsDisabled && audio.playingID != capture.id)
                            } else if !capture.attachments.isEmpty {
                                Button("Recognize text on device") { recognize(capture) }.disabled(controlsDisabled)
                            }
                            if capture.isPinned { Label("Pinned", systemImage: "pin.fill").font(.caption) }
                            Button {
                                checklist = capture
                                syncActivity()
                            } label: {
                                Label("Checklist · \(capture.tasks.filter { $0.isCompleted }.count)/\(capture.tasks.count)", systemImage: "checklist")
                            }
                            .accessibilityLabel("Checklist for \(capture.title)")
                            .accessibilityIdentifier("capture.checklist")
                            .disabled(controlsDisabled)
                            Menu {
                                Button(capture.isPinned ? "Unpin capture" : "Pin capture", systemImage: capture.isPinned ? "pin.slash" : "pin") {
                                    do { try store.setPinned(!capture.isPinned, captureID: capture.id) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                                Button(capture.isArchived ? "Unarchive capture" : "Archive capture", systemImage: "archivebox") {
                                    do {
                                        try store.setArchived(!capture.isArchived, captureID: capture.id)
                                        if audio.playingID == capture.id { audio.stopPlayback() }
                                    } catch { errorMessage = error.localizedDescription }
                                }
                                Button("Delete capture", role: .destructive) { deleting = capture; syncActivity() }
                            } label: {
                                Label("Capture actions", systemImage: "ellipsis.circle")
                            }
                            .accessibilityLabel("Actions for \(capture.title)")
                            .accessibilityIdentifier("capture.actions")
                            .disabled(controlsDisabled)
                        }.buttonStyle(.borderless)
                    }
                }
                if recognizing { ProgressView("Recognizing text on device") }
            }
            .navigationTitle("Local captures")
            .scrollContentBackground(.hidden)
            .background(Design.Colors.background)
            .searchable(text: $query.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search titles and text")
            .onChange(of: query.text) { _, _ in audio.stopPlayback() }
            .onChange(of: query.kind) { _, _ in audio.stopPlayback() }
            .onChange(of: query.scope) { _, _ in audio.stopPlayback() }
            .onChange(of: editor?.id) { _, id in if id != nil { audio.stopPlayback() }; syncActivity() }
            .onChange(of: checklist?.id) { _, id in if id != nil { audio.stopPlayback() }; syncActivity() }
            .onChange(of: deleting?.id) { _, _ in syncActivity() }
            .onChange(of: picker?.id) { _, id in if id != nil { audio.stopPlayback() }; syncActivity() }
            .onChange(of: pendingImages.count) { _, _ in syncActivity() }
            .onChange(of: mediaBusy) { _, _ in syncActivity() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { syncActivity() }
                else if phase == .background { deactivate() }
            }
            .onAppear { syncActivity() }
            .onDisappear {
                // Full-screen system capture covers its presenter. Keep that picker's
                // identity alive until its explicit completion or real backgrounding.
                if picker == nil { deactivate() }
                else { audio.stop() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                        .foregroundStyle(Design.Brand.accent)
                        .disabled(activity.blocksDismiss)
                }
            }
            .sheet(item: $checklist) { capture in
                LocalCaptureChecklist(captureID: capture.id, store: store)
            }
            .safeAreaInset(edge: .bottom) {
                if audio.isRecording {
                    Button { audio.stop(); syncActivity() } label: {
                        Label("Recording · Stop microphone", systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity).padding()
                    }
                    .tint(.red).background(.regularMaterial)
                    .accessibilityLabel("Microphone recording. Stop recording")
                }
                if audio.transcribingID != nil {
                    VStack {
                        ProgressView("Transcribing on device")
                        Button("Cancel transcription") { audio.cancelTranscription(); syncActivity() }
                    }
                    .frame(maxWidth: .infinity).padding().background(.regularMaterial)
                }
            }
            .sheet(item: $editor) { capture in
                LocalCaptureEditor(capture: capture, store: store)
            }
            .sheet(item: $picker) { choice in
                let token = lifecycleID
                LocalImagePicker(source: choice.source) { images, failure in
                    guard lifecycleID == token else { return }
                    picker = nil
                    if let failure { errorMessage = failure }
                    if let images, !images.isEmpty {
                        pendingImages = images
                        pendingKind = choice.source == .document ? .document : .photo
                        saveImages()
                    }
                    syncActivity()
                }.ignoresSafeArea()
            }
            .confirmationDialog("Delete this capture and all its attachments permanently?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                Button("Delete permanently", role: .destructive) {
                    guard let capture = deleting else { return }
                    audio.stop()
                    do { try store.delete(capture) }
                    catch { errorMessage = "Delete incomplete; retry. \(error.localizedDescription)" }
                    deleting = nil
                }
            }
            .confirmationDialog("Discard the unsaved imported images?", isPresented: $discardingPendingImages,
                                titleVisibility: .visible) {
                Button("Discard images", role: .destructive) { pendingImages = [] }
                Button("Keep images", role: .cancel) {}
            }
            .alert("Local capture", isPresented: Binding(
                get: { errorMessage != nil || audio.notice != nil },
                set: { if !$0 { errorMessage = nil; audio.notice = nil } }
            )) {
                Button("OK") { errorMessage = nil; audio.notice = nil }
            } message: { Text(errorMessage ?? audio.notice ?? "") }
        }
    }

    private func prepareCamera(document: Bool) {
        guard !controlsDisabled, pendingImages.isEmpty else { errorMessage = "Save or close the current work first."; return }
        guard document ? VNDocumentCameraViewController.isSupported : UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorMessage = "This device does not support \(document ? "document scanning" : "the camera"). Import a photo instead."
            return
        }
        let token = lifecycleID
        preparingCamera = true
        syncActivity()
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard lifecycleID == token, !Task.isCancelled else { return }
            preparingCamera = false
            syncActivity()
            guard allowed else { errorMessage = "Camera access denied. Enable it in iOS Settings."; return }
            guard UIApplication.shared.applicationState == .active else { return }
            picker = PickerChoice(source: document ? .document : .camera)
            syncActivity()
        }
    }

    private func saveImages() {
        guard !pendingImages.isEmpty else { return }
        do {
            _ = try store.create(kind: pendingKind, title: pendingKind == .document ? "Scanned document" : "Photo", attachments: pendingImages)
            pendingImages = []
        } catch { errorMessage = "Import not saved: \(error.localizedDescription). Retry without closing the app." }
    }

    private func recognize(_ capture: LocalCapture) {
        guard !controlsDisabled else { return }
        recognitionTask?.cancel()
        let token = lifecycleID
        recognizing = true
        syncActivity()
        recognitionTask = Task { @MainActor in
            defer {
                if lifecycleID == token {
                    recognizing = false
                    recognitionTask = nil
                    syncActivity()
                }
            }
            do {
                let urls = try capture.attachments.map { try store.attachmentURL(capture, name: $0) }
                let readTask = Task.detached(priority: .userInitiated) {
                    var pages: [Data] = []
                    pages.reserveCapacity(urls.count)
                    for url in urls {
                        try Task.checkCancellation()
                        pages.append(try Data(contentsOf: url))
                    }
                    return pages
                }
                let pages = try await withTaskCancellationHandler {
                    try await readTask.value
                } onCancel: {
                    readTask.cancel()
                }
                try Task.checkCancellation()
                let text = try await LocalCaptureOCR.recognize(pages)
                guard lifecycleID == token, !Task.isCancelled else { return }
                guard var latest = store.captures.first(where: { $0.id == capture.id }) else { return }
                guard !text.isEmpty else { errorMessage = "No readable text found. Original images kept."; return }
                latest.text += (latest.text.isEmpty ? "" : "\n\n") + text
                try store.save(latest)
            } catch is CancellationError {
                // Lifecycle cancellation intentionally leaves the original images untouched.
            } catch {
                if lifecycleID == token { errorMessage = "OCR failed: \(error.localizedDescription). Original images kept." }
            }
        }
    }

    private func syncActivity() {
        activity.isMediaBusy = mediaBusy
        activity.isDraftPresented = editor != nil || checklist != nil || deleting != nil
        activity.isPickerPresented = picker != nil
        activity.hasPendingImages = !pendingImages.isEmpty
    }

    private func deactivate() {
        lifecycleID = UUID()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizing = false
        preparingCamera = false
        picker = nil
        audio.stop()
        syncActivity()
    }
}

/// Explicit checklist edits save immediately; never sends, schedules, or executes a task.
private struct LocalCaptureChecklist: View {
    @Environment(\.dismiss) private var dismiss
    let captureID: UUID
    let store: LocalCaptureStore
    @State private var draft = ""
    @State private var failure: String?
    @State private var removing: LocalCaptureTask?

    private var capture: LocalCapture? { store.captures.first { $0.id == captureID } }

    var body: some View {
        NavigationStack {
            Form {
                if let capture {
                    Section {
                        Text(capture.title.isEmpty ? "Untitled capture" : capture.title).font(.headline)
                        Text("Only items you add. Changes save on this device immediately. Checking an item does not ask an agent to do anything.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Add an item") {
                        TextField("New checklist item", text: $draft, axis: .vertical)
                            .accessibilityLabel("New checklist item")
                        Button("Add checklist item", systemImage: "plus") {
                            do {
                                try store.addTask(draft, captureID: captureID)
                                draft = ""
                                failure = nil
                            } catch { failure = error.localizedDescription }
                        }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Section("Checklist") {
                        if capture.tasks.isEmpty { Text("No checklist items. Add one above.") }
                        ForEach(capture.tasks) { task in
                            VStack(alignment: .leading) {
                                Toggle(task.title, isOn: Binding(
                                    get: { self.capture?.tasks.first(where: { $0.id == task.id })?.isCompleted ?? false },
                                    set: { completed in
                                        perform { try store.setTaskCompleted(completed, taskID: task.id, captureID: captureID) }
                                    }
                                ))
                                .accessibilityHint("Marks this item complete locally only")
                                Button("Remove item", role: .destructive) { removing = task }
                                    .accessibilityLabel("Remove \(task.title)")
                            }
                        }
                    }
                } else {
                    Text("This capture no longer exists.")
                }
                if let failure { Text("Not saved: \(failure)").foregroundStyle(.red) }
            }
            .navigationTitle("Local checklist")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Remove this checklist item?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible) {
                Button("Remove item", role: .destructive) {
                    guard let task = removing else { return }
                    perform { try store.removeTask(task.id, captureID: captureID) }
                    removing = nil
                }
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}

private struct LocalCaptureEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var capture: LocalCapture
    let store: LocalCaptureStore
    @State private var failure: String?
    @State private var review: ReviewSnapshot?

    private struct ReviewSnapshot: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $capture.title).accessibilityLabel("Capture title")
                TextEditor(text: $capture.text).frame(minHeight: 200).accessibilityLabel("Capture text")
                Section("Optional AI review") {
                    LocalCaptureIntelligenceCapabilityView()
                    Button("Open AI review", systemImage: "sparkles") {
                        review = ReviewSnapshot(text: capture.text)
                    }
                    .accessibilityIdentifier("capture.aiReview")
                    Text("Review a temporary copy of your current text, including unsaved edits. Suggestions never change this capture or its checklist.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if capture.kind != .voice {
                    ForEach(capture.attachments, id: \.self) { name in
                        if let url = try? store.attachmentURL(capture, name: name),
                           let image = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Captured image \(name)")
                        } else { Text("Image unavailable. The attachment has not been deleted.") }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("Review capture")
            .sheet(item: $review) { snapshot in
                LocalCaptureIntelligenceReviewSheet(text: snapshot.text)
                    .id(snapshot.id)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save capture") {
                        do { try store.save(capture); dismiss() }
                        catch { failure = "Not saved: \(error.localizedDescription)" }
                    }
                }
            }
        }.interactiveDismissDisabled()
    }
}
