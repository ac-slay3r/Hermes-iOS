import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text()


class ProjectCommandSourceTests(unittest.TestCase):
    def test_host_project_store_is_host_backed_and_selection_is_guarded(self):
        model = source("HermesMobile/Models/HostProject.swift")
        store = source("HermesMobile/Stores/ProjectStore.swift")
        service = source("HermesMobile/Services/Live/LiveProjectService.swift")
        self.assertIn("struct HostProject", model)
        self.assertIn("let workspacePath: String", model)
        self.assertIn("let pinnedCommandIds: [String]", model)
        self.assertIn("func select(_ project: HostProject, conversationIsEmpty: Bool) throws", store)
        self.assertIn("case conversationMustBeCleared", store)
        self.assertIn("selectedProjectDefaultsKey", store)
        self.assertIn('path: "projects"', service)

    def test_messages_carry_only_selected_project_identifier(self):
        client = source("HermesMobile/Services/Live/LiveHermesClient.swift")
        conversation = source("HermesMobile/Models/Conversation.swift")
        self.assertIn("let projectId: String?", client)
        self.assertIn("projectIdProvider", client)
        self.assertNotIn("workspacePathProvider", client)
        self.assertIn("var projectID: String?", conversation)

    def test_chat_exposes_project_picker_and_explicit_command_palette(self):
        chat = source("HermesMobile/Features/Chat/ChatScreen.swift")
        input_bar = source("HermesMobile/Features/Chat/ChatInputBar.swift")
        menu = source("HermesMobile/Features/Chat/SlashCommandMenu.swift")
        picker = source("HermesMobile/Features/Projects/ProjectPickerSheet.swift")
        self.assertIn("ProjectPickerSheet", chat)
        self.assertIn("accessibilityLabel: projectPickerAccessibilityLabel", chat)
        self.assertIn('.accessibilityValue(isSelected ? "Selected" : "Not selected")', picker)
        self.assertIn('accessibilityLabel("Browse commands")', input_bar)
        self.assertIn("pinnedCommandIDs", input_bar)
        self.assertIn('Text("Pinned")', menu)
        self.assertIn('Text("All Commands")', menu)
        self.assertIn("Create Project", picker)
        self.assertIn("Exact workspace path", picker)

    def test_project_change_requires_new_conversation(self):
        chat = source("HermesMobile/Features/Chat/ChatScreen.swift")
        self.assertIn("showProjectSwitchConfirmation", chat)
        self.assertIn("await performClear()", chat)
        self.assertIn("pendingProjectSelection", chat)


if __name__ == "__main__":
    unittest.main()
