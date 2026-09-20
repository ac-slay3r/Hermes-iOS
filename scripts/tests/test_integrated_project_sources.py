"""Project structure checks only; does not compile Swift or extract App Intents."""
from pathlib import Path
import plistlib
import unittest
import xml.etree.ElementTree as ET
from test_local_intake_sources import parse_openstep

ROOT = Path(__file__).resolve().parents[2]


class IntegratedProjectTests(unittest.TestCase):
    def test_shared_scheme_references_real_native_test_targets(self):
        project = parse_openstep((ROOT / 'HermesMobile.xcodeproj/project.pbxproj').read_text())
        objects = project['objects']
        scheme = ET.parse(ROOT / 'HermesMobile.xcodeproj/xcshareddata/xcschemes/HermesMobile.xcscheme')
        for ref in scheme.findall('.//BuildableReference'):
            identifier = ref.attrib['BlueprintIdentifier']
            self.assertTrue(identifier in objects, f"Missing scheme target {ref.attrib['BlueprintName']}: {identifier}")
            self.assertEqual(objects[identifier]['name'], ref.attrib['BlueprintName'])
        self.assertEqual({ref.attrib['BlueprintName'] for ref in scheme.findall('.//Testables//BuildableReference')},
                         {'HermesMobileTests', 'HermesMobileUITests'})

    def test_all_swift_sources_belong_to_exact_native_targets(self):
        project = parse_openstep((ROOT / 'HermesMobile.xcodeproj/project.pbxproj').read_text())
        objects = project['objects']
        paths = {}

        def visit(identifier, parent=Path()):
            item = objects[identifier]
            base = Path() if item.get('sourceTree') == 'SOURCE_ROOT' else parent
            path = base / item.get('path', '')
            if item['isa'] == 'PBXGroup':
                for child in item.get('children', []):
                    visit(child, path)
            else:
                paths[identifier] = path

        visit(objects[project['rootObject']]['mainGroup'])
        for item in objects.values():
            if item['isa'] != 'PBXNativeTarget':
                continue
            name = item['name']
            actual = []
            for phase in item['buildPhases']:
                if objects[phase]['isa'] == 'PBXSourcesBuildPhase':
                    for f in objects[phase]['files']:
                        ref = objects[f]['fileRef']
                        self.assertIn(ref, paths, f"{name}: source missing from project groups: {objects[ref].get('path')}")
                        actual.append(str(paths[ref]))
            expected = [str(p.relative_to(ROOT)) for p in (ROOT / name).rglob('*.swift')]
            if name in ('HermesMobile', 'HermesShareExtension'):
                expected += [str(p.relative_to(ROOT)) for p in (ROOT / 'SharedIntake').glob('*.swift')]
            self.assertCountEqual(actual, expected, name)

    def test_permissions_and_build_versions_match_generator(self):
        specification = (ROOT / 'project.yml').read_text()
        info = plistlib.loads((ROOT / 'HermesMobile/Resources/Info.plist').read_bytes())
        for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSSpeechRecognitionUsageDescription'):
            self.assertIn(f'{key}: "{info[key]}"', specification)
        for path in ('HermesMobile/Resources/Info.plist', 'HermesMobileWidgets/Info.plist', 'HermesShareExtension/Info.plist'):
            self.assertEqual(plistlib.loads((ROOT / path).read_bytes())['CFBundleVersion'], '$(CURRENT_PROJECT_VERSION)')
        self.assertIn('- target: HermesShareExtension', specification)
        share = specification.split('  HermesShareExtension:\n', 1)[1].split('  HermesMobileTests:\n', 1)[0]
        for token in ('DEVELOPMENT_TEAM: VYJS7JMXU5', 'CODE_SIGN_STYLE: Manual',
                      'CODE_SIGN_IDENTITY: Apple Distribution',
                      'PROVISIONING_PROFILE_SPECIFIER: cool.n0thing.hermes.Share'):
            self.assertIn(token, share)


if __name__ == '__main__':
    unittest.main()
