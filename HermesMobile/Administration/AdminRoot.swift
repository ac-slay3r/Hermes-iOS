import SwiftUI

enum CombinedAppSection: String, CaseIterable, Identifiable {
    case dashboard
    case chat
    case device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .chat: "Chat"
        case .device: "Device"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .chat: "bubble.left.and.bubble.right"
        case .device: "iphone.gen3"
        }
    }
}

struct CombinedAppRoot: View {
    @Environment(AppContainer.self) private var container
    @State private var selectedSection: CombinedAppSection = .dashboard

    var body: some View {
        TabView(selection: $selectedSection) {
            AdminRoot()
                .tabItem { Label(CombinedAppSection.dashboard.title, systemImage: CombinedAppSection.dashboard.icon) }
                .tag(CombinedAppSection.dashboard)

            AppRootView()
                .tabItem { Label(CombinedAppSection.chat.title, systemImage: CombinedAppSection.chat.icon) }
                .tag(CombinedAppSection.chat)

            DeviceAccessRoot()
                .tabItem { Label(CombinedAppSection.device.title, systemImage: CombinedAppSection.device.icon) }
                .tag(CombinedAppSection.device)
        }
        .tint(Design.Brand.accent)
        .task(id: selectedSection) {
            guard selectedSection != .dashboard else { return }
            await container.activateCompanionRuntime()
        }
        .onChange(of: selectedSection) { _, _ in
            container.router.dismissSheet()
            container.router.popToRoot()
        }
    }
}

struct DeviceAccessRoot: View {
    @Environment(AppContainer.self) private var container
    @Environment(TabRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: router.pathBinding()) {
            Group {
                if !container.pairingStore.isPaired {
                    ConnectHermesScreen()
                } else if container.pairingStore.needsPermissionsOnboarding {
                    PermissionsOnboardingScreen()
                } else {
                    SettingsScreen(showsDismissButton: false)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .permissions: PermissionsScreen()
                case .capture: CaptureScreen()
                case .connectHost: ConnectHermesHostScreen()
                }
            }
        }
    }
}

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
    @State private var refreshingOverview = false
    @State private var connectionMessage: String?
    private let targetPersistence: any AdminTargetPersistenceProtocol

    init(targetPersistence: any AdminTargetPersistenceProtocol = .liveAdminTargetPersistence) {
        self.targetPersistence = targetPersistence
    }

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
                            targetPersistence.saveLastAdminTarget(address: address, profile: profile)
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
                    if let overview {
                        NavigationLink {
                            AdminOverviewView(
                                overview: overview,
                                refreshing: refreshingOverview,
                                refreshMessage: connectionMessage,
                                onRefresh: { await refreshOverview() }
                            )
                        } label: {
                            Label("Overview & health", systemImage: "gauge.with.dots.needle.50percent")
                        }
                        .accessibilityIdentifier("admin.overview")
                    } else {
                        Label("Overview & health", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    }
                    plannedArea("Configuration & models", systemImage: "slider.horizontal.3")
                    if let overview, let authSession {
                        NavigationLink {
                            ProfilesListView(
                                target: overview.target,
                                client: HermesAdminClient(transport: URLSessionAdminTransport(
                                    target: overview.target,
                                    accessTokenProvider: { authSession.accessToken }
                                )),
                                overview: overview,
                                onAuthorityLost: { handleAuthorityLost(for: overview.target, session: authSession) }
                            )
                        } label: {
                            Label("Profiles & sessions", systemImage: "person.2")
                        }
                        .accessibilityIdentifier("admin.profilesSessions")
                    } else {
                        plannedArea("Profiles & sessions", systemImage: "person.2", reason: "Locked")
                    }
                    if let overview, let authSession {
                        NavigationLink {
                            SkillsToolsMCPHubView(
                                target: overview.target,
                                client: HermesAdminClient(transport: URLSessionAdminTransport(
                                    target: overview.target,
                                    accessTokenProvider: { authSession.accessToken }
                                )),
                                onAuthorityLost: { handleAuthorityLost(for: overview.target, session: authSession) }
                            )
                        } label: {
                            Label("Skills, tools & MCP", systemImage: "wrench.and.screwdriver")
                        }
                        .accessibilityIdentifier("admin.skillsToolsMcp")
                    } else {
                        plannedArea("Skills, tools & MCP", systemImage: "wrench.and.screwdriver", reason: "Locked")
                    }
                    plannedArea("Memory & instructions", systemImage: "brain.head.profile")
                    plannedArea("Automation & connections", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    plannedArea("System & operations", systemImage: "server.rack")
                    Text(overview == nil
                         ? "Overview unlocks after this dashboard verifies sign-in and profile context."
                         : "Overview is available now. Remaining management areas are clearly marked as planned rather than presented as working controls.")
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
            .task { restoreLastTarget() }
        }
        .preferredColorScheme(.dark)
    }

    /// Restores only the last-reviewed, non-secret address/profile fields so the user
    /// does not retype them every launch. Does not restore `target` or attempt sign-in;
    /// the user still explicitly reviews and authenticates, matching existing behavior.
    private func restoreLastTarget() {
        guard address.isEmpty, let saved = targetPersistence.loadLastAdminTarget() else { return }
        address = saved.address
        profile = saved.profile
    }

    @ViewBuilder
    private func plannedArea(_ title: String, systemImage: String, reason: String = "Planned") -> some View {
        LabeledContent {
            Text(reason)
                .font(Design.Typography.footnote)
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)
        }
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

    @MainActor
    private func refreshOverview() async {
        guard let reviewedTarget = target,
              let session = authSession,
              overview != nil,
              !refreshingOverview
        else { return }
        refreshingOverview = true
        connectionMessage = nil
        defer { refreshingOverview = false }

        do {
            let transport = URLSessionAdminTransport(
                target: reviewedTarget,
                accessTokenProvider: { session.accessToken }
            )
            let refreshed = try await HermesAdminClient(transport: transport)
                .readOverview(target: reviewedTarget)
            guard target == reviewedTarget, authSession === session else { return }
            try await session.validate(identity: refreshed.identity)
            overview = refreshed
        } catch {
            guard target == reviewedTarget, authSession === session else { return }
            let hasAuthority = session.accessToken != nil && session.authenticatedTarget == reviewedTarget
            if AdminOverviewRefreshPolicy.invalidatesSession(error, sessionHasAuthority: hasAuthority) {
                session.cancel()
                authSession = nil
                overview = nil
                connectionMessage = "Dashboard authority could not be verified. Sign in again before continuing."
            } else {
                connectionMessage = "Status refresh failed. Existing verified values remain visible."
            }
        }
    }

    private func resetSelection() {
        authSession?.cancel()
        target = nil
        overview = nil
        authSession = nil
        connectionMessage = nil
    }

    /// Called from a pushed read-only screen (Profiles/Sessions/detail) when its own request
    /// hits a wrong-target/401/403. Mirrors refreshOverview's handling: only the exact session
    /// and target that were live when this fired are cleared, avoiding a stale callback from an
    /// already-superseded screen invalidating a newer sign-in.
    @MainActor
    private func handleAuthorityLost(for reviewedTarget: AdminTarget, session: AdminAuthSession) {
        guard target == reviewedTarget, authSession === session else { return }
        session.cancel()
        authSession = nil
        overview = nil
        connectionMessage = "Dashboard authority could not be verified. Sign in again before continuing."
    }
}

enum AdminOverviewRefreshPolicy {
    static func invalidatesSession(_ error: Error, sessionHasAuthority: Bool) -> Bool {
        guard sessionHasAuthority else { return true }
        guard let adminError = error as? AdminError else { return false }
        switch adminError {
        case .wrongTarget, .http(401), .http(403):
            return true
        default:
            return false
        }
    }
}

struct AdminOverviewView: View {
    let overview: AdminOverview
    let refreshing: Bool
    let refreshMessage: String?
    let onRefresh: @MainActor () async -> Void

    var body: some View {
        Form {
            Section("Reviewed target") {
                LabeledContent("Dashboard", value: overview.target.baseURL.absoluteString)
                LabeledContent("Selected profile", value: overview.target.profile)
                LabeledContent("Serving profile", value: overview.profiles.current)
                LabeledContent("Sticky active profile", value: overview.profiles.active)
            }

            Section("Host health") {
                LabeledContent("Overall", value: overview.status.overall.capitalized)
                LabeledContent("Gateway", value: overview.status.gatewayRunning ? "Running" : "Stopped")
                if let state = overview.status.gatewayState, !state.isEmpty {
                    LabeledContent("Gateway state", value: state)
                }
                LabeledContent("Hermes version", value: overview.status.version)
                LabeledContent("Active agents", value: String(overview.status.activeAgents))
                LabeledContent("Active sessions", value: String(overview.status.activeSessions))
            }

            Section("Authenticated identity") {
                LabeledContent("Name", value: overview.identity.displayName)
                LabeledContent("Email", value: overview.identity.email.isEmpty ? "Not provided" : overview.identity.email)
                LabeledContent("Provider", value: overview.identity.provider)
            }

            Section("Profile inventory") {
                LabeledContent("Available profiles", value: String(overview.status.availableProfiles.count))
                ForEach(overview.status.availableProfiles, id: \.self) { profile in
                    HStack {
                        Text(profile)
                        Spacer()
                        if profile == overview.target.profile {
                            Text("Selected")
                                .font(Design.Typography.footnote)
                                .foregroundStyle(Design.Brand.accent)
                        }
                    }
                }
            }

            Section {
                if refreshing {
                    ProgressView("Refreshing status…")
                } else {
                    Button("Refresh status", systemImage: "arrow.clockwise") {
                        Task { await onRefresh() }
                    }
                    .accessibilityIdentifier("admin.overview.refresh")
                }
                if let refreshMessage {
                    Text(refreshMessage)
                        .font(Design.Typography.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Colors.background)
        .foregroundStyle(Design.Colors.foreground)
        .tint(Design.Brand.accent)
        .navigationTitle("Overview")
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
