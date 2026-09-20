"""Source guardrails only; these do not compile or execute Swift UI."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
def source(path):
    return (ROOT / path).read_text()

class BaseUIPolishSourceTests(unittest.TestCase):
    def test_composer_drafts_and_unavailable_voice(self):
        text = source("HermesMobile/Features/Chat/ChatInputBar.swift")
        self.assertIn("enum ComposerAssistance", text)
        self.assertIn("action.draft(existing: text", text)
        self.assertIn('Live conversation — unavailable', text)
        self.assertIn('Take notes — unavailable here', text)
        self.assertNotIn('router.isVoiceOverlayPresented = true', text)
        self.assertIn('Dictate text', text)
        self.assertIn('Interrupt response', text)

    def test_truthful_tool_status_and_accessible_details(self):
        model = source("HermesMobile/Models/ToolActivity.swift")
        rail = source("HermesMobile/Features/Chat/ToolActivityRail.swift")
        self.assertIn('No longer updating', model)
        self.assertIn('Activity ended', model)
        self.assertNotIn('checkmark.circle.fill', rail)
        self.assertNotIn('guard activities.count > 1', rail)
        self.assertIn('displayStatus(isStreaming:', rail)
        self.assertIn('Show tool activity details', rail)

    def test_preview_has_no_services_and_combined_launch_is_explicit(self):
        entry = source("HermesMobile/AppEntry.swift")
        self.assertIn('CombinedAppRoot()', entry)
        self.assertIn('guard container.isCompanionRuntimeActive else { return }', entry)
        self.assertNotIn('.task { await container.initialize() }', entry)
        composer = source("HermesMobile/Features/Chat/ChatInputBar.swift")
        self.assertIn('struct ChatComposerLab: View {', composer)
        self.assertLess(composer.index('struct ChatComposerLab: View {'), composer.index('#if DEBUG'))
        preview = composer.split('struct ChatComposerLab: View {')[-1]
        self.assertIn('allowsDictation: false', preview)
        for forbidden in ['AppContainer', 'LiveVoiceSessionService', '.startSession', 'ChatStore(', 'URLSession']:
            self.assertNotIn(forbidden, preview)

    def test_approval_label_matches_action(self):
        row = source("HermesMobile/Features/Inbox/InboxItemRow.swift")
        self.assertIn('Review details before approving', row)
        self.assertIn(r'item.secondaryAction?.title ?? "Dismiss") \(item.title)', row)

if __name__ == '__main__':
    unittest.main()
