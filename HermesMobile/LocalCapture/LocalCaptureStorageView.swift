import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LocalCaptureStorageView: View {
    let store: LocalCaptureStore
    let activity: LocalCaptureActivity
    @State private var exported: LocalBackupExport?
    @State private var importing = false
    @State private var pending: LocalBackupPrepared?
    @State private var confirming = false
    @State private var notice: String?
    @State private var usage = "Calculating…"
    @State private var job: LocalBackupJob?
    @State private var progress = "Preparing…"
    @State private var work: Task<Void, Never>?

    private var storageWorking: Bool {
        importing || job != nil || work != nil || pending != nil || confirming || exported != nil
    }

    var body: some View {
        Form {
            Section("Local storage") {
                Text("\(store.captures.count) saved captures · \(usage)")
                Text("Saved capture files only; excludes temporary files and export copies. App-private captures are excluded from backup and deleted when this app is uninstalled.")
                    .font(.footnote)
            }
            Section("Choose where your copy goes") {
                Text("Files can save to iCloud Drive or third-party providers, which may upload your data. For local storage, choose Browse → On My iPhone (On My iPad on iPad). Importing from a cloud provider may download the selected file.")
                Text("A Hermes-owned folder under On My iPhone may also be deleted when you uninstall Hermes. Choose an independent destination and verify the saved copy. For protection against device loss, explicitly copy it off-device yourself. Local does not mean uninstall-safe.")
                Text("Backup documents are not encrypted by Hermes. They include all saved text, checklists, organization metadata, images, and audio, including archived captures. Anyone with access to the destination may read them. No automatic sync or agent transfer occurs.")
            }.font(.footnote)
            Section("Backup document") {
                Button("Export all captures to Files", systemImage: "square.and.arrow.up", action: beginExport)
                    .accessibilityIdentifier("capture.exportBackup")
                    .disabled(storageWorking)
                Button("Choose backup to import", systemImage: "square.and.arrow.down") { importing = true }
                    .accessibilityIdentifier("capture.importBackup")
                    .disabled(storageWorking)
                if job != nil {
                    ProgressView(progress)
                    Button("Cancel backup operation", role: .cancel) { cancelWork() }
                }
                Text("Stop recording and save edits first. Imports always create new copies with new IDs, including duplicates. Existing captures are never replaced. Confirm only after the entire file is checked and staged privately.")
                Text(LocalCaptureArchive.capacityDisclosure).font(.footnote)
            }
        }
        .navigationTitle("Storage & backup")
        .onAppear {
            activity.isStoragePresented = true
            activity.isStorageWorking = storageWorking
        }
        .onChange(of: storageWorking) { _, working in activity.isStorageWorking = working }
        .task {
            refreshUsage()
            // Poll a lock-protected value: no per-chunk UI tasks or unbounded progress queue.
            while !Task.isCancelled {
                if let job { progress = job.status }
                do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
            }
        }
        .sheet(item: $exported, onDismiss: { exported = nil }) { archive in
            LocalBackupFileExporter(archive: archive) { saved in
                exported = nil
                notice = saved
                    ? "Files reported the export saved. Verify your copy at the chosen destination; provider uploads and retention are managed by Files, not Hermes."
                    : "Export cancelled. Existing captures were not changed."
            }.interactiveDismissDisabled()
        }
        // Generic .data accepts the custom extension as well as legacy JSON. Bytes, not type labels, are trusted.
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .json], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                beginImport(url)
            } catch { notice = "Import not prepared: \(error.localizedDescription)" }
        }
        .confirmationDialog("Import \(pending?.captures.count ?? 0) captures as new copies?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Import copies") {
                guard let prepared = pending else { return }
                pending = nil
                do {
                    let count = try store.importPrepared(prepared)
                    notice = "Imported \(count) new copies. Existing captures were not changed."
                    refreshUsage()
                } catch { notice = "Import failed; existing captures unchanged. \(error.localizedDescription)" }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Even previously imported captures will be duplicated with new IDs. Nothing is sent to an agent.")
        }
        .onChange(of: confirming) { _, visible in if !visible { pending = nil } }
        .onDisappear {
            cancelWork()
            pending = nil
            exported = nil
            importing = false
            confirming = false
            activity.isStoragePresented = false
            activity.isStorageWorking = storageWorking
        }
        .alert("Storage & backup", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func cancelWork() {
        job?.cancel()
        work?.cancel()
        // Wait for worker handles to close; released owners queue any recursive cleanup off-main.
        progress = "Cancelling and removing temporary copies…"
    }

    private func beginExport() {
        guard !storageWorking else { return }
        do {
            let sources = try store.backupSources()
            let root = store.root
            let current = LocalBackupJob()
            job = current
            work = Task { @MainActor in
                do {
                    let archive = try await withTaskCancellationHandler {
                        try await Task.detached(priority: .userInitiated) {
                            try LocalCaptureArchive.export(sources: sources, root: root, job: current)
                        }.value
                    } onCancel: { current.cancel() }
                    try current.checkCancellation()
                    try Task.checkCancellation()
                    exported = archive
                } catch is CancellationError {
                    // The worker's owner/defer cleans only temporary copies.
                } catch { notice = "Export not completed: \(error.localizedDescription)" }
                job = nil
                work = nil
                activity.isStorageWorking = storageWorking
            }
        } catch { notice = error.localizedDescription }
    }

    private func beginImport(_ url: URL) {
        guard job == nil, work == nil, pending == nil, exported == nil else { return }
        let root = store.root
        let current = LocalBackupJob()
        job = current
        work = Task { @MainActor in
            do {
                let prepared = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        // Coordinate provider access for the entire streamed read, not just its initial stat.
                        let coordinator = NSFileCoordinator()
                        var coordinationError: NSError?
                        var result: Result<LocalBackupPrepared, Error>?
                        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                            result = Result { try LocalCaptureArchive.prepare(url: readable, root: root, job: current) }
                        }
                        if let coordinationError { throw coordinationError }
                        guard let result else { throw LocalCaptureArchive.invalid }
                        return try result.get()
                    }.value
                } onCancel: { current.cancel() }
                try current.checkCancellation()
                try Task.checkCancellation()
                pending = prepared
                confirming = true
            } catch is CancellationError {
                pending = nil
            } catch {
                pending = nil
                notice = "Import not prepared; existing captures unchanged. \(error.localizedDescription)"
            }
            job = nil
            work = nil
            activity.isStorageWorking = storageWorking
        }
    }

    private func refreshUsage() {
        do { usage = ByteCountFormatter.string(fromByteCount: try store.storageBytes(), countStyle: .file) }
        catch { usage = "Storage size unavailable: \(error.localizedDescription)" }
    }
}

/// The system copies a protected on-disk URL. Retain its owner until the delegate finishes.
/// Never turn the archive into an in-memory document wrapper for the Files picker.
private struct LocalBackupFileExporter: UIViewControllerRepresentable {
    let archive: LocalBackupExport
    let completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(archive: archive, completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [archive.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let archive: LocalBackupExport
        let completion: (Bool) -> Void
        private var finished = false
        init(archive: LocalBackupExport, completion: @escaping (Bool) -> Void) {
            self.archive = archive
            self.completion = completion
        }
        private func finish(_ saved: Bool) {
            guard !finished else { return }
            finished = true
            completion(saved)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(!urls.isEmpty)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
    }
}
