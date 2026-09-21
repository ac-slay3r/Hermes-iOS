import Foundation

@MainActor
final class MockProjectService: ProjectServiceProtocol {
    private var projects: [HostProject]

    init(projects: [HostProject] = []) {
        self.projects = projects
    }

    func listProjects() async throws -> [HostProject] {
        projects
    }

    func createProject(
        name: String,
        workspacePath: String,
        brief: String,
        pinnedCommandIds: [String]
    ) async throws -> HostProject {
        let project = HostProject(
            id: UUID(),
            name: name,
            workspacePath: workspacePath,
            brief: brief,
            pinnedCommandIds: pinnedCommandIds
        )
        projects.append(project)
        return project
    }
}
