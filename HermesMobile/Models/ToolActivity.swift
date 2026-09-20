import Foundation

/// A single tool invocation event captured during streaming.
///
/// Tool activities are accumulated on the ``Message`` during streaming so the UI
/// can show a compact, expandable timeline of what Hermes did.
struct ToolActivity: Identifiable, Hashable, Sendable {
    let id: UUID
    let label: String
    let startedAt: Date
    var isActive: Bool

    /// The stream reports activity, not verified tool success or failure.
    func displayStatus(isStreaming: Bool) -> String {
        if !isActive { return "Activity ended" }
        return isStreaming ? "Working" : "No longer updating"
    }

    var displayLabel: String {
        switch label {
        case "web_search": "Search the web"
        case "web_extract": "Read a web page"
        case "read_file": "Read a file"
        default: label.replacingOccurrences(of: "_", with: " ")
        }
    }

    init(
        id: UUID = UUID(),
        label: String,
        startedAt: Date = .now,
        isActive: Bool = true
    ) {
        self.id = id
        self.label = label
        self.startedAt = startedAt
        self.isActive = isActive
    }
}
