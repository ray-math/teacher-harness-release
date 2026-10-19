"""Exercise the documented CLI in fresh processes using synthetic TEMP files."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent
DEPS = Path(os.environ.get('OFFICIAL_ODT_TEST_DEPS', SCRIPTS.parent / '.deps'))


class RuntimeTests(unittest.TestCase):
    def run_cli(self, *args, deps=DEPS):
        env = os.environ.copy()
        env.pop('PYTHONPATH', None)
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        return subprocess.run(
            [sys.executable, str(SCRIPTS / 'run_odt.py'), '--deps', str(deps), *args],
            capture_output=True, text=True, encoding='utf-8', env=env)

    def test_cli_missing_template_stops_before_reading_data_or_creating_output(self):
        with tempfile.TemporaryDirectory(prefix='odt-runtime-no-template-') as folder:
            output = Path(folder)/'draft.odt'
            result = self.run_cli('--data', str(Path(folder)/'missing.json'), '--form', 'general', '--output', str(output))
            self.assertEqual(result.returncode, 2, result.stderr)
            receipt = json.loads(result.stdout)
            self.assertEqual(receipt['status'], 'needs_input')
            self.assertIn('--template', receipt['message'])
            self.assertFalse(output.exists())

    def test_missing_dependencies_fail_before_creation(self):
        with tempfile.TemporaryDirectory(prefix='odt-runtime-missing-') as folder:
            root = Path(folder)
            output = root / 'draft.odt'
            result = self.run_cli('--data', str(root / 'unused.json'),
                                  '--output', str(output), deps=root / 'missing')
            self.assertEqual(result.returncode, 2)
            self.assertIn('Install once:', result.stderr)
            self.assertIn('odfpy==1.4.1', result.stderr)
            self.assertFalse(output.exists())

    def test_explicit_dependencies_are_used(self):
        result = self.run_cli('--runtime-check')
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(Path(receipt['dependency_directory']), DEPS.resolve())
        for module in receipt['modules'].values():
            self.assertTrue(Path(module).is_relative_to(DEPS.resolve()))

    def test_new_drafts_package_checks_and_overwrite_protection(self):
        with tempfile.TemporaryDirectory(prefix='odt-runtime-create-') as folder:
            root = Path(folder)
            data = root / 'draft.json'
            data.write_text(json.dumps({
                'title': '합성 검증', 'agency': '검증기관', 'recipient': '내부결재',
                'related': [], 'body': ['1. 합성 문서 생성 검사를 수행합니다.'],
                'attachments': [{'name': '합성 자료', 'quantity': '1부'}],
            }, ensure_ascii=False), encoding='utf-8')
            for form in ('general', 'internal'):
                with self.subTest(form=form):
                    output = root / f'{form}.odt'
                    command = ('--data', str(data), '--template', str(SCRIPTS.parent/'assets'/(form+'.odt')), '--output', str(output))
                    created = self.run_cli(*command)
                    self.assertEqual(created.returncode, 0, created.stderr)
                    self.assertFalse(json.loads(created.stdout)['rendering_checked'])
                    checked = self.run_cli('--check', str(output))
                    self.assertEqual(checked.returncode, 0, checked.stderr)
                    self.assertEqual(json.loads(checked.stdout)['package_check'], 'passed')
                    original = hashlib.sha256(output.read_bytes()).hexdigest()
                    repeated = self.run_cli(*command)
                    self.assertNotEqual(repeated.returncode, 0)
                    self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), original)


if __name__ == '__main__':
    unittest.main()
