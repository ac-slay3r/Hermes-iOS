"""Focused source regressions for combined-shell review blockers.

These guards run on Linux; native XCTest remains the behavioral authority.
"""
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text()


class CombinedShellReviewRegressionTests(unittest.TestCase):
    def test_throwing_decode_is_not_nested_in_boolean_operator(self):
        settings = source("HermesMobile/Models/UserSettings.swift")
        self.assertIn("let decodedNotificationsEnabled = try container.decodeIfPresent", settings)
        self.assertIn("notificationConsentEstablished && decodedNotificationsEnabled", settings)
        self.assertNotIn("&& (try container.decodeIfPresent", settings)

    def test_sensor_drain_is_generation_bound_and_stop_does_not_unlock_stale_work(self):
        text = source("HermesMobile/Services/Live/SensorUploadService.swift")
        self.assertIn("private var drainGeneration", text)
        self.assertIn("drainGeneration &+= 1", text)
        self.assertIn("guard generation == drainGeneration", text)
        stop = text.split("func stop()", 1)[1].split("func resetOutbox()", 1)[0]
        self.assertNotIn("isDraining = false", stop)
        self.assertIn("invalidateDrain()", stop)
        self.assertIn("currentUploadTask?.cancel()", stop)
        reset = text.split("func resetOutbox()", 1)[1].split("func handleAppDidBecomeActive", 1)[0]
        self.assertIn("invalidateDrain()", reset)
        self.assertIn("currentUploadTask?.cancel()", reset)
        capture = text.split("private func captureHealthSnapshot", 1)[1].split("private func drainOutboxIfPossible", 1)[0]
        self.assertIn("generation == drainGeneration", capture)
        self.assertIn("!Task.isCancelled", capture)

    def test_remote_wake_is_consent_token_and_work_gated(self):
        container = source("HermesMobile/Stores/AppContainer.swift")
        entry = source("HermesMobile/AppEntry.swift")
        signature = "func handleRemoteNotificationWake() async -> Bool"
        self.assertIn(signature, container)
        wake = container.split(signature, 1)[1].split("func handleSystemLaunch", 1)[0]
        self.assertIn("notificationConsentEstablished", wake)
        self.assertIn("notificationsEnabled", wake)
        self.assertIn("storedPushToken", wake)
        self.assertIn("return true", wake)
        self.assertIn("let didWork = await container.handleRemoteNotificationWake()", entry)
        self.assertIn("completionHandler(didWork ? .newData : .noData)", entry)

    def test_push_mutations_are_versioned_and_compensate_stale_enable(self):
        text = source("HermesMobile/Stores/AppContainer.swift")
        self.assertIn("private var pushOperationGeneration", text)
        self.assertIn("pushOperationGeneration &+= 1", text)
        self.assertIn("guard generation == pushOperationGeneration", text)
        self.assertIn("await deactivatePushRegistration", text)
        self.assertIn("reconcilePushRegistrationIfNeeded", text)
        disabled_branch = text.split("guard settingsStore.settings.notificationsEnabled else", 1)[1].split("let normalizedToken", 1)[0]
        self.assertIn("await deactivatePushRegistration", disabled_branch)
        self.assertIn("reconcilePushRegistrationIfNeeded", disabled_branch)
        self.assertIn("stale", text.lower())
        self.assertIn("guard let storedToken = storedPushToken else", text)

    def test_remote_revocation_is_fail_closed_with_bounded_retry_and_visible_error(self):
        session = source("HermesMobile/Stores/AppSessionStore.swift")
        pairing = source("HermesMobile/Stores/PairingStore.swift")
        live = source("HermesMobile/Services/Live/LiveSessionBootstrapService.swift")
        self.assertIn("remoteRevocationAttemptLimit", session)
        self.assertIn("for attempt in 1...Self.remoteRevocationAttemptLimit", session)
        disconnect = pairing.split("func disconnect", 1)[1].split("func completePermissionsOnboarding", 1)[0]
        self.assertIn("async -> Bool", disconnect)
        self.assertIn("guard await sessionStore.revokeCurrentSession()", disconnect)
        self.assertIn("return false", disconnect)
        self.assertLess(disconnect.index("guard await sessionStore.revokeCurrentSession()"), disconnect.index("await clearLocalPairing"))
        self.assertIn("sessionStore.lastErrorMessage", disconnect)
        self.assertNotIn("clearSession", session.split("func revokeCurrentSession", 1)[1].split("func clearSession", 1)[0])
        self.assertIn("guard response.revoked else", live)

    def test_permissions_are_least_privilege_and_background_location_is_inert_when_sync_off(self):
        permissions = source("HermesMobile/Stores/PermissionsStore.swift")
        onboarding = source("HermesMobile/Models/PermissionType.swift")
        settings = source("HermesMobile/Features/Settings/SettingsScreen.swift")
        self.assertNotIn("DeviceCapability(permissionType: .photos", permissions)
        self.assertNotIn(".photos", onboarding.split("static let onboardingPermissions", 1)[1].split("\n", 1)[0])
        self.assertIn("live voice camera", onboarding.lower())
        toggle = settings.split("title: \"Background Location\"", 1)[1].split("Text(backgroundLocationDescription)", 1)[0]
        self.assertIn(".disabled(!settingsStore.settings.deviceServicesEnabled)", toggle)
        self.assertIn("Device Data Sync is off", settings)
        binding = settings.split("private var backgroundLocationBinding", 1)[1].split("private var relayConfiguration", 1)[0]
        self.assertIn("guard settingsStore.settings.deviceServicesEnabled", binding)

    def test_connect_art_is_hidden_and_auto_connect_copy_matches_foreground_behavior(self):
        connect = source("HermesMobile/Features/Onboarding/ConnectHermesScreen.swift")
        art = connect.split("Text(Self.caduceus)", 1)[1].split("Text(\"Hermes iOS\")", 1)[0]
        self.assertIn(".accessibilityHidden(true)", art)
        settings = source("HermesMobile/Features/Settings/SettingsScreen.swift")
        self.assertIn('title: "Reconnect When Active"', settings)
        self.assertIn("foreground", settings.lower())

    def test_admin_launch_ui_tests_use_isolated_defaults_and_keychain(self):
        text = source("HermesMobileUITests/AdminLaunchUITests.swift")
        self.assertIn('UITEST_DEFAULTS_SUITE', text)
        self.assertIn('UITEST_KEYCHAIN_SERVICE', text)
        self.assertIn('UITEST_PAIRING_MODE', text)
        self.assertNotIn("let app = XCUIApplication()\n        app.launch()", text)

    def test_camera_usage_string_only_describes_reachable_camera_surfaces(self):
        info = plistlib.loads((ROOT / "HermesMobile/Resources/Info.plist").read_bytes())
        description = info["NSCameraUsageDescription"]
        self.assertNotIn("NSPhotoLibraryUsageDescription", info)
        self.assertIn("explicitly tap Save", info["NSPhotoLibraryAddUsageDescription"])
        self.assertIn("live voice", description.lower())
        self.assertIn("chat image attachment", description.lower())
        self.assertNotIn("documents", description.lower())
        project = source("project.yml")
        self.assertIn(description, project)

    def test_microphone_disclosure_matches_reachable_live_voice_transport(self):
        info = plistlib.loads((ROOT / "HermesMobile/Resources/Info.plist").read_bytes())
        description = info["NSMicrophoneUsageDescription"]
        self.assertIn("chat dictation", description.lower())
        self.assertIn("live voice", description.lower())
        self.assertIn("audio is sent", description.lower())
        self.assertIn(description, source("project.yml"))

    def test_notification_onboarding_persists_consent_and_live_voice_is_reachable(self):
        onboarding = source("HermesMobile/Features/Onboarding/PermissionsOnboardingScreen.swift")
        chat = source("HermesMobile/Features/Chat/ChatScreen.swift")
        entry = source("HermesMobile/AppEntry.swift")
        self.assertIn("await container.setNotificationsEnabled(enabled)", onboarding)
        self.assertIn('accessibilityLabel: "Start voice mode"', chat)
        self.assertIn("router.isVoiceOverlayPresented = true", chat)
        remote_callback = entry.split("didReceiveRemoteNotification", 1)[1].split("}\n}", 1)[0]
        self.assertNotIn("isCompanionRuntimeActive", remote_callback)

    def test_silent_push_has_production_entitlement_and_release_verification(self):
        entitlements = plistlib.loads((ROOT / "HermesMobile/HermesMobile.entitlements").read_bytes())
        self.assertEqual(entitlements["aps-environment"], "production")
        project = source("project.yml")
        self.assertIn("aps-environment: production", project)
        workflow = source(".github/workflows/testflight.yml")
        self.assertGreaterEqual(workflow.count("Print :aps-environment"), 2)


if __name__ == "__main__":
    unittest.main()
