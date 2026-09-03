import Foundation

enum AdminCockpitDeviceState: Equatable {
    case current
    case stale
    case unavailable
}

struct AdminCockpitStatus: Decodable {
    struct Relay: Decodable {
        let status: String
    }

    struct Host: Decodable {
        let status: String
        let lastSeenAt: Date?
    }

    struct Device: Decodable, Identifiable {
        let id: UUID
        let name: String
        let platform: String
        let status: String
        let lastSeenAt: Date?
    }

    let relay: Relay
    let host: Host
    let devices: [Device]
}

struct AdminCockpitAuditEvent: Decodable, Identifiable {
    let id: UUID
    let actorType: String
    let action: String
    let entityType: String
    let entityId: String?
    let occurredAt: Date
}

struct AdminCockpitAuditResponse: Decodable {
    let events: [AdminCockpitAuditEvent]
}

enum AdminCockpitPresentation {
    private static let staleAfter: TimeInterval = 10 * 60

    static func freshness(_ lastSeenAt: Date?, now: Date = .now) -> String {
        guard let lastSeenAt else { return "Last seen unavailable" }
        let elapsed = max(0, now.timeIntervalSince(lastSeenAt))
        if elapsed < 60 { return "Last seen just now" }
        if elapsed < 60 * 60 { return "Last seen \(Int(elapsed / 60))m ago" }
        if elapsed < 24 * 60 * 60 { return "Last seen \(Int(elapsed / 3600))h ago" }
        return "Last seen \(Int(elapsed / 86400))d ago"
    }

    static func relayFreshness(_ refreshedAt: Date?, now: Date = .now) -> String {
        guard let refreshedAt else { return "Last checked unavailable" }
        let elapsed = max(0, now.timeIntervalSince(refreshedAt))
        if elapsed < 60 { return "Last checked just now" }
        if elapsed < 60 * 60 { return "Last checked \(Int(elapsed / 60))m ago" }
        if elapsed < 24 * 60 * 60 { return "Last checked \(Int(elapsed / 3600))h ago" }
        return "Last checked \(Int(elapsed / 86400))d ago"
    }

    static func deviceState(status: String, lastSeenAt: Date?, now: Date = .now) -> AdminCockpitDeviceState {
        let normalized = status.lowercased()
        if ["inactive", "unavailable", "offline", "unreachable", "revoked"].contains(normalized) || lastSeenAt == nil {
            return .unavailable
        }
        if let lastSeenAt, now.timeIntervalSince(lastSeenAt) >= staleAfter {
            return .stale
        }
        return .current
    }

    static func recoveryGuidance(relayStatus: String, hostStatus: String) -> String? {
        if relayStatus.lowercased() != "ok" {
            return "The relay cannot be reached. Check your network and relay address, then refresh."
        }

        switch hostStatus.lowercased() {
        case "offline":
            return "The Hermes Host is offline. Make sure it is running and connected to this relay, then refresh."
        case "unreachable":
            return "The Hermes Host cannot be reached. Check that it is online and connected to this relay, then refresh."
        case "not_connected":
            return "No Hermes Host is connected. Complete host connection in Settings to make it available."
        default:
            return nil
        }
    }

    static func title(for status: String) -> String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
