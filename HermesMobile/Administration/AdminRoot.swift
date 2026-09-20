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
    @State private var authSession: AdminAuthSession?
    @State private var overview: AdminOverview?
    @State private var signingIn = false
    @State private var connectionMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(overview == nil ? "Not connected" : "Dashboard connected", systemImage: overview == nil ? "lock.shield" : "checkmark.shield")
                        .foregroundStyle(Design.Brand.accent)
                    Text("Administration requires its own verified dashboard sign-in. Chat pairing does not grant administrator access.")
                    Text(overview == nil
                         ? "Choose an HTTPS dashboard and profile, then authenticate in the system browser."
                         : "Authenticated dashboard identity and profile context were read from the selected host.")
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
                            authSession?.cancel()
                            target = try AdminTarget(address: address, profile: profile)
                            invalidTarget = false
                            overview = nil
                            authSession = nil
                            connectionMessage = nil
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
                    Section(overview == nil ? "Selected target · unverified" : "Verified dashboard") {
                        LabeledContent("Dashboard", value: target.baseURL.absoluteString)
                        LabeledContent("Target profile", value: target.profile)
                        LabeledContent("Signed-in identity", value: overview?.identity.displayName ?? "Not authenticated")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Signed-in identity")
                            .accessibilityValue(overview?.identity.displayName ?? "Not authenticated")
                            .accessibilityIdentifier("admin.identity")
                        LabeledContent("Serving profile", value: overview?.profiles.current ?? "Unknown")
                        if let overview {
                            LabeledContent("Provider", value: overview.identity.provider)
                            LabeledContent("Gateway", value: overview.status.gatewayRunning ? "Running" : "Stopped")
                            Button("Sign out", role: .destructive) {
                                Task { await signOut() }
                            }
                            .accessibilityIdentifier("admin.signOut")
                        } else if signingIn {
                            ProgressView("Checking host / signing in…")
                        } else {
                            Button("Check host & sign in", systemImage: "person.badge.key") {
                                Task { await signIn(to: target) }
                            }
                            .accessibilityIdentifier("admin.signIn")
                        }
                        if let connectionMessage {
                            Text(connectionMessage)
                                .font(Design.Typography.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Section("Manage Hermes") {
                    Label("Overview & health", systemImage: "gauge.with.dots.needle.50percent")
                    Label("Configuration & models", systemImage: "slider.horizontal.3")
                    Label("Profiles & sessions", systemImage: "person.2")
                    Label("Skills, tools & MCP", systemImage: "wrench.and.screwdriver")
                    Label("Memory & instructions", systemImage: "brain.head.profile")
                    Label("Automation & connections", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    Label("System & operations", systemImage: "server.rack")
                    Text("Management areas unlock only after the selected dashboard verifies sign-in and profile context. No local-only feature grants host authority.")
                        .font(Design.Typography.footnote)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Design.Colors.background)
            .foregroundStyle(Design.Colors.foreground)
            .tint(Design.Brand.accent)
            .navigationTitle("Hermes")
            .onChange(of: address) { _, _ in resetSelection() }
            .onChange(of: profile) { _, _ in resetSelection() }
        }
        .preferredColorScheme(.dark)
    }

    @MainActor
    private func signIn(to reviewedTarget: AdminTarget) async {
        guard target == reviewedTarget, !signingIn else { return }
        signingIn = true
        connectionMessage = nil
        defer { signingIn = false }

        do {
            let publicTransport = URLSessionAdminTransport(target: reviewedTarget)
            let publicClient = HermesAdminClient(transport: publicTransport)
            let status = try await publicClient.readStatus(target: reviewedTarget)
            guard target == reviewedTarget else { return }
            guard status.authRequired, status.authFlows.contains("native_ios_pkce") else {
                connectionMessage = "This dashboard does not advertise iOS native sign-in. Update Hermes on the selected host."
                return
            }

            let session = AdminAuthSession(
                browser: SystemAdminWebAuthentication(),
                client: HermesAdminAuthClient(transport: publicTransport),
                credentialStore: KeychainAdminCredentialStore()
            )
            authSession = session
            if try await session.restore(target: reviewedTarget) == false {
                try await session.signIn(target: reviewedTarget)
            }
            guard target == reviewedTarget else { return }
            let authenticatedTransport = URLSessionAdminTransport(
                target: reviewedTarget,
                accessTokenProvider: { session.accessToken }
            )
            let verified = try await HermesAdminClient(transport: authenticatedTransport)
                .readOverview(target: reviewedTarget)
            guard target == reviewedTarget else { return }
            try await session.validate(identity: verified.identity)
            authSession = session
            overview = verified
        } catch {
            guard target == reviewedTarget else { return }
            authSession?.cancel()
            authSession = nil
            connectionMessage = "Dashboard sign-in was cancelled or could not be verified. Nothing was changed."
        }
    }

    @MainActor
    private func signOut() async {
        let session = authSession
        authSession = nil
        overview = nil
        connectionMessage = nil
        do {
            try await session?.signOut()
        } catch {
            connectionMessage = "The local dashboard credential could not be removed."
        }
    }

    private func resetSelection() {
        authSession?.cancel()
        target = nil
        overview = nil
        authSession = nil
        connectionMessage = nil
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
