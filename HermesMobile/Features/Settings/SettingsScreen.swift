import SwiftUI

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AppContainer.self) private var container
    @Environment(AppSessionStore.self) private var sessionStore
    @Environment(HermesHostStore.self) private var hostStore
    @Environment(PairingStore.self) private var pairingStore
    @Environment(PermissionsStore.self) private var permissionsStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(TabRouter.self) private var router
    @State private var isSystemCockpitPresented = false
    let showsDismissButton: Bool

    init(showsDismissButton: Bool = true) {
        self.showsDismissButton = showsDismissButton
    }

    var body: some View {
        ZStack {
            Design.Colors.background
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: Design.Spacing.lg) {
                    connectionSection
                    adminCockpitSection
                    relaySection
                    if settingsStore.availableEnvironments.count > 1 {
                        environmentSection
                    }
                    preferencesSection
                    deviceAccessSection
                    locationSection
                    privacySection
                    aboutSection
                }
                .padding(.horizontal, Design.Spacing.md)
                .padding(.vertical, Design.Spacing.sm)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if showsDismissButton {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: Design.Size.iconSmall, weight: .semibold))
                            .foregroundStyle(Design.Colors.foreground)
                    }
                }
            }
        }
        .task {
            await hostStore.refresh()
            await permissionsStore.reloadCapabilities()
        }
        .fullScreenCover(isPresented: $isSystemCockpitPresented) {
            NavigationStack {
                SystemCockpitScreen()
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        SettingsSectionView(title: "Connection") {
            VStack(spacing: 0) {
                settingsRow(
                    icon: sessionStore.state.connectionStatus.displayIcon,
                    iconColor: sessionStore.state.connectionStatus.displayColor,
                    title: "Status",
                    value: sessionStore.state.connectionStatus.displayLabel
                )

                sectionDivider

                if pairingStore.pairedRelayConfiguration != nil {
                    settingsNavRow(
                        icon: hostStatusRowIcon,
                        iconColor: hostStatusRowColor,
                        title: "Hermes Host",
                        value: hostStatusRowValue,
                        accessibilityIdentifier: "settings.hermesHost"
                    ) {
                        dismiss()
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            router.navigate(to: .connectHost)
                        }
                    }

                    sectionDivider
                }

                settingsToggle(
                    icon: "bolt.fill",
                    iconColor: Design.Brand.accent,
                    title: "Reconnect When Active",
                    isOn: autoConnectBinding
                )
            }
        }
    }

    // MARK: - Admin Cockpit

    private var adminCockpitSection: some View {
        SettingsSectionView(title: "System") {
            settingsNavRow(
                icon: "gauge.with.dots.needle.67percent",
                iconColor: Design.Brand.accent,
                title: "System Cockpit",
                value: "Private status"
            ) {
                isSystemCockpitPresented = true
            }
        }
    }

    // MARK: - Environment

    private var relaySection: some View {
        SettingsSectionView(title: "Relay") {
            VStack(alignment: .leading, spacing: Design.Spacing.sm) {
                if pairingStore.isPaired {
                    settingsRow(
                        icon: "point.3.connected.trianglepath.dotted",
                        iconColor: Design.Brand.accent,
                        title: "Active Relay",
                        value: pairingStore.pairedRelayConfiguration?.hostDisplayName ?? relayConfiguration.relayOriginLabel
                    )
                    sectionDivider
                    settingsRow(
                        icon: "link",
                        iconColor: .secondary,
                        title: "Base URL",
                        value: pairingStore.pairedRelayConfiguration?.baseURLString ?? relayConfiguration.activeBaseURLString ?? "Not configured"
                    )
                    Text("Disconnect Hermes before changing the relay configuration.")
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Colors.secondaryForeground)
                        .padding(.top, Design.Spacing.xs)
                } else {
                    if relayConfiguration.canUseHosted {
                        Picker("Relay Mode", selection: relayModeBinding) {
                            Text(RelayMode.custom.displayLabel).tag(RelayMode.custom)
                            Text(RelayMode.hosted.displayLabel).tag(RelayMode.hosted)
                        }
                        .pickerStyle(.segmented)

                        sectionDivider
                    }

                    if relayConfiguration.relayMode == .custom {
                        VStack(alignment: .leading, spacing: Design.Spacing.xs) {
                            TextField("https://your-relay.example.com/v1", text: customRelayURLBinding)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .font(Design.Typography.callout.monospaced())
                                .foregroundStyle(Design.Colors.foreground)
                                .padding(Design.Spacing.md)
                                .background(Design.Colors.background, in: RoundedRectangle(cornerRadius: Design.CornerRadius.lg))

                            Text("Enter the relay API base URL your connector will use.")
                                .font(Design.Typography.caption)
                                .foregroundStyle(Design.Colors.secondaryForeground)
                        }
                    } else if let hostedRelayBaseURL = relayConfiguration.hostedRelayBaseURL {
                        settingsRow(
                            icon: "cloud",
                            iconColor: Design.Brand.accent,
                            title: "Hosted Relay",
                            value: hostedRelayBaseURL
                        )
                    }

                    if let relayValidationMessage {
                        Text(relayValidationMessage)
                            .font(Design.Typography.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var hostStatusRowIcon: String {
        switch hostStore.connectionState {
        case .online:
            return "desktopcomputer"
        case .offline:
            return "desktopcomputer.trianglebadge.exclamationmark"
        case .unreachable:
            return "wifi.exclamationmark"
        case .notConnected:
            return "desktopcomputer"
        }
    }

    private var hostStatusRowColor: Color {
        switch hostStore.connectionState {
        case .online:
            return .green
        case .offline, .unreachable:
            return .orange
        case .notConnected:
            return Design.Colors.secondaryForeground
        }
    }

    private var hostStatusRowValue: String {
        switch hostStore.connectionState {
        case .online, .offline:
            return hostStore.currentHost?.resolvedDisplayName ?? "Hermes Host"
        case .unreachable:
            return "Status unavailable"
        case .notConnected:
            return "Not Connected"
        }
    }

    private var environmentSection: some View {
        SettingsSectionView(title: "Internal Environment") {
            VStack(spacing: 0) {
                ForEach(Array(settingsStore.availableEnvironments.enumerated()), id: \.element) { index, env in
                    Button {
                        withAnimation(Design.Motion.quickResponse) {
                            settingsStore.settings.environment = env
                        }
                    } label: {
                        HStack {
                            Text(env.displayLabel)
                                .font(Design.Typography.callout)
                                .foregroundStyle(Design.Colors.foreground)

                            Spacer()

                            if settingsStore.settings.environment == env {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Design.Brand.accent)
                            }
                        }
                        .frame(minHeight: Design.Size.minTapTarget)
                    }

                    if index < settingsStore.availableEnvironments.count - 1 {
                        sectionDivider
                    }
                }
            }
        }
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        SettingsSectionView(title: "Preferences") {
            VStack(spacing: 0) {
                settingsToggle(
                    icon: "bell.fill",
                    iconColor: .orange,
                    title: "Notifications",
                    isOn: notificationsBinding
                )

                sectionDivider

                settingsToggle(
                    icon: "hand.tap.fill",
                    iconColor: .purple,
                    title: "Haptic Feedback",
                    isOn: hapticBinding
                )
            }
        }
    }

    // MARK: - Device Access

    private var deviceAccessSection: some View {
        SettingsSectionView(title: "Device Access") {
            VStack(alignment: .leading, spacing: Design.Spacing.sm) {
                settingsToggle(
                    icon: "sensor.tag.radiowaves.forward.fill",
                    iconColor: .teal,
                    title: "Device Data Sync",
                    isOn: deviceServicesBinding
                )
                Text(settingsStore.settings.deviceServicesEnabled
                     ? "Authorized location, health, and motion data can sync through the paired relay. Individual iOS permissions still apply. Turning this off stops monitoring and removes queued device samples."
                     : "Off by default. Chat and dashboard administration continue without sensor collection or upload.")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Colors.secondaryForeground)

                sectionDivider

                settingsNavRow(
                    icon: "lock.shield.fill",
                    iconColor: .green,
                    title: "Permissions"
                ) {
                    router.navigate(to: .permissions)
                }
            }
        }
    }

    // MARK: - Location

    private var locationSection: some View {
        SettingsSectionView(title: "Location") {
            VStack(alignment: .leading, spacing: Design.Spacing.sm) {
                settingsRow(
                    icon: "location.fill",
                    iconColor: .blue,
                    title: "Authorization",
                    value: permissionsStore.locationAuthorizationLevel.displayLabel
                )

                sectionDivider

                settingsRow(
                    icon: "scope",
                    iconColor: .blue,
                    title: "Accuracy",
                    value: permissionsStore.locationAccuracyLevel.displayLabel
                )

                sectionDivider

                settingsToggle(
                    icon: "location.circle.fill",
                    iconColor: .blue,
                    title: "Background Location",
                    isOn: backgroundLocationBinding
                )
                .disabled(!settingsStore.settings.deviceServicesEnabled)

                Text(backgroundLocationDescription)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Colors.secondaryForeground)
            }
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        SettingsSectionView(title: "Privacy") {
            settingsNavRow(
                icon: "lock.shield.fill",
                iconColor: .green,
                title: "Permissions"
            ) {
                if showsDismissButton {
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        router.navigate(to: .permissions)
                    }
                } else {
                    router.navigate(to: .permissions)
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsSectionView(title: "About") {
            VStack(spacing: 0) {
                settingsRow(
                    icon: "info.circle",
                    iconColor: .secondary,
                    title: "Version",
                    value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "1"))"
                )

                if settingsStore.buildConfiguration.termsOfServiceURL != nil {
                    sectionDivider
                    settingsNavRow(
                        icon: "doc.text",
                        iconColor: .secondary,
                        title: "Terms of Service"
                    ) {
                        openConfiguredURL(settingsStore.buildConfiguration.termsOfServiceURL)
                    }
                }

                if settingsStore.buildConfiguration.privacyPolicyURL != nil {
                    sectionDivider
                    settingsNavRow(
                        icon: "hand.raised",
                        iconColor: .secondary,
                        title: "Privacy Policy"
                    ) {
                        openConfiguredURL(settingsStore.buildConfiguration.privacyPolicyURL)
                    }
                }

                if settingsStore.buildConfiguration.supportURL != nil {
                    sectionDivider

                    settingsNavRow(
                        icon: "questionmark.circle",
                        iconColor: .secondary,
                        title: "Support"
                    ) {
                        openConfiguredURL(settingsStore.buildConfiguration.supportURL)
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private var autoConnectBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.autoConnectOnLaunch },
            set: { settingsStore.settings.autoConnectOnLaunch = $0 }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.notificationsEnabled },
            set: { newValue in
                Task {
                    if newValue {
                        await permissionsStore.requestPermission(for: .notifications)
                        await permissionsStore.reloadCapabilities()
                        let notificationStatus = permissionsStore.capabilities
                            .first(where: { $0.permissionType == .notifications })?.status
                        let granted = notificationStatus == .authorized || notificationStatus == .limited
                        await container.setNotificationsEnabled(granted)
                        if granted {
                            UIApplication.shared.registerForRemoteNotifications()
                        } else {
                            UIApplication.shared.unregisterForRemoteNotifications()
                        }
                    } else {
                        await container.setNotificationsEnabled(false)
                        UIApplication.shared.unregisterForRemoteNotifications()
                    }
                }
            }
        )
    }

    private var hapticBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.hapticFeedbackEnabled },
            set: { settingsStore.settings.hapticFeedbackEnabled = $0 }
        )
    }

    private var deviceServicesBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.deviceServicesEnabled },
            set: { enabled in
                Task { await container.setDeviceServicesEnabled(enabled) }
            }
        )
    }

    private var backgroundLocationBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.locationSyncPreference == .backgroundAllowed },
            set: { isEnabled in
                guard settingsStore.settings.deviceServicesEnabled else { return }
                let preference: LocationSyncPreference = isEnabled ? .backgroundAllowed : .foregroundOnly
                settingsStore.settings.locationSyncPreference = preference
                permissionsStore.updateLocationSyncPreference(preference)

                guard isEnabled else { return }

                Task {
                    switch permissionsStore.locationAuthorizationLevel {
                    case .denied, .restricted:
                        permissionsStore.openLocationSystemSettings()
                    case .always, .whenInUse:
                        // Both levels support CLBackgroundActivitySession.
                        // While In Use shows blue indicator; Always does not.
                        await permissionsStore.requestBackgroundLocationAccess()
                    case .notDetermined:
                        await permissionsStore.requestBackgroundLocationAccess()
                    }
                }
            }
        )
    }

    private var relayConfiguration: RelayConfiguration {
        settingsStore.settings.relayConfiguration
    }

    private var relayValidationMessage: String? {
        relayConfiguration.validationMessage
    }

    private var backgroundLocationDescription: String {
        guard settingsStore.settings.deviceServicesEnabled else {
            return "Device Data Sync is off. Enable it before requesting or using background location."
        }
        if settingsStore.settings.locationSyncPreference == .backgroundAllowed {
            switch permissionsStore.locationAuthorizationLevel {
            case .always:
                return "Hermes receives location updates in the background without the blue indicator."
            case .whenInUse:
                return "Hermes receives background location updates. A blue indicator appears at the top of the screen when active."
            case .notDetermined:
                return "Enabling this will request location access so Hermes can sync while backgrounded."
            case .denied, .restricted:
                return "Location is blocked at the system level. Open Settings to allow Hermes to request background updates."
            }
        }

        return "Foreground-only keeps location updates limited to active app use."
    }

    private var relayModeBinding: Binding<RelayMode> {
        Binding(
            get: { settingsStore.settings.relayConfiguration.relayMode },
            set: { newValue in
                var relayConfiguration = settingsStore.settings.relayConfiguration
                relayConfiguration.relayMode = newValue
                settingsStore.settings.relayConfiguration = relayConfiguration
            }
        )
    }

    private var customRelayURLBinding: Binding<String> {
        Binding(
            get: { settingsStore.settings.relayConfiguration.customRelayBaseURL },
            set: { newValue in
                var relayConfiguration = settingsStore.settings.relayConfiguration
                relayConfiguration.customRelayBaseURL = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                settingsStore.settings.relayConfiguration = relayConfiguration
            }
        )
    }

    // MARK: - Row Components

    private var sectionDivider: some View {
        Divider()
            .overlay(Design.Colors.divider)
    }

    private func settingsRow(icon: String, iconColor: Color, title: String, value: String?) -> some View {
        HStack(spacing: Design.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 20, alignment: .center)

            Text(title)
                .font(Design.Typography.callout)
                .foregroundStyle(Design.Colors.foreground)

            Spacer()

            if let value {
                Text(value)
                    .font(Design.Typography.callout)
                    .foregroundStyle(Design.Colors.secondaryForeground)
            }
        }
        .frame(minHeight: Design.Size.minTapTarget)
    }

    @ViewBuilder
    private func settingsNavRow(
        icon: String,
        iconColor: Color,
        title: String,
        value: String? = nil,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let row = Button(action: action) {
            HStack(spacing: Design.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
                    .frame(width: 20, alignment: .center)

                Text(title)
                    .font(Design.Typography.callout)
                    .foregroundStyle(Design.Colors.foreground)

                Spacer()

                if let value {
                    Text(value)
                        .font(Design.Typography.callout)
                        .foregroundStyle(Design.Colors.secondaryForeground)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Design.Colors.secondaryForeground)
            }
            .frame(minHeight: Design.Size.minTapTarget)
        }

        if let accessibilityIdentifier {
            row.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            row
        }
    }

    private func settingsToggle(
        icon: String,
        iconColor: Color,
        title: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: Design.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
                    .frame(width: 20, alignment: .center)

                Text(title)
                    .font(Design.Typography.callout)
                    .foregroundStyle(Design.Colors.foreground)
            }
        }
        .tint(Design.Brand.accent)
        .frame(minHeight: Design.Size.minTapTarget)
    }

    private func openConfiguredURL(_ url: URL?) {
        guard let url else { return }
        openURL(url)
    }
}
