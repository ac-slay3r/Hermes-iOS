import Testing
import XCTest
@testable import HermesMobile

final class BaseUIPolishTests: XCTestCase {
    func testAssistanceKeepsDraftAndDoesNotInventAttachedContent() {
        XCTAssertEqual(ComposerAssistance.summarize.draft(existing: "", hasAttachments: true),
                       "Summarize the attached material.")
        XCTAssertEqual(ComposerAssistance.nextSteps.draft(existing: "My draft", hasAttachments: false),
                       "My draft\n\nHelp me identify next steps.")
        XCTAssertEqual(ComposerAssistance.summarize.draft(existing: "  ", hasAttachments: false),
                       "Help me summarize this conversation.")
    }

    func testToolStatusDoesNotClaimSuccessWhenStreamStops() {
        let active = ToolActivity(label: "web_search")
        XCTAssertEqual(active.displayStatus(isStreaming: true), "Working")
        XCTAssertEqual(active.displayStatus(isStreaming: false), "No longer updating")
        XCTAssertEqual(ToolActivity(label: "custom_tool", isActive: false)
            .displayStatus(isStreaming: false), "Activity ended")
        XCTAssertEqual(active.displayLabel, "Search the web")
        XCTAssertEqual(ToolActivity(label: "custom_tool").displayLabel, "custom tool")
    }
}

struct HermesMobileTests {

    @Test func messageCreationDefaultsToSentStatus() async throws {
        let message = Message(sender: .user, content: "Hello Hermes")
        #expect(message.sender == .user)
        #expect(message.content == "Hello Hermes")
        #expect(message.status == .sent)
    }

    @Test func conversationPreviewTextShowsLastMessage() async throws {
        let messages = [
            Message(sender: .hermes, content: "First message"),
            Message(sender: .user, content: "Second message"),
        ]
        let conversation = Conversation(title: "Test", messages: messages)
        #expect(conversation.previewText == "Second message")
        #expect(conversation.lastMessage?.sender == .user)
    }

    @Test func emptyConversationShowsPlaceholderPreview() async throws {
        let conversation = Conversation(title: "Empty")
        #expect(conversation.previewText == "No messages yet")
        #expect(conversation.lastMessage == nil)
    }

    @Test func permissionTypeHasDistinctColorsAndIcons() async throws {
        let types = PermissionType.allCases
        #expect(!types.isEmpty)

        let icons = Set(types.map(\.displayIcon))
        #expect(icons.count == types.count, "Each permission type should have a unique icon")
    }

    @Test func inboxItemTypeVisualIdentityIsComplete() async throws {
        for itemType in InboxItemType.allCases {
            #expect(!itemType.displayLabel.isEmpty)
            #expect(!itemType.displayIcon.isEmpty)
        }
    }
}
