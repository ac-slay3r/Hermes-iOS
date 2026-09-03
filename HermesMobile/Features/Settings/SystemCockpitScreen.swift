import SwiftUI

struct SystemCockpitScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSessionStore.self) private var sessionStore
    @Environment(PairingStore.self) private var pairingStore

    @State private var status: AdminCockpitStatus?
    @State private var auditEvents: [AdminCockpitAuditEvent] = []
    @State private var errorMessage: String?
    @State private var isRefreshing = false

    var body: some View {
        ZStack {
            Design.Colors.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.lg) {
                    header
                    if let status {
                        healthOverview(status)
                        pairedDevices(status.devices)
                        if let guidance = AdminCockpitPresentation.recoveryGuidance(
                            relayStatus: status.relay.status,
                            hostStatus: status.host.status
                        ) {
                            recoveryGuidance(guidance)
                        }
                        auditTimeline
                    } else if isRefreshing {
                        ProgressView("Refreshing private system status…")
                            .tint(Design.Brand.accent)
                            .foregroundStyle(Design.Colors.foreground)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        unavailableState
                    }
                }
                .padding(Design.Spacing.md)
                .padding(.bottom, Design.Spacing.xxl)
            }
            .refreshable { await refresh() }
        }
        .navigationTitle("System Cockpit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
                    .foregroundStyle(Design.Brand.accent)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh system status")
                .accessibilityIdentifier("systemCockpit.refresh")
            }
        }
        .task { await refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.xs) {
            Text("Private system status")
                .font(Design.Typography.screenTitle)
                .foregroundStyle(Design.Colors.foreground)
            Text("Read-only status and audit metadata for your connected relay.")
                .font(Design.Typography.callout)
                .foregroundStyle(Design.Colors.secondaryForeground)
        }
    }

    private func healthOverview(_ status: AdminCockpitStatus) -> some View {
        SettingsSectionView(title: "Connection health") {
            VStack(spacing: 0) {
                statusRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Relay",
                    status: AdminCockpitPresentation.title(for: status.relay.status),
                    color: status.relay.status.lowercased() == "ok" ? .green : .orange,
                    detail: status.relay.status.lowercased() == "ok" ? "Reachable" : "Unavailable"
                )
                divider
                statusRow(
                    icon: "desktopcomputer",
                    title: "Hermes Host",
                    status: AdminCockpitPresentation.title(for: status.host.status),
                    color: hostColor(status.host.status),
                    detail: AdminCockpitPresentation.freshness(status.host.lastSeenAt)
                )
            }
        }
    }

    private func pairedDevices(_ devices: [AdminCockpitStatus.Device]) -> some View {
        SettingsSectionView(title: "Paired devices (\(devices.count))") {
            VStack(spacing: 0) {
                if devices.isEmpty {
                    Text("No paired devices are available for this account.")
                        .font(Design.Typography.callout)
                        .foregroundStyle(Design.Colors.secondaryForeground)
                        .frame(maxWidth: .infinity, minHeight: Design.Size.minTapTarget, alignment: .leading)
                } else {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        deviceRow(device)
                        if index < devices.count - 1 { divider }
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: AdminCockpitStatus.Device) -> some View {
        let state = AdminCockpitPresentation.deviceState(status: device.status, lastSeenAt: device.lastSeenAt)
        return HStack(alignment: .top, spacing: Design.Spacing.sm) {
            Image(systemName: device.platform.lowercased() == "ios" ? "iphone" : "desktopcomputer")
                .font(.system(size: Design.Size.iconSmall))
                .foregroundStyle(deviceColor(state))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: Design.Spacing.xxs) {
                Text(device.name)
                    .font(Design.Typography.callout)
                    .foregroundStyle(Design.Colors.foreground)
                Text("\(AdminCockpitPresentation.title(for: device.platform)) · \(deviceStateLabel(state))")
                    .font(Design.Typography.caption)
                    .foregroundStyle(deviceColor(state))
                Text(AdminCockpitPresentation.freshness(device.lastSeenAt))
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Colors.secondaryForeground)
            }
            Spacer()
        }
        .frame(minHeight: Design.Size.minTapTarget)
        .accessibilityElement(children: .combine)
    }

    private var auditTimeline: some View {
        SettingsSectionView(title: "Private audit timeline") {
            VStack(alignment: .leading, spacing: Design.Spacing.sm) {
                if auditEvents.isEmpty {
                    Text("No audit metadata is available yet.")
                        .font(Design.Typography.callout)
                        .foregroundStyle(Design.Colors.secondaryForeground)
                } else {
                    ForEach(auditEvents) { event in
                        HStack(alignment: .top, spacing: Design.Spacing.sm) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: Design.Size.iconSmall))
                                .foregroundStyle(Design.Colors.secondaryForeground)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: Design.Spacing.xxs) {
                                Text(AdminCockpitPresentation.title(for: event.action.replacingOccurrences(of: ".", with: " ")))
                                    .font(Design.Typography.callout)
                                    .foregroundStyle(Design.Colors.foreground)
                                Text("Actor: \(event.actorType) · Entity: \(event.entityType)")
                                    .font(Design.Typography.caption)
                                    .foregroundStyle(Design.Colors.secondaryForeground)
                                if let entityId = event.entityId {
                                    Text("Entity ID: \(entityId)")
                                        .font(Design.Typography.caption.monospaced())
                                        .foregroundStyle(Design.Colors.secondaryForeground)
                                }
                                Text(event.occurredAt, style: .relative)
                                    .font(Design.Typography.caption)
                                    .foregroundStyle(Design.Colors.secondaryForeground)
                            }
                        }
                    }
                }
            }
        }
    }

    private func recoveryGuidance(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Design.Spacing.sm) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: Design.Spacing.xxs) {
                Text("Safe recovery")
                    .font(Design.Typography.headline)
                    .foregroundStyle(Design.Colors.foreground)
                Text(text)
                    .font(Design.Typography.callout)
                    .foregroundStyle(Design.Colors.secondaryForeground)
            }
        }
        .padding(Design.Spacing.md)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Design.CornerRadius.lg))
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.sm) {
            Text("System status unavailable")
                .font(Design.Typography.sectionTitle)
                .foregroundStyle(Design.Colors.foreground)
            Text(errorMessage ?? "Pair with a relay to view your private system status.")
                .font(Design.Typography.callout)
                .foregroundStyle(Design.Colors.secondaryForeground)
            Text("Check your network and relay connection, then refresh. This screen does not make system changes.")
                .font(Design.Typography.callout)
                .foregroundStyle(Design.Colors.secondaryForeground)
            Button("Refresh") { Task { await refresh() } }
                .foregroundStyle(Design.Brand.accent)
                .disabled(isRefreshing)
        }
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
    }

    private var divider: some View {
        Divider().overlay(Design.Colors.divider)
    }

    private func statusRow(icon: String, title: String, status: String, color: Color, detail: String) -> some View {
        HStack(spacing: Design.Spacing.sm) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: Design.Spacing.xxs) {
                Text(title).font(Design.Typography.callout).foregroundStyle(Design.Colors.foreground)
                Text(detail).font(Design.Typography.caption).foregroundStyle(Design.Colors.secondaryForeground)
            }
            Spacer()
            Text(status).font(Design.Typography.callout).foregroundStyle(color)
        }
        .frame(minHeight: Design.Size.minTapTarget)
    }

    private func hostColor(_ status: String) -> Color {
        status.lowercased() == "online" ? .green : .orange
    }

    private func deviceColor(_ state: AdminCockpitDeviceState) -> Color {
        switch state {
        case .current: .green
        case .stale: .orange
        case .unavailable: .red
        }
    }

    private func deviceStateLabel(_ state: AdminCockpitDeviceState) -> String {
        switch state {
        case .current: "Current"
        case .stale: "Stale"
        case .unavailable: "Unavailable"
        }
    }

    @MainActor
    private func refresh() async {
        guard pairingStore.isPaired, let relayURL = pairingStore.pairedRelayConfiguration?.baseURLString else {
            status = nil
            auditEvents = []
            errorMessage = nil
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let client = RelayAPIClient(baseURLProvider: { relayURL })
            let token = await sessionStore.currentAccessToken()
            status = try await client.get(path: "admin/status", accessToken: token)
            let audit: AdminCockpitAuditResponse = try await client.get(path: "admin/audit", accessToken: token)
            auditEvents = audit.events
            errorMessage = nil
        } catch {
            status = nil
            auditEvents = []
            errorMessage = "The relay cannot be reached. Check your network and relay connection, then refresh."
        }
    }
}
