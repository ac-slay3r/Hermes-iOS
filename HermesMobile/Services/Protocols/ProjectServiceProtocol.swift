import Foundation

@MainActor
protocol ProjectServiceProtocol {
    func listProjects() async throws -> [HostProject]
    func createProject(
        name: String,
        workspacePath: String,
        brief: String,
        pinnedCommandIds: [String]
    ) async throws -> HostProject
}
