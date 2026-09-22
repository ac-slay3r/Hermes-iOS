import SwiftUI

/// Read-only Automation/Connections and Logs screens (M2 Batch 3). Cron jobs, messaging
/// platforms, webhooks, pairing, and log tail — all render-only. No trigger/pause/resume/
/// approve/revoke/config/test wired here; each carries real-world side effects (executes
/// work, delivers messages, authorizes users, spends money) and belongs to a later,
/// explicit-consequence milestone.
struct AutomationConnectionsHubView: View {
    let client: HermesAdminClient
    let target: AdminTarget
    let onAuthorityLost: @MainActor () -> Void

    var body: some View {
        List {
            Section("Automation") {
                NavigationLink {
                    CronJobsListView(client: client, target: target, onAuthorityLost: onAuthorityLost)
                } label: {
                    Label("Cron jobs", systemImage: "clock.badge")
                }
            }
            Section("Connections") {
                NavigationLink {
                    MessagingPlatformsView(client: client, target: target, onAuthorityLost: onAuthorityLost)
                } label: {
                    Label("Messaging platforms", systemImage: "bubble.left.and.bubble.right")
                }
                NavigationLink {
                    WebhooksListView(client: client, target: target, onAuthorityLost: onAuthorityLost)
                } label: {
                    Label("Webhooks", systemImage: "arrow.triangle.branch")
                }
                NavigationLink {
                    PairingStatusView(client: client, target: target, onAuthorityLost: onAuthorityLost)
                } label: {
                    Label("Pairing", systemImage: "link.badge.plus")
                }
            }
            Section("Diagnostics") {
                NavigationLink {
                    LogsView(client: client, target: target, onAuthorityLost: onAuthorityLost)
                } label: {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .navigationTitle("Automation & connections")
    }
}

@MainActor
private func classify(_ error: Error, onAuthorityLost: @MainActor () -> Void) -> String {
    if adminSignalsAuthorityLost(error) {
        onAuthorityLost()
        return "Sign-in expired. Please sign in again."
    }
    return "Could not load this data. Check the connection and try again."
}

// MARK: - Cron jobs

struct CronJobsListView: View {
    let client: HermesAdminClient
    let target: AdminTarget
    let onAuthorityLost: @MainActor () -> Void

    @State private var jobs: [AdminCronJobSummary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(jobs) { job in
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name).font(.headline)
                    Text(job.scheduleDisplay).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(job.enabled ? "Enabled" : "Disabled")
                            .font(.caption2)
                            .foregroundStyle(job.enabled ? .green : .secondary)
                        if let profile = job.profile {
                            Text(profile).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if jobs.isEmpty && !isLoading && errorMessage == nil {
                Text("No cron jobs configured.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Cron jobs")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            jobs = try await client.readCronJobs(target: target)
        } catch {
            errorMessage = classify(error, onAuthorityLost: onAuthorityLost)
        }
    }
}

// MARK: - Messaging platforms

struct MessagingPlatformsView: View {
    let client: HermesAdminClient
    let target: AdminTarget
    let onAuthorityLost: @MainActor () -> Void

    @State private var platforms: [AdminMessagingPlatformSummary] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(platforms) { platform in
                VStack(alignment: .leading, spacing: 4) {
                    Text(platform.name).font(.headline)
                    HStack {
                        Text(platform.enabled ? "Enabled" : "Disabled")
                            .font(.caption)
                            .foregroundStyle(platform.enabled ? .green : .secondary)
                        Text(platform.configured ? "Configured" : "Not configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(platform.gatewayRunning ? "Running" : "Stopped")
                            .font(.caption)
                            .foregroundStyle(platform.gatewayRunning ? .green : .orange)
                    }
                    if let errText = platform.errorMessage {
                        Text(errText).font(.caption2).foregroundStyle(.red)
                    }
                }
            }
            if platforms.isEmpty && !isLoading && errorMessage == nil {
                Text("No messaging platforms configured.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Messaging platforms")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            platforms = try await client.readMessagingPlatforms(target: target)
        } catch {
            errorMessage = classify(error, onAuthorityLost: onAuthorityLost)
        }
    }
}

// MARK: - Webhooks

struct WebhooksListView: View {
    let client: HermesAdminClient
    let target: AdminTarget
    let onAuthorityLost: @MainActor () -> Void

    @State private var status: AdminWebhooksStatus?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if let status {
                Section {
                    HStack {
                        Text(status.enabled ? "Webhooks enabled" : "Webhooks disabled")
                        Spacer()
                        if let baseURL = status.baseURL {
                            Text(baseURL).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(status.subscriptions) { hook in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hook.name).font(.headline)
                        if !hook.description.isEmpty {
                            Text(hook.description).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(hook.enabled ? "Enabled" : "Disabled")
                                .font(.caption2)
                                .foregroundStyle(hook.enabled ? .green : .secondary)
                            Text(hook.deliver).font(.caption2).foregroundStyle(.secondary)
                            Text(hook.secretSet ? "Secret set" : "No secret")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if !hook.events.isEmpty {
                            Text(hook.events.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if status.subscriptions.isEmpty && errorMessage == nil {
                    Text("No webhooks configured.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Webhooks")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            status = try await client.readWebhooks(target: target)
        } catch {
            errorMessage = classify(error, onAuthorityLost: onAuthorityLost)
        }
    }
}

// MARK: - Pairing

struct PairingStatusView: View {
    let client: HermesAdminClient
    let target: AdminTarget
    let onAuthorityLost: @MainActor () -> Void

    @State private var status: AdminPairingStatus?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if let status {
                Section("Pending (\(status.pending.count))") {
                    ForEach(status.pending) { entry in
                        row(entry)
                    }
                    if status.pending.isEmpty {
                        Text("No pending pairing requests.").foregroundStyle(.secondary)
                    }
                }
                Section("Approved (\(status.approved.count))") {
                    ForEach(status.approved) { entry in
                        row(entry)
                    }
                    if status.approved.isEmpty {
                        Text("No approved pairings.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Pairing")
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func row(_ entry: AdminPairingEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayName ?? entry.id).font(.subheadline)
            if let source = entry.source {
                Text(source).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            status = try await client.readPairing(target: target)
        } catch {
            errorMessage = classify(error, onAuthorityLost: onAuthorityLost)
        }
    }
}

// MARK: - Logs

struct LogsView: View {
    let client: HermesAdminClient
    let target: AdminTarget
    let onAuthorityLost: @MainActor () -> Void

    @State private var result: AdminLogsResult?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var searchText = ""

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if let result {
                ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                }
                if result.lines.isEmpty && errorMessage == nil {
                    Text("No matching log lines.").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Logs")
        .searchable(text: $searchText, prompt: "Search log text")
        .onSubmit(of: .search) { Task { await load() } }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            result = try await client.readLogs(
                target: target,
                search: searchText.isEmpty ? nil : searchText
            )
        } catch {
            errorMessage = classify(error, onAuthorityLost: onAuthorityLost)
        }
    }
}
