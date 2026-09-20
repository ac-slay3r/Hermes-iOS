import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private static let maxItems = 1
    private let preview = UITextView()
    private let status = UILabel()
    private let saveButton = UIButton(type: .system)
    private var envelope: IntakeEnvelope?
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let heading = UILabel(); heading.text = "Preview · Local inbox"; heading.font = .preferredFont(forTextStyle: .headline)
        let instructions = UILabel()
        instructions.text = "Text or one HTTP/HTTPS link only. 64 KiB text / 8 KiB link. Save keeps this on your device; links are never fetched. Open Hermes to import. No agent, uploads, images, or PDFs."
        instructions.numberOfLines = 0
        preview.isEditable = false; preview.dataDetectorTypes = []; preview.font = .preferredFont(forTextStyle: .body)
        preview.accessibilityIdentifier = "intake.preview"
        status.numberOfLines = 0; status.text = "Loading shared text…"
        saveButton.setTitle("Save to local inbox", for: .normal)
        saveButton.isEnabled = false
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [heading, instructions, preview, status, saveButton, cancel])
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        loadPreview()
    }

    private func loadPreview() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem], items.count == Self.maxItems,
              let providers = items.first?.attachments, providers.count == Self.maxItems,
              let provider = providers.first else {
            status.text = "Share exactly one text item or link. Nothing has been saved."; return
        }
        let kind: IntakeEnvelope.Kind
        let type: String
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            kind = .url; type = UTType.url.identifier
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            kind = .text; type = UTType.plainText.identifier
        } else {
            status.text = "Unsupported input. Only plain text and HTTP/HTTPS links are accepted."; return
        }
        // Never load a file representation or follow a provider-supplied file URL.
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, error in
            let text: String?
            if kind == .url, let url = item as? URL { text = url.absoluteString }
            else if let value = item as? String { text = value }
            else if let data = item as? Data, data.count <= IntakeEnvelope.maxTextBytes {
                text = String(data: data, encoding: .utf8)
            } else { text = nil }
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                guard !failed, let text else {
                    self.status.text = "Could not load plain text. Cancel and share again; nothing was saved."; return
                }
                do {
                    let envelope = try IntakeEnvelope(text: text, kind: kind)
                    self.envelope = envelope; self.preview.text = envelope.text
                    self.status.text = "Review the original above, then Save or Cancel."
                    self.saveButton.isEnabled = true
                } catch { self.status.text = error.localizedDescription }
            }
        }
    }

    @objc private func save() {
        guard !finished, let envelope else { return }
        saveButton.isEnabled = false
        do {
            try LocalIntakeQueue().save(envelope)
            finished = true
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            status.text = "Save failed. \(error.localizedDescription) Retry Save or Cancel; the source is unchanged."
            saveButton.isEnabled = true
        }
    }

    @objc private func cancelShare() {
        finished = true
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
