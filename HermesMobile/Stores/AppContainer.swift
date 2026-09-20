import Foundation

@MainActor
@Observable
final class AppContainer {
    private static let apnsTokenDefaultsKey = "hermes.apns.deviceToken"
    private static let sharedDefaultContainer = AppContainer.makeDefault()

    let router = TabRouter()
    let sessionStore: AppSessionStore
    let pairingStore: PairingStore
    let hostStore: HermesHostStore
    let chatStore: ChatStore
    let inboxStore: InboxStore
    let permissionsStore: PermissionsStore
    let settingsStore: SettingsStore
    let talkStore: TalkStore
    let sensorUploadService: SensorUploadService?
    private let apiClient: RelayAPIClient?
    private let notificationService: (any NotificationServiceProtocol)?
    private let usesMockPairingService: Bool
    private var isInitialized = false
    private var hasFinishedLaunchAttempt = false
    private var isInitializing = false
    private(set) var isCompanionRuntimeActive = false
    private var pushOperationGeneration: UInt64 = 0
    private var lastCommandCatalogRefreshAt: Date?
    private var lastKnownHostOnline = false

    private static let commandCatalogRefreshInterval: TimeInterval = 60

    init(
        sessionStore: AppSessionStore,
        pairingStore: PairingStore,
        hostStore: HermesHostStore,
        chatStore: ChatStore,
        inboxStore: InboxStore,
        permissionsStore: PermissionsStore,
        settingsStore: SettingsStore,
        talkStore: TalkStore,
        sensorUploadService: SensorUploadService? = nil,
        apiClient: RelayAPIClient? = nil,
        notificationService: (any NotificationServiceProtocol)? = nil,
        usesMockPairingService: Bool = false
    ) {
        self.sessionStore = sessionStore
        self.pairingStore = pairingStore
        self.hostStore = hostStore
        self.chatStore = chatStore
        self.inboxStore = inboxStore
        self.permissionsStore = permissionsStore
        self.settingsStore = settingsStore
        self.talkStore = talkStore
        self.sensorUploadService = sensorUploadService
        self.apiClient = apiClient
        self.notificationService = notificationService
        self.usesMockPairingService = usesMockPairingService
    }

    static func sharedDefault() -> AppContainer {
        sharedDefaultContainer
    }

    var shouldShowLaunchSplash: Bool {
        pairingStore.isPaired && !hasFinishedLaunchAttempt
    }

    static func makeDefault(
        defaults: UserDefaults? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppContainer {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else if let suiteName = processEnvironment["UITEST_DEFAULTS_SUITE"] {
            resolvedDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            resolvedDefaults = .standard
        }

        let persistence = UserDefaultsAppPersistenceStore(defaults: resolvedDefaults)
        let buildConfiguration = AppBuildConfiguration.current()
        let usesMockPairingService = processEnvironment["UITEST_PAIRING_MODE"] == "mock"
        let secureStore: any SecureStoreProtocol = if usesMockPairingService {
            MockSecureStore(defaults: resolvedDefaults)
        } else {
            KeychainSecureStore(
                serviceName: processEnvironment["UITEST_KEYCHAIN_SERVICE"] ?? "cool.n0thing.hermes.session"
            )
        }
        let settingsStore = SettingsStore(
            persistence: persistence,
            buildConfiguration: buildConfiguration
        )
        if usesMockPairingService {
            settingsStore.settings.relayConfiguration = RelayConfiguration(
                customRelayBaseURL: "https://relay.test/v1"
            )
        }
        let syncCoordinator = MockSyncCoordinator()
        let notificationService = LiveNotificationService()
        let allowMockFallbacks = AppEnvironmentPolicy.currentBuild.allowsEnvironmentOverrides || usesMockPairingService
        let pairingService: any PairingServiceProtocol
        var activePairingStore: PairingStore?

        if processEnvironment["UITEST_PAIRING_MODE"] == "mock" {
            pairingService = MockPairingService()
        } else {
            pairingService = LivePairingService()
        }

        let apiClient = RelayAPIClient {
            activePairingStore?.pairedRelayConfiguration?.baseURLString
                ?? settingsStore.settings.relayConfiguration.activeBaseURLString
                ?? ""
        }

        let sessionBootstrapService: any SessionBootstrapServiceProtocol
        let inboxService: any InboxServiceProtocol
        if usesMockPairingService {
            sessionBootstrapService = MockSessionBootstrapService()
            inboxService = MockInboxService()
        } else {
            sessionBootstrapService = ResilientSessionBootstrapService(
                primary: LiveSessionBootstrapService(apiClient: apiClient),
                fallback: MockSessionBootstrapService(),
                allowsFallback: { allowMockFallbacks && activePairingStore?.isPaired != true }
            )

            inboxService = ResilientInboxService(
                primary: LiveInboxService(apiClient: apiClient),
                fallback: MockInboxService(),
                allowsFallback: { allowMockFallbacks && activePairingStore?.isPaired != true }
            )

        }

        let sessionStore = AppSessionStore(
            bootstrapService: sessionBootstrapService,
            syncCoordinator: syncCoordinator,
            secureStore: secureStore,
            persistence: persistence,
            notificationService: notificationService,
            environmentProvider: { settingsStore.settings.environment }
        )

        let runtimePairingStore = PairingStore(
            pairingService: pairingService,
            sessionStore: sessionStore,
            persistence: persistence,
            onboardingDefaults: resolvedDefaults,
            environmentProvider: { settingsStore.settings.environment },
            relayBaseURLProvider: { settingsStore.settings.relayConfiguration.activeBaseURLString }
        )
        activePairingStore = runtimePairingStore

        let hostService: any HermesHostServiceProtocol
        if usesMockPairingService {
            hostService = MockHermesHostService()
        } else {
            hostService = LiveHermesHostService(
                apiClient: apiClient,
                accessTokenRefresher: {
                    await sessionStore.refreshAccessTokenIfNeeded()
                    return await sessionStore.currentAccessToken()
                }
            )
        }

        let hostStore = HermesHostStore(
            hostService: hostService,
            accessTokenProvider: { await sessionStore.currentAccessToken() }
        )

        let hermesClient: any HermesClientProtocol
        if usesMockPairingService {
            hermesClient = MockHermesClient()
        } else {
            hermesClient = ResilientHermesClient(
                primary: LiveHermesClient(
                    apiClient: apiClient,
                    accessTokenProvider: { await sessionStore.currentAccessToken() },
                    accessTokenRefresher: {
                        await sessionStore.refreshAccessTokenIfNeeded()
                        return await sessionStore.currentAccessToken()
                    },
                    allowDemoFallback: false
                ),
                fallback: MockHermesClient(),
                allowsFallback: { allowMockFallbacks && activePairingStore?.isPaired != true }
            )
        }

        let liveLocationService = LiveLocationService()
        liveLocationService.updateSyncPreference(settingsStore.settings.locationSyncPreference)
        let liveHealthService = LiveHealthService(persistence: persistence)
        let liveMotionService = LiveMotionService()
        let sensorUploadService: SensorUploadService? = usesMockPairingService ? nil : SensorUploadService(
            apiClient: apiClient,
            accessTokenProvider: { await sessionStore.currentAccessToken() },
            accessTokenRefresher: {
                await sessionStore.refreshAccessTokenIfNeeded()
                return await sessionStore.currentAccessToken()
            },
            persistence: persistence,
            isPairedProvider: { activePairingStore?.isPaired == true },
            locationService: liveLocationService,
            healthService: liveHealthService,
            motionService: liveMotionService
        )
        let voiceService: any VoiceSessionServiceProtocol = if usesMockPairingService {
            MockVoiceSessionService()
        } else {
            LiveVoiceSessionService(
                apiClient: apiClient,
                accessTokenProvider: { await sessionStore.currentAccessToken() },
                accessTokenRefresher: {
                    await sessionStore.refreshAccessTokenIfNeeded()
                    return await sessionStore.currentAccessToken()
                }
            )
        }

        let container = AppContainer(
            sessionStore: sessionStore,
            pairingStore: runtimePairingStore,
            hostStore: hostStore,
            chatStore: ChatStore(hermesClient: hermesClient, persistence: persistence),
            inboxStore: InboxStore(
                inboxService: inboxService,
                persistence: persistence,
                sessionStore: sessionStore,
                allowDemoFallback: allowMockFallbacks
            ),
            permissionsStore: PermissionsStore(
                locationService: liveLocationService,
                healthService: liveHealthService,
                notificationService: notificationService,
                mediaService: processEnvironment["UITEST_PAIRING_MODE"] != nil ? MockMediaService() : LiveMediaService(),
                motionService: liveMotionService
            ),
            settingsStore: settingsStore,
            talkStore: TalkStore(voiceService: voiceService),
            sensorUploadService: sensorUploadService,
            apiClient: apiClient,
            notificationService: notificationService,
            usesMockPairingService: usesMockPairingService
        )

        runtimePairingStore.onPairingChanged = { [weak container] isPaired in
            if isPaired {
                await container?.handlePairingActivated()
            } else {
                await container?.handlePairingRemoved()
            }
        }

        // Keep widget data fresh while app is foregrounded
        container.chatStore.onConversationChanged = { [weak container] in
            container?.updateWidgetData()
        }
        container.talkStore.onSessionStateChanged = { [weak container] in
            container?.updateWidgetData()
        }
        container.hostStore.onHostChanged = { [weak container] in
            guard let container else { return }
            let isOnline = container.hostStore.isHostOnline
            let becameOnline = isOnline && container.lastKnownHostOnline == false
            container.lastKnownHostOnline = isOnline
            container.updateWidgetData()
            Task { [weak container] in
                await container?.refreshCommandCatalog(force: becameOnline)
            }
        }

        return container
    }

    func initialize() async {
        guard pairingStore.isPaired else { return }
        guard !isInitializing else { return }
        guard !isInitialized || sessionStore.state.connectionStatus == .error else { return }
        isInitializing = true
        defer {
            // Launch completion is independent of relay reachability. Leave the
            // paired UI available while a later foreground or manual retry recovers.
            hasFinishedLaunchAttempt = true
            isInitializing = false
        }
        guard await sessionStore.currentAccessToken() != nil else {
            await pairingStore.clearLocalPairing()
            return
        }

        await permissionsStore.reloadCapabilities()
        await sessionStore.bootstrap()
        guard sessionStore.state.connectionStatus == .connected else { return }
        await hostStore.refresh()
        lastKnownHostOnline = hostStore.isHostOnline
        await chatStore.loadConversationIfNeeded()
        await inboxStore.loadInbox()
        await refreshCommandCatalog(force: true)
        await registerStoredPushTokenIfNeeded()
        await activateDeviceServicesIfEnabled()
        reconcileLiveActivities()
        updateWidgetData()
        isInitialized = true
    }

    func handleAppDidBecomeActive() async {
        guard isCompanionRuntimeActive else { return }
        guard pairingStore.isPaired else { return }
        if !isInitialized || sessionStore.state.connectionStatus == .error {
            guard settingsStore.settings.autoConnectOnLaunch else { return }
            await initialize()
        }
        guard pairingStore.isPaired else { return }
        guard await sessionStore.currentAccessToken() != nil else { return }

        await permissionsStore.reloadCapabilities()
        await hostStore.refresh()
        lastKnownHostOnline = hostStore.isHostOnline
        await refreshCommandCatalog(force: true)
        await registerStoredPushTokenIfNeeded()
        await activateDeviceServicesIfEnabled()
        talkStore.handleAppDidBecomeActive()
        await talkStore.refreshReadiness()
        reconcileLiveActivities()
        await reportAppStateIfNeeded("foreground")
        updateWidgetData()
    }

    func handleRemoteNotificationWake() async -> Bool {
        guard settingsStore.settings.notificationConsentEstablished,
              settingsStore.settings.notificationsEnabled,
              storedPushToken != nil
        else { return false }
        guard pairingStore.isPaired else { return false }
        guard await sessionStore.currentAccessToken() != nil else { return false }
        isCompanionRuntimeActive = true

        await permissionsStore.reloadCapabilities()
        await hostStore.refresh()
        lastKnownHostOnline = hostStore.isHostOnline
        await registerStoredPushTokenIfNeeded()
        await sensorUploadService?.handleAppDidBecomeActive()
        talkStore.handleAppDidBecomeActive()
        await talkStore.refreshReadiness()
        reconcileLiveActivities()
        updateWidgetData()
        return true
    }

    func handleSystemLaunch() async {
        guard pairingStore.isPaired else { return }
        let resumesDeviceServices = settingsStore.settings.deviceServicesEnabled
        let resumesPush = settingsStore.settings.notificationConsentEstablished
            && settingsStore.settings.notificationsEnabled
        guard resumesDeviceServices || resumesPush else { return }
        guard await sessionStore.currentAccessToken() != nil else { return }
        isCompanionRuntimeActive = true

        if resumesDeviceServices {
            sensorUploadService?.start()
            await sensorUploadService?.handleSystemLaunch()
        }
        if resumesPush {
            await registerStoredPushTokenIfNeeded()
        }
    }

    private func handlePairingActivated() async {
        guard isCompanionRuntimeActive else { return }
        isInitialized = false
        hasFinishedLaunchAttempt = false
        chatStore.reset()
        inboxStore.reset()
        await initialize()
        await talkStore.refreshReadiness()
    }

    func activateCompanionRuntime() async {
        isCompanionRuntimeActive = true
        await initialize()
    }

    func setDeviceServicesEnabled(_ enabled: Bool) async {
        settingsStore.settings.deviceServicesEnabled = enabled
        await activateDeviceServicesIfEnabled()
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        settingsStore.settings.notificationConsentEstablished = true
        settingsStore.settings.notificationsEnabled = enabled
        let generation = beginPushOperation()
        if enabled {
            await registerStoredPushTokenIfNeeded(generation: generation)
        } else {
            await deactivatePushRegistration()
            guard generation == pushOperationGeneration else {
                await reconcilePushRegistrationIfNeeded(staleGeneration: generation)
                return
            }
            await notificationService?.markPushTokenRegistered(false)
            sessionStore.state.pushTokenRegistered = false
        }
    }

    private func activateDeviceServicesIfEnabled() async {
        guard settingsStore.settings.deviceServicesEnabled else {
            sensorUploadService?.stop()
            sensorUploadService?.resetOutbox()
            return
        }
        guard isCompanionRuntimeActive, pairingStore.isPaired else { return }
        sensorUploadService?.start()
        await sensorUploadService?.handleAppDidBecomeActive()
    }

    /// Registers the APNs device token with the relay so it can send silent push notifications.
    func registerPushTokenIfNeeded(_ token: String) async {
        let generation = beginPushOperation()
        await registerPushTokenIfNeeded(token, generation: generation)
    }

    private func registerPushTokenIfNeeded(_ token: String, generation: UInt64) async {
        guard pairingStore.isPaired,
              let apiClient,
              let notificationService
        else { return }

        // Respect the user's in-app notifications toggle.
        // If disabled, deactivate any existing registration on the relay
        // so the user actually stops receiving pushes.
        guard settingsStore.settings.notificationsEnabled else {
            // Always attempt deactivation — the relay may have an active
            // registration from a previous session even if the local flag is false.
            await deactivatePushRegistration()
            guard generation == pushOperationGeneration else {
                await reconcilePushRegistrationIfNeeded(staleGeneration: generation)
                return
            }
            await notificationService.markPushTokenRegistered(false)
            sessionStore.state.pushTokenRegistered = false
            return
        }

        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return }

        await notificationService.updatePushToken(normalizedToken)
        guard generation == pushOperationGeneration,
              settingsStore.settings.notificationsEnabled
        else { return }

        guard let accessToken = await sessionStore.currentAccessToken() else {
            guard generation == pushOperationGeneration else { return }
            await notificationService.markPushTokenRegistered(false)
            sessionStore.state.pushTokenRegistered = false
            return
        }
        guard generation == pushOperationGeneration,
              settingsStore.settings.notificationsEnabled
        else { return }

        if notificationService.isPushTokenRegistered,
           notificationService.currentPushToken == normalizedToken {
            sessionStore.state.pushTokenRegistered = true
            return
        }

        guard let deviceID = sessionStore.state.deviceID else {
            await notificationService.markPushTokenRegistered(false)
            sessionStore.state.pushTokenRegistered = false
            return
        }

        #if DEBUG
        let pushEnvironment = "development"
        #else
        let pushEnvironment = "production"
        #endif

        struct PushRegisterBody: Encodable {
            let deviceId: String
            let apnsToken: String
            let pushEnvironment: String
            let bundleId: String
        }

        let body = PushRegisterBody(
            deviceId: deviceID.uuidString.lowercased(),
            apnsToken: normalizedToken,
            pushEnvironment: pushEnvironment,
            bundleId: Bundle.main.bundleIdentifier ?? "cool.n0thing.hermes"
        )

        struct PushRegisterResponse: Decodable {
            let data: PushData?
            struct PushData: Decodable { let registered: Bool }
        }

        do {
            let _: PushRegisterResponse = try await apiClient.post(
                path: "push/register",
                body: body,
                accessToken: accessToken
            )
            guard generation == pushOperationGeneration else {
                await reconcilePushRegistrationIfNeeded(staleGeneration: generation)
                return
            }
            await notificationService.markPushTokenRegistered(true)
            sessionStore.state.pushTokenRegistered = true
        } catch {
            guard generation == pushOperationGeneration else { return }
            // Non-critical — token will be retried on next app launch
            await notificationService.markPushTokenRegistered(false)
            sessionStore.state.pushTokenRegistered = false
        }
    }

    /// Tells the relay to deactivate push registrations for this device.
    private func deactivatePushRegistration() async {
        guard let apiClient,
              let accessToken = await sessionStore.currentAccessToken() else { return }

        struct DeactivateResponse: Decodable {
            let deactivated: Bool?
        }

        _ = try? await apiClient.post(
            path: "push/deactivate",
            accessToken: accessToken
        ) as DeactivateResponse
    }

    private func reconcilePushRegistrationIfNeeded(staleGeneration: UInt64) async {
        guard staleGeneration != pushOperationGeneration else { return }
        let currentGeneration = pushOperationGeneration

        if settingsStore.settings.notificationsEnabled {
            await notificationService?.markPushTokenRegistered(false)
            guard currentGeneration == pushOperationGeneration else {
                await reconcilePushRegistrationIfNeeded(staleGeneration: currentGeneration)
                return
            }
            sessionStore.state.pushTokenRegistered = false
            await registerStoredPushTokenIfNeeded(generation: currentGeneration)
        } else {
            await deactivatePushRegistration()
            guard currentGeneration == pushOperationGeneration else {
                await reconcilePushRegistrationIfNeeded(staleGeneration: currentGeneration)
                return
            }
            await notificationService?.markPushTokenRegistered(false)
            sessionStore.state.pushTokenRegistered = false
        }
    }

    private var storedPushToken: String? {
        UserDefaults.standard.string(forKey: Self.apnsTokenDefaultsKey)
    }

    private func beginPushOperation() -> UInt64 {
        pushOperationGeneration &+= 1
        return pushOperationGeneration
    }

    private func registerStoredPushTokenIfNeeded(generation: UInt64? = nil) async {
        guard let storedToken else {
            return
        }
        let resolvedGeneration = generation ?? beginPushOperation()
        await registerPushTokenIfNeeded(storedToken, generation: resolvedGeneration)
    }

    /// Fetches the dynamic slash command catalog from the connected Hermes host.
    /// Merges built-in commands, gateway commands, skills, and personality options.
    func refreshCommandCatalog(force: Bool = false) async {
        guard !usesMockPairingService else { return }
        if !force,
           let lastCommandCatalogRefreshAt,
           Date().timeIntervalSince(lastCommandCatalogRefreshAt) < Self.commandCatalogRefreshInterval {
            return
        }

        guard let token = await sessionStore.currentAccessToken(),
              let client = apiClient else { return }

        struct CatalogResponse: Decodable {
            let commands: [RemoteCommand]?
            let skills: [RemoteSkill]?
            let personalities: [RemotePersonality]?
            let quickCommands: [RemoteQuickCommand]?
            let activeModel: ActiveModel?

            struct RemoteCommand: Decodable {
                let name: String
                let description: String
                let category: String?
                let args: String?
            }
            struct RemoteSkill: Decodable {
                let name: String
                let description: String
            }
            struct RemotePersonality: Decodable {
                let name: String
                let description: String
            }
            struct RemoteQuickCommand: Decodable {
                let name: String
                let description: String
            }
            struct ActiveModel: Decodable {
                let name: String
                let provider: String?
                let contextWindow: Int?
            }
        }

        do {
            let response: CatalogResponse = try await client.get(
                path: "commands",
                accessToken: token
            )

            var catalog = SlashCommand.localCommands
            var catalogIDs = Set(catalog.map(\.id))
            let remoteCommands = response.commands ?? []
            let skills = response.skills ?? []
            let personalities = response.personalities ?? []
            let quickCommands = response.quickCommands ?? []

            // Add remote built-in commands (skip any that overlap with local)
            for cmd in remoteCommands {
                let command = SlashCommand.fromRemote(
                    name: cmd.name,
                    description: cmd.description,
                    category: cmd.category ?? "Agent",
                    args: cmd.args
                )
                if catalogIDs.insert(command.id).inserted {
                    catalog.append(command)
                }
            }

            // Add skill commands
            for skill in skills {
                let command = SlashCommand.fromSkill(name: skill.name, description: skill.description)
                if catalogIDs.insert(command.id).inserted {
                    catalog.append(command)
                }
            }

            // `/personality <name>` suggestions only appear once the user starts
            // typing `/personality`, keeping the top-level dropdown manageable.
            for personality in personalities {
                let command = SlashCommand.fromPersonality(
                    name: personality.name,
                    description: personality.description
                )
                if catalogIDs.insert(command.id).inserted {
                    catalog.append(command)
                }
            }

            // Hermes docs say quick commands resolve at dispatch time and are not
            // included in built-in autocomplete tables, but we still track them so
            // typed commands can be considered part of the known catalog.
            for quickCommand in quickCommands {
                let command = SlashCommand.fromQuickCommand(
                    name: quickCommand.name,
                    description: quickCommand.description
                )
                if catalogIDs.insert(command.id).inserted {
                    catalog.append(command)
                }
            }

            if remoteCommands.isEmpty && skills.isEmpty && personalities.isEmpty && quickCommands.isEmpty {
                chatStore.resetCommandCatalog()
            } else {
                chatStore.replaceCommandCatalog(
                    catalog,
                    activeModel: response.activeModel?.name,
                    contextWindow: response.activeModel?.contextWindow
                )
                lastCommandCatalogRefreshAt = .now
            }
        } catch {
            // Fallback to built-in list — catalog is a nice-to-have
            chatStore.resetCommandCatalog()
        }
    }

    func reportAppStateIfNeeded(_ state: String) async {
        guard pairingStore.isPaired, let apiClient, let accessToken = await sessionStore.currentAccessToken() else {
            return
        }

        struct AppStateBody: Encodable {
            let state: String
        }

        struct AppStateResponse: Decodable {}

        _ = try? await apiClient.post(
            path: "device/app-state",
            body: AppStateBody(state: state),
            accessToken: accessToken
        ) as AppStateResponse
    }

    /// Snapshots current app state into the App Group shared container
    /// so Home Screen widgets and CarPlay widgets can display it.
    func updateWidgetData() {
        let lastMessage = chatStore.conversation?.messages.last
        var data = SharedWidgetDataStore.read()
        data.hostName = hostStore.currentHost?.resolvedDisplayName
        data.hostOnline = hostStore.isHostOnline
        data.voiceSessionActive = talkStore.isSessionActive
        data.updatedAt = .now
        if let msg = lastMessage {
            data.lastMessagePreview = String(msg.content.prefix(120))
            data.lastMessageSender = msg.sender.rawValue
            data.lastMessageAt = msg.timestamp
        }
        SharedWidgetDataStore.write(data)
    }

    private func handlePairingRemoved() async {
        isInitialized = false
        hasFinishedLaunchAttempt = false
        await talkStore.endSessionIfNeeded()
        talkStore.reset()
        sensorUploadService?.stop()
        sensorUploadService?.resetOutbox()
        router.selectedTab = .chat
        router.activeSheet = nil
        router.resetAll()
        chatStore.reset()
        inboxStore.reset()
        hostStore.reset()
        lastKnownHostOnline = false
        lastCommandCatalogRefreshAt = nil
        LiveActivityService.endAllActivities()
        SharedWidgetDataStore.write(.empty)
    }

    private func reconcileLiveActivities() {
        if talkStore.isSessionActive || chatStore.isStreaming {
            return
        }
        LiveActivityService.endAllActivities()
    }
}
