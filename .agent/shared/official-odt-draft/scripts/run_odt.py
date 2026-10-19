"""Run the ODT generator with this skill's explicit, pinned dependencies."""
import argparse
import importlib
from importlib.metadata import distributions
import json
from pathlib import Path
import runpy
import sys
import unittest


SCRIPTS = Path(__file__).resolve().parent
DEFAULT_DEPS = SCRIPTS.parent / '.deps'


def activate_dependencies(deps):
    """Use only the requested package directory; never install at runtime."""
    deps = Path(deps).resolve()
    expected = dict(line.split('==') for line in
                    (SCRIPTS / 'requirements.txt').read_text().splitlines()
                    if line.strip() and not line.startswith('#'))
    installed = {dist.metadata['Name'].casefold(): dist.version
                 for dist in distributions(path=[str(deps)])}
    missing = [f'{name}=={version}' for name, version in expected.items()
               if installed.get(name.casefold()) != version]
    if missing:
        raise RuntimeError(
            'ODT dependencies missing or mismatched: ' + ', '.join(missing) + '\n'
            f'Install once: "{sys.executable}" -m pip install --target "{deps}" '
            f'-r "{SCRIPTS / "requirements.txt"}"')
    sys.path.insert(0, str(deps))
    sys.path.insert(0, str(SCRIPTS))
    paths = {}
    for name in ('odf.opendocument', 'PIL.ImageFont', 'defusedxml'):
        module = importlib.import_module(name)
        path = Path(module.__file__).resolve()
        if not path.is_relative_to(deps):
            raise RuntimeError(f'{name} was loaded outside the ODT dependency directory: {path}')
        paths[name] = str(path)
    return {'dependency_directory': str(deps), 'versions': expected, 'modules': paths}


def main(argv=None):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--deps', type=Path, default=DEFAULT_DEPS)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--runtime-check', action='store_true')
    modes.add_argument('--self-test', action='store_true')
    args, forwarded = parser.parse_known_args(argv)
    if forwarded[:1] == ['--']:
        forwarded = forwarded[1:]
    if (args.runtime_check or args.self_test) and forwarded:
        parser.error('Runtime checks do not accept generator arguments')
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    try:
        receipt = activate_dependencies(args.deps)
    except (ImportError, OSError, RuntimeError) as exc:
        parser.exit(2, f'{exc}\n')
    if args.runtime_check:
        print(json.dumps(receipt, ensure_ascii=False))
    elif args.self_test:
        # Tests receive the selected dependency directory through the receipt.
        import os
        os.environ['OFFICIAL_ODT_TEST_DEPS'] = receipt['dependency_directory']
        suite = unittest.defaultTestLoader.discover(str(SCRIPTS), pattern='test_*.py')
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() else 1
    else:
        sys.argv = [str(SCRIPTS / 'draft_odt.py'), *forwarded]
        runpy.run_path(sys.argv[0], run_name='__main__')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
