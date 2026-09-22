import SwiftUI

/// Read-only Skills, Tools/toolsets, and MCP servers screens (M2 Batch 2). No create/edit/
/// toggle/enable/disable/test/auth mutation paths are wired here even though the server
/// exposes them; those remain M4 scope. Follows the same read pattern and authority-loss
/// handling as ProfilesSessionsViews.swift (M2 Batch 1).

struct SkillsListView: View {
    let target: AdminTarget
    let client: HermesAdminClient
    var onAuthorityLost: @MainActor () -> Void = {}

    @State private var skills: [AdminSkillSummary] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var loadedOnce = false

    var body: some View {
        Form {
            Section("Reviewed target") {
                LabeledContent("Dashboard", value: target.baseURL.absoluteString)
                LabeledContent("Profile", value: target.profile)
            }

            if loading && !loadedOnce {
                Section {
                    ProgressView("Loading skills…")
                }
            } else if skills.isEmpty, loadedOnce, errorMessage == nil {
                Section {
                    Text("No skills were returned by this dashboard.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Skills · \(skills.count)") {
                    ForEach(skills) { skill in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(skill.name)
                                    .font(Design.Typography.body)
                                Spacer()
                                Text(skill.enabled ? "Enabled" : "Disabled")
                                    .font(Design.Typography.footnote)
                                    .foregroundStyle(skill.enabled ? Design.Brand.accent : .secondary)
                            }
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(Design.Typography.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            HStack(spacing: 12) {
                                if !skill.category.isEmpty {
                                    Label(skill.category, systemImage: "folder")
                                }
                                Label(skill.provenance.capitalized, systemImage: "tag")
                                if skill.usage > 0 {
                                    Label("\(skill.usage) uses", systemImage: "chart.bar")
                                }
                            }
                            .font(Design.Typography.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("admin.skills.row.\(skill.name)")
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
                    .accessibilityIdentifier("admin.skills.refresh")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Colors.background)
        .foregroundStyle(Design.Colors.foreground)
        .tint(Design.Brand.accent)
        .navigationTitle("Skills")
        .task { if !loadedOnce { await load() } }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false; loadedOnce = true }
        do {
            skills = try await client.readSkills(target: target)
        } catch {
            if adminSignalsAuthorityLost(error) {
                errorMessage = "Dashboard sign-in expired. Go back and sign in again."
                onAuthorityLost()
            } else {
                errorMessage = "Could not load skills. Existing list, if any, remains visible."
            }
        }
    }
}

struct ToolsetsListView: View {
    let target: AdminTarget
    let client: HermesAdminClient
    var onAuthorityLost: @MainActor () -> Void = {}

    @State private var toolsets: [AdminToolsetSummary] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var loadedOnce = false

    var body: some View {
        Form {
            Section("Reviewed target") {
                LabeledContent("Dashboard", value: target.baseURL.absoluteString)
                LabeledContent("Profile", value: target.profile)
            }

            if loading && !loadedOnce {
                Section {
                    ProgressView("Loading toolsets…")
                }
            } else if toolsets.isEmpty, loadedOnce, errorMessage == nil {
                Section {
                    Text("No toolsets were returned by this dashboard.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Toolsets · \(toolsets.count)") {
                    ForEach(toolsets) { toolset in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(toolset.label)
                                    .font(Design.Typography.body)
                                Spacer()
                                Text(toolset.enabled ? "Enabled" : "Disabled")
                                    .font(Design.Typography.footnote)
                                    .foregroundStyle(toolset.enabled ? Design.Brand.accent : .secondary)
                            }
                            if !toolset.description.isEmpty {
                                Text(toolset.description)
                                    .font(Design.Typography.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            HStack(spacing: 12) {
                                if !toolset.platformLabel.isEmpty {
                                    Label(toolset.platformLabel, systemImage: "desktopcomputer")
                                }
                                Label(
                                    toolset.configured ? "Configured" : "Not configured",
                                    systemImage: toolset.configured ? "checkmark.circle" : "circle"
                                )
                                if !toolset.tools.isEmpty {
                                    Label("\(toolset.tools.count) tools", systemImage: "wrench")
                                }
                            }
                            .font(Design.Typography.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("admin.toolsets.row.\(toolset.name)")
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
                    .accessibilityIdentifier("admin.toolsets.refresh")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Colors.background)
        .foregroundStyle(Design.Colors.foreground)
        .tint(Design.Brand.accent)
        .navigationTitle("Tools")
        .task { if !loadedOnce { await load() } }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false; loadedOnce = true }
        do {
            toolsets = try await client.readToolsets(target: target)
        } catch {
            if adminSignalsAuthorityLost(error) {
                errorMessage = "Dashboard sign-in expired. Go back and sign in again."
                onAuthorityLost()
            } else {
                errorMessage = "Could not load toolsets. Existing list, if any, remains visible."
            }
        }
    }
}

struct MCPServersListView: View {
    let target: AdminTarget
    let client: HermesAdminClient
    var onAuthorityLost: @MainActor () -> Void = {}

    @State private var servers: [AdminMCPServerSummary] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var loadedOnce = false

    var body: some View {
        Form {
            Section("Reviewed target") {
                LabeledContent("Dashboard", value: target.baseURL.absoluteString)
                LabeledContent("Profile", value: target.profile)
            }

            if loading && !loadedOnce {
                Section {
                    ProgressView("Loading MCP servers…")
                }
            } else if servers.isEmpty, loadedOnce, errorMessage == nil {
                Section {
                    Text("No MCP servers were returned by this dashboard.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("MCP servers · \(servers.count)") {
                    ForEach(servers) { server in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(server.name)
                                    .font(Design.Typography.body)
                                Spacer()
                                Text(server.enabled ? "Enabled" : "Disabled")
                                    .font(Design.Typography.footnote)
                                    .foregroundStyle(server.enabled ? Design.Brand.accent : .secondary)
                            }
                            if let url = server.url, !url.isEmpty {
                                Text(url)
                                    .font(Design.Typography.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else if let command = server.command, !command.isEmpty {
                                Text(command)
                                    .font(Design.Typography.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            HStack(spacing: 12) {
                                Label(server.transport.uppercased(), systemImage: "network")
                                if let auth = server.auth, !auth.isEmpty {
                                    Label(auth.capitalized, systemImage: "lock")
                                }
                                if let tools = server.tools {
                                    Label("\(tools.count) tools", systemImage: "wrench")
                                } else {
                                    Label("All tools", systemImage: "wrench")
                                }
                            }
                            .font(Design.Typography.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("admin.mcp.row.\(server.name)")
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
                    .accessibilityIdentifier("admin.mcp.refresh")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Colors.background)
        .foregroundStyle(Design.Colors.foreground)
        .tint(Design.Brand.accent)
        .navigationTitle("MCP Servers")
        .task { if !loadedOnce { await load() } }
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false; loadedOnce = true }
        do {
            servers = try await client.readMCPServers(target: target)
        } catch {
            if adminSignalsAuthorityLost(error) {
                errorMessage = "Dashboard sign-in expired. Go back and sign in again."
                onAuthorityLost()
            } else {
                errorMessage = "Could not load MCP servers. Existing list, if any, remains visible."
            }
        }
    }
}

/// Simple hub screen linking to Skills, Tools, and MCP — mirrors how ProfilesListView links
/// through to SessionsListView, keeping the "Manage Hermes" entry a single NavigationLink.
struct SkillsToolsMCPHubView: View {
    let target: AdminTarget
    let client: HermesAdminClient
    var onAuthorityLost: @MainActor () -> Void = {}

    var body: some View {
        Form {
            Section("Reviewed target") {
                LabeledContent("Dashboard", value: target.baseURL.absoluteString)
                LabeledContent("Profile", value: target.profile)
            }
            Section {
                NavigationLink {
                    SkillsListView(target: target, client: client, onAuthorityLost: onAuthorityLost)
                } label: {
                    Label("Skills", systemImage: "sparkles")
                }
                .accessibilityIdentifier("admin.skills.open")

                NavigationLink {
                    ToolsetsListView(target: target, client: client, onAuthorityLost: onAuthorityLost)
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier("admin.toolsets.open")

                NavigationLink {
                    MCPServersListView(target: target, client: client, onAuthorityLost: onAuthorityLost)
                } label: {
                    Label("MCP Servers", systemImage: "server.rack")
                }
                .accessibilityIdentifier("admin.mcp.open")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.Colors.background)
        .foregroundStyle(Design.Colors.foreground)
        .tint(Design.Brand.accent)
        .navigationTitle("Skills, Tools & MCP")
    }
}
