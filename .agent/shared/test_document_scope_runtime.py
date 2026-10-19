"""Synthetic scope-denial tests; never activate Hancom or read school documents."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class NativeRenderScopeTest(unittest.TestCase):
    def assert_denied_before_native_work(self, runner):
        root = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(prefix='document-scope-native-') as fixture:
            job = Path(fixture) / '.ai/jobs/synthetic'
            job.mkdir(parents=True)
            (job / 'inputs.json').write_text('{}', encoding='utf-8')
            manifest = job / 'native-plan.json'
            manifest.write_text(json.dumps(dict(renderPdf=True, inputs=[], output=str(job / 'wip/result.hwpx'))), encoding='utf-8')
            result = subprocess.run([sys.executable, '-B', str(root / 'hancom-native' / runner), str(manifest)],
                                    capture_output=True, encoding='utf-8', errors='replace',
                                    creationflags=subprocess.CREATE_NO_WINDOW, timeout=30)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Document scope denied before execution', result.stderr)
            self.assertFalse((job / 'wip').exists())

    def test_launcher_denies_before_cache_or_worker(self):
        self.assert_denied_before_native_work('run_merge.py')

    def test_worker_denies_before_com(self):
        self.assert_denied_before_native_work('merge_worker.py')


if __name__ == '__main__':
    unittest.main()
