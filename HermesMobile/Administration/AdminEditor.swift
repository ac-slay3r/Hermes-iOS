import Foundation
import Observation

@MainActor
@Observable
final class AdminEditor {
    enum Phase: Equatable {
        case idle, loading, editing, review, applying, saved, conflict, unknown, rejected, failed
    }
    private(set) var target: AdminTarget
    private(set) var resource: AdminResource?
    private(set) var original: AdminSnapshot?
    var proposed = ""
    private(set) var phase: Phase = .idle
    private let client: HermesAdminClient
    private var generation = UUID()
    private var reviewed: String?
    /// Set by the caller so a 401/403/wrong-target failure routes back through the same
    /// re-sign-in path the read-only screens use, rather than a dead-end generic error.
    var onAuthorityLost: @MainActor () -> Void = {}

    init(client: HermesAdminClient, target: AdminTarget) {
        self.client = client
        self.target = target
    }

    func select(_ target: AdminTarget) {
        guard phase != .applying, phase != .unknown else { return }
        generation = UUID()
        self.target = target
        resource = nil
        original = nil
        proposed = ""
        reviewed = nil
        phase = .idle
    }

    func load(_ resource: AdminResource) async {
        guard phase != .applying, phase != .loading, phase != .unknown else { return }
        generation = UUID()
        let ticket = generation
        let target = target
        original = nil
        proposed = ""
        reviewed = nil
        self.resource = resource
        phase = .loading
        do {
            let snapshot = try await client.read(resource, target: target)
            guard ticket == generation else { return }
            original = snapshot
            proposed = snapshot.value
            phase = .editing
        } catch {
            guard ticket == generation else { return }
            if adminSignalsAuthorityLost(error) { onAuthorityLost() }
            phase = .failed
        }
    }

    func review() {
        guard phase == .editing, let original, proposed != original.value else { return }
        reviewed = proposed
        phase = .review
    }

    func revise() {
        guard phase == .review else { return }
        reviewed = nil
        phase = .editing
    }

    func apply() async {
        guard phase == .review, let resource, let original,
              let reviewed, reviewed == proposed else { return }
        let ticket = generation
        let target = target
        phase = .applying
        do {
            let current = try await client.read(resource, target: target)
            guard ticket == generation else { return }
            guard current == original else { phase = .conflict; return }
        } catch {
            guard ticket == generation else { return }
            if adminSignalsAuthorityLost(error) { onAuthorityLost() }
            phase = .failed // No write was attempted.
            return
        }
        // This is a best-effort preflight, NOT atomic compare-and-swap.
        do {
            try await client.write(resource, target: target, value: reviewed)
        } catch AdminError.rejected {
            guard ticket == generation else { return }
            phase = .rejected
            return
        } catch {
            guard ticket == generation else { return }
            phase = .unknown // A timeout/5xx may occur after persistence.
            return
        }
        guard ticket == generation else { return }
        phase = .unknown
        await verify()
    }

    /// Reconcile uncertain outcomes by GET only; never automatically repeat a write.
    func verify() async {
        guard phase == .unknown, let resource, let reviewed else { return }
        let ticket = generation
        let target = target
        phase = .applying
        do {
            let actual = try await client.read(resource, target: target)
            guard ticket == generation else { return }
            if actual.value == reviewed && actual.exists {
                original = actual
                phase = .saved
            } else {
                phase = .unknown
            }
        } catch {
            guard ticket == generation else { return }
            phase = .unknown
        }
    }
}
