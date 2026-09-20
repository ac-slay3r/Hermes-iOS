"""Source guardrails only: these do NOT compile or run Swift."""
import pathlib
import unittest
import re
import plistlib
from typing import Any


def parse_openstep(text: str) -> dict[str, Any]:
    """Small structural parser, not an Xcode/build validator."""
    tokens = re.findall(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', text, re.S)
    tokens = [t for t in tokens if not t.startswith(('/*', '//'))]
    index = 0
    def value():
        nonlocal index
        token = tokens[index]; index += 1
        if token == '{':
            result = {}
            while tokens[index] != '}':
                key = value()
                assert tokens[index] == '='; index += 1
                assert key not in result, f'duplicate key {key}'
                result[key] = value()
                assert tokens[index] == ';'; index += 1
            index += 1
            return result
        if token == '(':
            result = []
            while tokens[index] != ')':
                result.append(value())
                if tokens[index] == ',': index += 1
                else: assert tokens[index] == ')'
            index += 1
            return result
        return token[1:-1] if token.startswith('"') else token
    result = value()
    assert index == len(tokens)
    assert isinstance(result, dict)
    return result

ROOT = pathlib.Path(__file__).resolve().parents[2]

class LocalIntakeSources(unittest.TestCase):
    def test_durable_local_intake_contract(self):
        paths = ['SharedIntake/LocalIntakeQueue.swift', 'HermesMobile/LocalCapture/LocalIntakeImporter.swift']
        for path in paths:
            self.assertTrue((ROOT / path).exists(), f'Missing intake implementation: {path}')
        queue, importer = [(ROOT / p).read_text() for p in paths]
        for token in ['group.cool.n0thing.hermes', 'LocalIntake-v1', '.completeFileProtection', '.atomic', 'O_NOFOLLOW', 'maxTextBytes', 'maxURLBytes']:
            self.assertIn(token, queue)
        self.assertLess(importer.index('moveItem'), importer.index('queue.acknowledge'))
        self.assertIn('afterCommit()', importer)
        self.assertIn('.batch-intake-', importer)
        self.assertNotIn('importBackup(', importer)
        for token in ['URLSession', 'AppContainer', 'WKWebView', 'startAccessingSecurityScopedResource']:
            self.assertNotIn(token, queue + importer)

    def test_share_and_intents_are_explicit_and_registered(self):
        for path in ['HermesShareExtension/ShareViewController.swift', 'HermesMobile/LocalCapture/LocalCaptureIntents.swift']:
            self.assertTrue((ROOT / path).exists(), f'Missing explicit entry point: {path}')
        share = (ROOT / 'HermesShareExtension/ShareViewController.swift').read_text()
        intents = (ROOT / 'HermesMobile/LocalCapture/LocalCaptureIntents.swift').read_text()
        for token in ['Save to local inbox', 'Cancel', 'Preview', 'maxItems', 'UTType.url', 'UTType.plainText']:
            self.assertIn(token, share)
        for token in ['SaveLocalTextIntent', 'OpenLocalInboxIntent', 'requestConfirmation', 'authenticationPolicy', 'openAppWhenRun']:
            self.assertIn(token, intents)
        for token in ['URLSession', 'AppContainer', 'AVAudioRecorder', 'CLLocationManager', 'HKHealthStore', 'WKWebView']:
            self.assertNotIn(token, share + intents)
        for path in ['project.yml', 'HermesMobile.xcodeproj/project.pbxproj']:
            self.assertIn('HermesShareExtension', (ROOT / path).read_text())

    def test_project_structure_embeds_real_extension_and_shared_queue(self):
        objects = parse_openstep((ROOT / 'HermesMobile.xcodeproj/project.pbxproj').read_text())['objects']
        targets = {v['name']: (k, v) for k, v in objects.items() if v['isa'] == 'PBXNativeTarget'}
        share_id, share = targets['HermesShareExtension']
        _, app = targets['HermesMobile']
        self.assertEqual(share['productType'], 'com.apple.product-type.app-extension')
        self.assertTrue(any(objects[d]['target'] == share_id for d in app['dependencies']))
        copies = [objects[x] for x in app['buildPhases'] if objects[x]['isa'] == 'PBXCopyFilesBuildPhase']
        self.assertTrue(any(objects[f]['fileRef'] == share['productReference'] for phase in copies for f in phase['files']))
        def sources(target):
            return [objects[objects[f]['fileRef']]['path'] for phase in target['buildPhases']
                    if objects[phase]['isa'] == 'PBXSourcesBuildPhase' for f in objects[phase]['files']]
        self.assertCountEqual(sources(share), ['SharedIntake/LocalIntakeQueue.swift', 'HermesShareExtension/ShareViewController.swift'])
        self.assertIn('SharedIntake/LocalIntakeQueue.swift', sources(app))
        self.assertIn('HermesMobileTests/LocalIntakeTests.swift', sources(targets['HermesMobileTests'][1]))
        for config in objects[share['buildConfigurationList']]['buildConfigurations']:
            settings = objects[config]['buildSettings']
            self.assertEqual(settings['APPLICATION_EXTENSION_API_ONLY'], 'YES')
            self.assertEqual(settings['PRODUCT_BUNDLE_IDENTIFIER'], 'cool.n0thing.hermes.Share')
            self.assertEqual(settings['DEVELOPMENT_TEAM'], '')
        info = plistlib.loads((ROOT / 'HermesShareExtension/Info.plist').read_bytes())
        self.assertEqual(info['NSExtension']['NSExtensionPointIdentifier'], 'com.apple.share-services')
        rule = info['NSExtension']['NSExtensionAttributes']['NSExtensionActivationRule']
        self.assertEqual(rule, {'NSExtensionActivationSupportsText': True, 'NSExtensionActivationSupportsWebURLWithMaxCount': 1})
        for path in ['HermesMobile/HermesMobile.entitlements', 'HermesShareExtension/HermesShareExtension.entitlements']:
            entitlements = plistlib.loads((ROOT / path).read_bytes())
            self.assertEqual(entitlements['com.apple.security.application-groups'], ['group.cool.n0thing.hermes'])

if __name__ == '__main__': unittest.main()
