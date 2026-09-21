import Foundation

@MainActor
final class LiveProjectService: ProjectServiceProtocol {
    private struct ProjectListResponse: Decodable {
        let projects: [HostProject]
    }

    private struct ProjectCreateResponse: Decodable {
        let project: HostProject
    }

    private struct ProjectCreateBody: Encodable {
        let name: String
        let workspacePath: String
        let brief: String
        let pinnedCommandIds: [String]
    }

    private let apiClient: RelayAPIClient
    private let accessTokenProvider: @MainActor () async -> String?
    private let accessTokenRefresher: @MainActor () async -> String?

    init(
        apiClient: RelayAPIClient,
        accessTokenProvider: @escaping @MainActor () async -> String?,
        accessTokenRefresher: @escaping @MainActor () async -> String? = { nil }
    ) {
        self.apiClient = apiClient
        self.accessTokenProvider = accessTokenProvider
        self.accessTokenRefresher = accessTokenRefresher
    }

    func listProjects() async throws -> [HostProject] {
        let response: ProjectListResponse = try await authorized { token in
            try await self.apiClient.get(path: "projects", accessToken: token)
        }
        return response.projects
    }

    func createProject(
        name: String,
        workspacePath: String,
        brief: String,
        pinnedCommandIds: [String]
    ) async throws -> HostProject {
        let body = ProjectCreateBody(
            name: name,
            workspacePath: workspacePath,
            brief: brief,
            pinnedCommandIds: pinnedCommandIds
        )
        let response: ProjectCreateResponse = try await authorized { token in
            try await self.apiClient.post(path: "projects", body: body, accessToken: token)
        }
        return response.project
    }

    private func authorized<T>(
        _ operation: @escaping @MainActor (String?) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(await accessTokenProvider())
        } catch RelayAPIClient.ClientError.unauthorized {
            guard let token = await accessTokenRefresher(), !token.isEmpty else {
                throw RelayAPIClient.ClientError.unauthorized("Expired or invalid access token.")
            }
            return try await operation(token)
        }
    }
}
