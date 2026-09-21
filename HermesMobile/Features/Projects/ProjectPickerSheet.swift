import SwiftUI

struct ProjectPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let projectStore: ProjectStore
    let commandCatalog: [SlashCommand]
    let onSelect: (HostProject) -> Void

    @State private var showsCreateForm = false

    var body: some View {
        NavigationStack {
            Group {
                if projectStore.isLoading && projectStore.projects.isEmpty {
                    ProgressView("Loading projects…")
                } else if let errorMessage = projectStore.errorMessage, projectStore.projects.isEmpty {
                    ContentUnavailableView {
                        Label("Projects Unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await projectStore.refresh() } }
                    }
                } else if projectStore.projects.isEmpty {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "folder.badge.plus",
                        description: Text("Create a host-backed project to bind Chat to an exact workspace and useful commands.")
                    )
                } else {
                    List {
                        if let errorMessage = projectStore.errorMessage {
                            Section {
                                Label(errorMessage, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Button("Retry") { Task { await projectStore.refresh() } }
                            } header: {
                                Text("Showing last known projects")
                            }
                        }
                        ForEach(projectStore.projects) { project in
                            Button {
                                onSelect(project)
                                dismiss()
                            } label: {
                                HStack(spacing: Design.Spacing.sm) {
                                    Image(systemName: project.id == projectStore.selectedProjectID ? "checkmark.circle.fill" : "folder")
                                        .foregroundStyle(project.id == projectStore.selectedProjectID ? Design.Brand.accent : Design.Colors.secondaryForeground)
                                    VStack(alignment: .leading, spacing: Design.Spacing.xxxs) {
                                        Text(project.name)
                                            .foregroundStyle(Design.Colors.foreground)
                                        Text(project.workspacePath)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(Design.Colors.secondaryForeground)
                                            .lineLimit(1)
                                        if !project.brief.isEmpty {
                                            Text(project.brief)
                                                .font(Design.Typography.caption)
                                                .foregroundStyle(Design.Colors.secondaryForeground)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsCreateForm = true
                    } label: {
                        Label("Create Project", systemImage: "plus")
                    }
                }
            }
            .refreshable { await projectStore.refresh() }
            .sheet(isPresented: $showsCreateForm) {
                ProjectCreateSheet(
                    projectStore: projectStore,
                    commandCatalog: commandCatalog
                ) { project in
                    onSelect(project)
                    dismiss()
                }
            }
            .task { await projectStore.refresh() }
        }
    }
}

private struct ProjectCreateSheet: View {
    @Environment(\.dismiss) private var dismiss

    let projectStore: ProjectStore
    let commandCatalog: [SlashCommand]
    let onCreated: (HostProject) -> Void

    @State private var name = ""
    @State private var workspacePath = ""
    @State private var brief = ""
    @State private var pinnedCommandIDs = Set<String>()
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var availableCommands: [SlashCommand] {
        commandCatalog
            .filter { $0.suggestedArgument == nil }
            .sorted {
                if $0.category == $1.category { return $0.displayTitle < $1.displayTitle }
                return $0.category < $1.category
            }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Exact workspace path", text: $workspacePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("Brief and desired outcome", text: $brief, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("The paired host validates and canonicalizes this directory. Hermes runs project-scoped work from that exact location.")
                }

                Section("Pinned commands") {
                    ForEach(availableCommands) { command in
                        Toggle(isOn: pinBinding(command.id)) {
                            VStack(alignment: .leading, spacing: Design.Spacing.xxxs) {
                                Text(command.displayTitle)
                                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                                Text(command.description)
                                    .font(Design.Typography.caption)
                                    .foregroundStyle(Design.Colors.secondaryForeground)
                            }
                        }
                    }
                } footer: {
                    Text("Pins organize the command palette. They do not bypass Hermes approvals or command authorization.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Project") {
                        Task { await createProject() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || isSaving)
                }
            }
        }
    }

    private func pinBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { pinnedCommandIDs.contains(id) },
            set: { enabled in
                if enabled { pinnedCommandIDs.insert(id) }
                else { pinnedCommandIDs.remove(id) }
            }
        )
    }

    private func createProject() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let project = try await projectStore.create(
                name: name,
                workspacePath: workspacePath,
                brief: brief,
                pinnedCommandIds: availableCommands.map(\.id).filter(pinnedCommandIDs.contains)
            )
            onCreated(project)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
