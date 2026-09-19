import SwiftUI

/// Frozen legacy entry points cannot start remote sessions in the admin slice.
enum AdminLaunchPolicy {
    static let legacyRemoteEnabled = false
}

/// Administration-first launch. No AppContainer, sensors, voice or relay startup.
struct AdminRoot: View {
    @State private var address = ""
    @State private var profile = "default"
    @State private var target: AdminTarget?
    @State private var invalidTarget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Not connected", systemImage: "lock.shield")
                        .foregroundStyle(Design.Brand.accent)
                    Text("Administration requires its own verified dashboard sign-in. Chat pairing does not grant administrator access.")
                    Text("This build has no enabled admin network transport. No host settings or credentials have been read.")
                        .font(Design.Typography.footnote)
                }
                Section("Choose a target") {
                    TextField("HTTPS dashboard address", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Exact profile name", text: $profile)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Review target") {
                        do {
                            target = try AdminTarget(address: address, profile: profile)
                            invalidTarget = false
                        } catch {
                            target = nil
                            invalidTarget = true
                        }
                    }
                    if invalidTarget {
                        Text("Use HTTPS without credentials, query or fragment and an exact lowercase profile identifier.")
                            .foregroundStyle(.red)
                    }
                }
                if let target {
                    Section("Selected target · unverified") {
                        LabeledContent("Dashboard", value: target.baseURL.absoluteString)
                        LabeledContent("Target profile", value: target.profile)
                        LabeledContent("Signed-in identity", value: "Not authenticated")
                        LabeledContent("Serving profile", value: "Unknown")
                    }
                }
                Section("Inspect") {
                    Label("Settings inspection unavailable", systemImage: "slider.horizontal.3")
                    Text("The dashboard's general settings response can include credentials. A server-side secret-safe projection is required; this client does not fetch raw configuration.")
                        .font(Design.Typography.footnote)
                }
                Section("Correct") {
                    Label("Session titles", systemImage: "text.cursor")
                    Label("SOUL.md instructions", systemImage: "doc.text")
                    Text("Editors are implemented but locked until an approved iOS sign-in is verified. The existing native broker accepts only HTTP loopback callbacks; this build does not bypass that restriction or ask for copied tokens.")
                        .font(Design.Typography.footnote)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Design.Colors.background)
            .foregroundStyle(Design.Colors.foreground)
            .tint(Design.Brand.accent)
            .navigationTitle("Hermes")
            .onChange(of: address) { _, _ in target = nil }
            .onChange(of: profile) { _, _ in target = nil }
        }
        .preferredColorScheme(.dark)
    }
}

/// Injected only by a future approved authentication coordinator or native tests.
/// The normal launch does not construct this editor with fake credentials/data.
struct AdminCorrectionView: View {
    @State var editor: AdminEditor
    let resource: AdminResource

    var body: some View {
        Form {
            Section("Exact target") {
                Text(editor.target.baseURL.absoluteString)
                LabeledContent("Profile", value: editor.target.profile)
                Text(resource.label)
            }
            Section {
                Text("Read-before-write detects some changes, but the server has no atomic edit precondition. Avoid simultaneous edits from other clients.")
                    .font(Design.Typography.footnote)
            }
            if let original = editor.original {
                Section("Before") {
                    Text(original.exists ? original.value : "File does not exist")
                        .textSelection(.enabled)
                }
                Section("After") {
                    if editor.phase == .editing {
                        TextEditor(text: $editor.proposed)
                            .frame(minHeight: 160)
                            .autocorrectionDisabled()
                    } else {
                        Text(editor.proposed).textSelection(.enabled)
                    }
                }
            }
            Section {
                switch editor.phase {
                case .idle:
                    Button("Read exact target") { Task { await editor.load(resource) } }
                case .loading, .applying:
                    ProgressView(editor.phase == .loading ? "Reading…" : "Applying / verifying…")
                case .editing:
                    Button("Review change") { editor.review() }
                        .disabled(editor.proposed == editor.original?.value)
                case .review:
                    Text("Apply only this change to the host and profile above. Saving does not prove running sessions have reloaded instructions.")
                    Button("Apply change") { Task { await editor.apply() } }
                    Button("Keep editing") { editor.revise() }
                case .saved:
                    Label("Saved · exact readback verified", systemImage: "checkmark.circle")
                    Text("Runtime application is unknown. No restart was requested.")
                case .conflict:
                    Text("Changed elsewhere. Nothing was written. Read again before making a new edit.")
                    Button("Read again") { Task { await editor.load(resource) } }
                case .unknown:
                    Text("Outcome unknown. Do not repeat the write. Verify the exact target first.")
                    Button("Verify saved value") { Task { await editor.verify() } }
                case .rejected:
                    Text("The server rejected this change. It is not verified saved.")
                    Button("Read again") { Task { await editor.load(resource) } }
                case .failed:
                    Text("Cannot read this target. Check dashboard sign-in, authority and profile. No write was attempted.")
                    Button("Read again") { Task { await editor.load(resource) } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Colors.background)
        .foregroundStyle(Design.Colors.foreground)
        .tint(Design.Brand.accent)
        .navigationTitle(resource.label)
    }
}
