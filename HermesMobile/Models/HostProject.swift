import Foundation

struct HostProject: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let workspacePath: String
    let brief: String
    let pinnedCommandIds: [String]
}
