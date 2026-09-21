import Foundation

@MainActor
@Observable
final class ProjectStore {
    enum SelectionError: LocalizedError {
        case conversationMustBeCleared

        var errorDescription: String? {
            switch self {
            case .conversationMustBeCleared:
                "Start a new conversation before changing projects."
            }
        }
    }

    private static let selectedProjectDefaultsKey = "hermes.projects.selectedProjectID"

    private let service: any ProjectServiceProtocol
    private let defaults: UserDefaults
    private var hostScopeID: UUID?

    private(set) var projects: [HostProject] = []
    private(set) var selectedProjectID: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(service: any ProjectServiceProtocol, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    var selectedProject: HostProject? {
        projects.first { $0.id == selectedProjectID }
    }

    func setHostScope(_ hostID: UUID?) {
        guard hostScopeID != hostID else { return }
        hostScopeID = hostID
        projects = []
        errorMessage = nil
        guard let selectionKey else {
            selectedProjectID = nil
            return
        }
        selectedProjectID = defaults.string(forKey: selectionKey)
    }

    func refresh() async {
        guard hostScopeID != nil else {
            projects = []
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            projects = try await service.listProjects()
            if let selectedProjectID, !projects.contains(where: { $0.id == selectedProjectID }) {
                persistSelection(nil)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func create(
        name: String,
        workspacePath: String,
        brief: String,
        pinnedCommandIds: [String]
    ) async throws -> HostProject {
        guard hostScopeID != nil else {
            throw RelayAPIClient.ClientError.requestFailed("Connect a Hermes host before creating a project.")
        }
        let project = try await service.createProject(
            name: name,
            workspacePath: workspacePath,
            brief: brief,
            pinnedCommandIds: pinnedCommandIds
        )
        projects.removeAll { $0.id == project.id }
        projects.append(project)
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return project
    }

    func select(_ project: HostProject, conversationIsEmpty: Bool) throws {
        guard conversationIsEmpty else { throw SelectionError.conversationMustBeCleared }
        persistSelection(project.id)
    }

    func alignSelection(with conversationProjectID: String?, conversationIsEmpty: Bool) {
        if conversationIsEmpty { return }
        persistSelection(conversationProjectID)
    }

    func pinnedCommands(from catalog: [SlashCommand]) -> [SlashCommand] {
        guard let selectedProject else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        return selectedProject.pinnedCommandIds.compactMap { byID[$0] }
    }

    private var selectionKey: String? {
        hostScopeID.map { "\(Self.selectedProjectDefaultsKey).\($0.uuidString.lowercased())" }
    }

    private func persistSelection(_ id: String?) {
        selectedProjectID = id
        guard let selectionKey else { return }
        if let id {
            defaults.set(id, forKey: selectionKey)
        } else {
            defaults.removeObject(forKey: selectionKey)
        }
    }
}
