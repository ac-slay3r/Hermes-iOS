"""Static guardrails only. They do not compile or execute Swift or measure RAM."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
def source(name):
    return (ROOT / 'HermesMobile/LocalCapture' / name).read_text()

class LocalCaptureBackupSources(unittest.TestCase):
    def test_streamed_export_never_collects_media_or_file_document(self):
        backup = source('LocalCaptureBackup.swift')
        store = source('LocalCaptureStore.swift')
        view = source('LocalCaptureStorageView.swift')
        self.assertIn('enum LocalCaptureArchive', backup)
        for token in ['HLCB0002', 'chunkBytes = 64 * 1024', 'maxManifestBytes = 8 * 1024 * 1024',
                      'maxPayloadBytes = 256 * 1024 * 1024', 'FileHandle', 'SHA256()', 'hasher.update(data:', 'O_NOFOLLOW']:
            self.assertIn(token, backup)
        self.assertNotIn('func exportBackup()', store)
        self.assertIn('func backupSources()', store)
        self.assertNotIn('FileDocument', backup + view)
        self.assertNotIn('FileWrapper', backup + view)
        self.assertIn('UIDocumentPickerViewController(forExporting:', view)
        self.assertIn('asCopy: true', view)

    def test_import_is_staged_validated_and_atomic(self):
        backup = source('LocalCaptureBackup.swift')
        store = source('LocalCaptureStore.swift')
        for token in ['readExactly', 'requireEOF', 'checksum', 'validateManifest', 'checkCancellation()',
                      'maxLegacyDocumentBytes = 8 * 1024 * 1024', '.backup-import-', '.backup-export-',
                      'volumeAvailableCapacityForImportantUsage', 'isExcludedFromBackup = true', 'synchronize()',
                      'cleanupAbandoned', 'isSymbolicLink', 'maxJSONDepth']:
            self.assertIn(token, backup)
        transaction = store.split('func importPrepared', 1)[1].split('func storageBytes', 1)[0]
        self.assertLess(transaction.index('try beforeCommit()'), transaction.index('try fm.moveItem'))
        self.assertLess(transaction.index('try fm.moveItem'), transaction.index('captures ='))
        self.assertNotIn('replaceItem', transaction)
        self.assertIn('LocalCaptureArchive.cleanupAbandoned', store)

    def test_heavy_work_is_detached_scoped_and_cancellable(self):
        view = source('LocalCaptureStorageView.swift')
        for token in ['Task.detached', 'startAccessingSecurityScopedResource', 'stopAccessingSecurityScopedResource',
                      'NSFileCoordinator', 'confirmationDialog', 'Import copies', 'Cancel backup operation',
                      '.onDisappear', 'On My iPhone', 'iCloud', 'independent', 'uninstall']:
            self.assertIn(token, view)
        self.assertIn('LocalCaptureArchive.capacityDisclosure', view)

    def test_file_url_directory_comparisons_ignore_trailing_slashes(self):
        backup = source('LocalCaptureBackup.swift')
        store = source('LocalCaptureStore.swift')
        self.assertIn('func samePath(', backup)
        self.assertIn('standardizedFileURL.path', backup)
        self.assertNotIn('parent == root', backup)
        self.assertIn('samePath(stage.deletingLastPathComponent(), root)', store)

    def test_temporary_destruction_and_startup_cleanup_are_off_main(self):
        backup = source('LocalCaptureBackup.swift')
        self.assertIn('enum LocalBackupCleanup', backup)
        self.assertIn('qos: .utility', backup)
        self.assertIn('deinit { LocalBackupCleanup.remove', backup)
        self.assertIn('LocalBackupCleanup.remove(url)', backup)

    def test_native_cases_and_honest_documentation(self):
        tests = (ROOT / 'HermesMobileTests/LocalCaptureBackupTests.swift').read_text()
        for token in ['testEmpty', 'testRoundTrip', 'testMalformed', 'testTruncated', 'testChecksum',
                      'testCancellation', 'testRollback', 'testLimits', 'testSymlink', 'testLegacy']:
            self.assertIn(token, tests)
        doc = (ROOT / 'docs/BACKUP_CAPACITY.md').read_text()
        for token in ['HLCB0002', '268435456', 'Xcode', 'not executed', '64 KiB', '8 MiB', 'reserve']:
            self.assertIn(token, doc)

if __name__ == '__main__':
    unittest.main()
