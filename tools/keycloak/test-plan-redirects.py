import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('plan-redirects.py')
spec = importlib.util.spec_from_file_location('planner', SCRIPT)
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class PlannerTests(unittest.TestCase):
    def setUp(self):
        self.issuer = 'https://identity.example.com/auth/realms/preprod'
        self.export = {'realm': 'preprod', 'clients': [
            {'clientId': 'hawtio', 'redirectUris': ['https://legacy.example.com/*', '*'],
             'secret': 'MASKED', 'webOrigins': ['https://legacy.example.com'], 'publicClient': True},
            {'clientId': 'other', 'redirectUris': ['https://other.example.com/*']}]}
        self.inventory = {'clients': [{'issuerUrl': self.issuer, 'clientId': 'hawtio',
                                      'redirectUris': ['https://cell-b.example.com/console',
                                                       'https://cell-a.example.com/console']}]}

    def run_plan(self):
        return planner.plan(self.export, self.inventory, self.issuer, 'hawtio')

    def test_preserves_legacy_and_wildcard_without_exporting_unrelated_fields(self):
        original = copy.deepcopy(self.export)
        review, desired = self.run_plan()
        self.assertEqual(review['removed'], [])
        self.assertEqual(review['after'][:2], original['clients'][0]['redirectUris'])
        self.assertEqual(len(review['added']), 2)
        self.assertTrue(review['warnings'])
        self.assertEqual(set(desired), {'realm', 'clients'})
        self.assertEqual(set(desired['clients'][0]), {'clientId', 'redirectUris'})
        self.assertEqual(self.export, original)

    def test_idempotent_and_duplicate_inventory_urls(self):
        self.inventory['clients'][0]['redirectUris'] *= 2
        _, desired = self.run_plan()
        self.export['clients'][0]['redirectUris'] = desired['clients'][0]['redirectUris']
        review, _ = self.run_plan()
        self.assertFalse(review['changed'])
        self.assertEqual(review['added'], [])

    def test_reject_wrong_realm_missing_or_ambiguous_client(self):
        for change in ['realm', 'missing', 'duplicate']:
            with self.subTest(change=change):
                self.setUp()
                if change == 'realm':
                    self.export['realm'] = 'prod'
                elif change == 'missing':
                    self.export['clients'] = []
                else:
                    self.export['clients'] *= 2
                with self.assertRaises(ValueError):
                    self.run_plan()

    def test_reject_wrong_inventory_target(self):
        self.inventory['clients'][0]['issuerUrl'] = 'https://other.example.com/realms/preprod'
        with self.assertRaises(ValueError):
            self.run_plan()

    def test_reject_unsafe_input(self):
        for uri in ['*', 'http://cell.example.com/console', 'https://x.invalid/console',
                    'https://cell.example.com/console?x=1', 'https://user@cell.example.com/console']:
            with self.subTest(uri=uri):
                self.inventory['clients'][0]['redirectUris'] = [uri]
                with self.assertRaises(ValueError):
                    self.run_plan()
        self.setUp()
        self.export['clients'][0]['redirectUris'].append('$(env:SECRET)')
        with self.assertRaises(ValueError):
            self.run_plan()

    def test_cli_dry_run_and_separate_review_from_apply_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'export.json').write_text(json.dumps(self.export))
            (root / 'inventory.json').write_text(json.dumps(self.inventory))
            command = [sys.executable, str(SCRIPT), '--export', str(root / 'export.json'),
                       '--inventory', str(root / 'inventory.json'), '--issuer', self.issuer,
                       '--client-id', 'hawtio']
            dry = subprocess.run(command, capture_output=True, text=True, check=True)
            self.assertTrue(json.loads(dry.stdout)['changed'])
            self.assertEqual(len(list(root.iterdir())), 2)
            subprocess.run(command + ['--output-dir', str(root / 'plan')], check=True, capture_output=True)
            self.assertTrue((root / 'plan/review.json').exists())
            self.assertEqual([p.name for p in (root / 'plan/desired').iterdir()], ['hawtio-redirects.json'])
            retry = subprocess.run(command + ['--output-dir', str(root / 'plan')], capture_output=True)
            self.assertNotEqual(retry.returncode, 0)


if __name__ == '__main__':
    unittest.main()
