import SwiftUI

/// M3 Batch (a): a hand-picked allowlist of safe scalar config fields (timezone, terminal
/// backend/timeout, gateway timeout, max turns, checkpoints, browser headed). `/api/config`
/// has no server-side secret-safe projection yet, so this screen deliberately reads/writes
/// ONLY the named `AdminConfigField` cases — never the full document, never anything under
/// providers/tts/stt/proxy-credential-shaped paths. Each field is saved individually via a
/// minimal `PUT` body (server deep-merges), so unrelated config, including secrets this
/// client never reads, is left untouched.
struct ConfigurationEditorView: View {
    let target: AdminTarget
    let client: HermesAdminClient
    var onAuthorityLost: @MainActor () -> Void = {}

    @State private var snapshot: AdminConfigSnapshot?
    @State private var drafts: [AdminConfigField: String] = [:]
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var loadedOnce = false
    @State private var saving: AdminConfigField?
    @State private var savedField: AdminConfigField?

    var body: some View {
        Form {
            Section("Reviewed target") {
                Text(target.baseURL.absoluteString)
                LabeledContent("Profile", value: target.profile)
            }

            Section {
                Text("Only this hand-picked set of safe fields is shown. Provider keys, API tokens, and other secret-shaped configuration are never read or displayed here.")
                    .font(Design.Typography.footnote)
                    .foregroundStyle(.secondary)
            }

            if loading && !loadedOnce {
                Section { ProgressView("Reading configuration…") }
            } else if snapshot != nil {
                Section("Fields") {
                    ForEach(AdminConfigField.allCases, id: \.self) { field in
                        fieldRow(field)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(Design.Typography.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if loading, loadedOnce {
                    ProgressView("Refreshing…")
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                    .accessibilityIdentifier("admin.configuration.refresh")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Colors.background)
        .foregroundStyle(Design.Colors.foreground)
        .tint(Design.Brand.accent)
        .navigationTitle("Configuration")
        .task { if !loadedOnce { await load() } }
    }

    @ViewBuilder
    private func fieldRow(_ field: AdminConfigField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label).font(Design.Typography.body)
            HStack {
                switch field.kind {
                case .boolean:
                    Toggle(isOn: Binding(
                        get: { drafts[field] == "true" },
                        set: { drafts[field] = $0 ? "true" : "false" }
                    )) { EmptyView() }
                    .labelsHidden()
                case .selectString(let options):
                    Picker("", selection: Binding(
                        get: { drafts[field] ?? "" },
                        set: { drafts[field] = $0 }
                    )) {
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                case .number:
                    TextField("Value", text: Binding(
                        get: { drafts[field] ?? "" },
                        set: { drafts[field] = $0 }
                    ))
                    .keyboardType(.numbersAndPunctuation)
                case .string:
                    TextField("Value", text: Binding(
                        get: { drafts[field] ?? "" },
                        set: { drafts[field] = $0 }
                    ))
                    .autocorrectionDisabled()
                }
                Spacer()
                if saving == field {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save(field) } }
                        .disabled(!isDirty(field))
                        .accessibilityIdentifier("admin.configuration.save.\(field.rawValue)")
                }
            }
            if savedField == field {
                Text("Saved").font(Design.Typography.footnote).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private func isDirty(_ field: AdminConfigField) -> Bool {
        guard let snapshot, let original = snapshot.values[field] else { return false }
        return drafts[field] != Self.stringify(original)
    }

    private static func stringify(_ value: AdminConfigValue) -> String {
        switch value {
        case .string(let s): return s
        case .boolean(let b): return b ? "true" : "false"
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .null: return ""
        }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        savedField = nil
        defer { loading = false; loadedOnce = true }
        do {
            let result = try await client.readAllowlistedConfig(target: target)
            snapshot = result
            for field in AdminConfigField.allCases {
                drafts[field] = Self.stringify(result.values[field] ?? .null)
            }
        } catch {
            if adminSignalsAuthorityLost(error) {
                errorMessage = "Dashboard sign-in expired. Go back and sign in again."
                onAuthorityLost()
            } else {
                errorMessage = "Could not read configuration. Existing values, if any, remain visible."
            }
        }
    }

    @MainActor
    private func save(_ field: AdminConfigField) async {
        guard saving == nil, let draft = drafts[field] else { return }
        let value: AdminConfigValue
        switch field.kind {
        case .boolean:
            value = .boolean(draft == "true")
        case .number:
            guard let n = Double(draft) else {
                errorMessage = "\(field.label) must be a number."
                return
            }
            value = .number(n)
        case .string, .selectString:
            value = .string(draft)
        }
        saving = field
        savedField = nil
        errorMessage = nil
        defer { saving = nil }
        do {
            try await client.writeAllowlistedConfig(field, value: value, target: target)
            snapshot?.values[field] = value
            savedField = field
        } catch AdminError.rejected {
            errorMessage = "The server rejected this change to \(field.label). It is not saved."
        } catch {
            if adminSignalsAuthorityLost(error) {
                errorMessage = "Dashboard sign-in expired. Go back and sign in again."
                onAuthorityLost()
            } else {
                errorMessage = "Could not save \(field.label). The outcome is unknown; refresh to check."
            }
        }
    }
}
