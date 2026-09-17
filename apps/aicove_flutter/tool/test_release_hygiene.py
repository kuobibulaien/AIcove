import re
from pathlib import Path
from urllib.parse import urlparse
import unittest

APP_ROOT = Path(__file__).resolve().parent.parent


class ReleaseHygieneTest(unittest.TestCase):
    def asset_entries(self):
        lines = (APP_ROOT / 'pubspec.yaml').read_text().splitlines()
        entries = []
        in_assets = False
        for line in lines:
            if re.match(r'^\s+assets:\s*$', line):
                in_assets = True
                continue
            if in_assets:
                m = re.match(r'^\s+-\s+(\S+)\s*$', line)
                if m:
                    entries.append(m.group(1))
                elif line.strip() and not line.startswith('    '):
                    break
        return entries

    def dart_string_const(self, name):
        text = (APP_ROOT / 'lib/src/core/config.dart').read_text()
        m = re.search(r"const String %s = '([^']+)';" % name, text)
        self.assertIsNotNone(m, f'{name} not found in config.dart')
        return m.group(1)

    def test_pubspec_assets_do_not_glob_root_assets_dir(self):
        entries = self.asset_entries()
        self.assertIn('assets/agent_context_defaults.json', entries)
        self.assertIn('assets/prompt_defaults.json', entries)
        self.assertNotIn('assets/', entries,
                         'root assets/ entry would bundle local_keys.json automatically')
        for entry in entries:
            self.assertNotIn('local_keys', entry)

    def test_default_api_urls_resolve_to_localhost(self):
        for name in ('_defaultApiUrl', '_localApiUrl', '_lanApiUrl'):
            host = urlparse(self.dart_string_const(name)).hostname
            self.assertEqual(host, 'localhost', f'{name} host is {host}')


if __name__ == '__main__':
    unittest.main()
