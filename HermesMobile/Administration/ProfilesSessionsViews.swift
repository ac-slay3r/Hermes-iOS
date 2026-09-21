import SwiftUI

/// Read-only Profiles & Sessions screens (M2 Batch 1). No create/rename/delete/clone/archive
/// mutation paths are wired here even though the server exposes them; those remain M4 scope.

struct ProfilesListView: View {
    let target: AdminTarget
    let client: HermesAdminClient
    let overview: AdminOverview

    @State private var profiles: [AdminProfileSummary] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var loadedOnce = false

    var body: some View {
        Form {
            Section("Reviewed target") {
                LabeledContent("Dashboard", value: target.baseURL.absoluteString)
                LabeledContent("Selected profile", value: target.profile)
                LabeledContent("Serving profile", value: overview.profiles.current)
                LabeledContent("Sticky active profile", value: overview.profiles.active)
            }

            if loading && !loadedOnce {
                Section {
                    ProgressView("Loading profiles…")
                }
            } else if profiles.isEmpty, loadedOnce, errorMessage == nil {
                Section {
                    Text("No profiles were returned by this dashboard.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Profile inventory · \(profiles.count)") {
                    ForEach(profiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(profile.displayName.isEmpty ? profile.name : profile.displayName)
                                    .font(Design.Typography.body)
                                Spacer()
                                if profile.name == target.profile {
                                    Text("Selected")
                                        .font(Design.Typography.footnote)
                                        .foregroundStyle(Design.Brand.accent)
                                }
                                if profile.name == overview.profiles.current {
                                    Text("Serving")
                                        .font(Design.Typography.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if profile.name != profile.displayName, !profile.displayName.isEmpty {
                                Text(profile.name)
                                    .font(Design.Typography.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 12) {
                                if let provider = profile.provider, !provider.isEmpty {
                                    Label(provider, systemImage: "cpu")
                                }
                                if let model = profile.model, !model.isEmpty {
                                    Label(model, systemImage: "brain")
                                }
                                Label(
                                    profile.gatewayRunning ? "Running" : "Stopped",
                                    systemImage: profile.gatewayRunning ? "play.circle" : "stop.circle"
                                )
                            }
                            .font(Design.Typography.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("admin.profiles.row.\(profile.name)")
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
                    .accessibilityIdentifier("admin.profiles.refresh")
                }
            }

            Section {
                NavigationLink {
                    SessionsListView(target: target, client: client)
                } label: {
                    Label("Sessions", systemImage: "bubble.left.and.bubble.right")
                }
                .accessibilityIdentifier("admin.sessions.open")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Colors.background)
        .foregroundStyle(Design.Colors.foreground)
        .tint(Design.Brand.accent)
        .navigationTitle("Profiles")
        .task { if !loadedOnce { await load() } }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false; loadedOnce = true }
        do {
            profiles = try await client.readProfiles(target: target)
        } catch {
            errorMessage = "Could not load profiles. Existing list, if any, remains visible."
        }
    }
}

struct SessionsListView: View {
    let target: AdminTarget
    let client: HermesAdminClient

    @State private var page: AdminSessionListPage?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var loadedOnce = false
    @State private var searchText = ""

    var body: some View {
        Form {
            Section("Reviewed target") {
                LabeledContent("Dashboard", value: target.baseURL.absoluteString)
                LabeledContent("Profile", value: target.profile)
            }

            Section("Search") {
                TextField("Search sessions", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await search() } }
                    .accessibilityIdentifier("admin.sessions.search")
                if !searchText.isEmpty {
                    Button("Clear search") {
                        searchText = ""
                        Task { await load() }
                    }
                }
            }

            if loading && !loadedOnce {
                Section {
                    ProgressView("Loading sessions…")
                }
            } else if let page {
                Section("Sessions · \(page.total)") {
                    if page.sessions.isEmpty {
                        Text("No sessions match this view.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(page.sessions) { session in
                        NavigationLink {
                            SessionDetailView(target: target, client: client, sessionID: session.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(session.title?.isEmpty == false ? session.title! : "Untitled session")
                                        .font(Design.Typography.body)
                                    Spacer()
                                    if session.isActive {
                                        Text("Active")
                                            .font(Design.Typography.footnote)
                                            .foregroundStyle(Design.Brand.accent)
                                    }
                                }
                                if !session.preview.isEmpty {
                                    Text(session.preview)
                                        .font(Design.Typography.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                HStack(spacing: 8) {
                                    if session.pinned {
                                        Label("Pinned", systemImage: "pin.fill")
                                    }
                                    if session.archived {
                                        Label("Archived", systemImage: "archivebox")
                                    }
                                    if session.unread {
                                        Label("Unread", systemImage: "circle.fill")
                                    }
                                }
                                .font(Design.Typography.footnote)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("admin.sessions.row.\(session.id)")
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
                        Task { searchText.isEmpty ? await load() : await search() }
                    }
                    .accessibilityIdentifier("admin.sessions.refresh")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Colors.background)
        .foregroundStyle(Design.Colors.foreground)
        .tint(Design.Brand.accent)
        .navigationTitle("Sessions")
        .task { if !loadedOnce { await load() } }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false; loadedOnce = true }
        do {
            page = try await client.readSessions(target: target)
        } catch {
            errorMessage = "Could not load sessions. Existing list, if any, remains visible."
        }
    }

    @MainActor
    private func search() async {
        guard !loading, !searchText.isEmpty else { return }
        loading = true
        errorMessage = nil
        defer { loading = false; loadedOnce = true }
        do {
            page = try await client.searchSessions(target: target, query: searchText)
        } catch {
            errorMessage = "Search failed. Existing list, if any, remains visible."
        }
    }
}

struct SessionDetailView: View {
    let target: AdminTarget
    let client: HermesAdminClient
    let sessionID: String

    @State private var detail: AdminSessionDetail?
    @State private var messages: [AdminSessionMessage] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var loadedOnce = false

    var body: some View {
        Form {
            Section("Exact target") {
                Text(target.baseURL.absoluteString)
                LabeledContent("Profile", value: target.profile)
                LabeledContent("Session", value: sessionID)
            }

            if loading && !loadedOnce {
                Section {
                    ProgressView("Loading session…")
                }
            } else if let detail {
                Section("Session") {
                    LabeledContent("Title", value: detail.title?.isEmpty == false ? detail.title! : "Untitled")
                    LabeledContent("Archived", value: detail.archived ? "Yes" : "No")
                    LabeledContent("Pinned", value: detail.pinned ? "Yes" : "No")
                }

                Section("Messages · \(messages.count)") {
                    if messages.isEmpty {
                        Text("No messages returned for this session.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role.capitalized)
                                .font(Design.Typography.footnote)
                                .foregroundStyle(Design.Brand.accent)
                            Text(message.displayContent ?? message.content ?? "")
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
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
                    .accessibilityIdentifier("admin.sessionDetail.refresh")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Colors.background)
        .foregroundStyle(Design.Colors.foreground)
        .tint(Design.Brand.accent)
        .navigationTitle("Session")
        .task { if !loadedOnce { await load() } }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false; loadedOnce = true }
        do {
            async let detailFetch = client.readSessionDetail(target: target, id: sessionID)
            async let messagesFetch = client.readSessionMessages(target: target, id: sessionID)
            detail = try await detailFetch
            messages = try await messagesFetch
        } catch {
            errorMessage = "Could not read this session. Check sign-in, authority and profile."
        }
    }
}
