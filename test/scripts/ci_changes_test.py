"""Regression coverage for skipped jobs, native inputs, and shallow diffs."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import ci_changes as changes


class ClassificationTest(unittest.TestCase):
    def assert_platforms(self, paths, platforms):
        result = changes.classify(paths)
        self.assertEqual({p for p in changes.PLATFORMS if result[p]}, set(platforms))
        return result

    def test_documentation_is_a_noop(self):
        self.assertFalse(any(changes.classify(['README.md', 'docs/setup.md']).values()))

    def test_dart_changes_keep_analyzer_and_tests_without_native_builds(self):
        for path in ['lib/main.dart', 'test/widget/example_test.dart', 'analysis_options.yaml']:
            with self.subTest(path=path):
                result = self.assert_platforms([path], [])
                self.assertTrue(result['run_check'])

    def test_release_and_workflow_tooling_do_not_require_flutter(self):
        for path in [
            '.github/workflows/security.yml', '.github/actions/deployment-status/action.yml',
            '.github/dependabot.yml', 'scripts/validate_app_store_metadata.py',
            'scripts/generate_store_screenshots.py', 'test/scripts/preview_release_notes_test.rb',
            'Gemfile.lock', 'ios/fastlane/Fastfile',
            'ios/fastlane/metadata-production/en-US/description.txt',
            'android/fastlane/metadata-private/android/en-US/title.txt',
        ]:
            with self.subTest(path=path):
                result = self.assert_platforms([path], [])
                self.assertTrue(result['tooling'])
                self.assertFalse(result['run_check'])

    def test_each_native_platform_is_checked_in_isolation(self):
        for platform in changes.PLATFORMS:
            with self.subTest(platform=platform):
                result = self.assert_platforms([f'{platform}/native/source'], [platform])
                self.assertTrue(result['run_check'])

    def test_shared_dependencies_assets_and_ci_changes_build_every_platform(self):
        for path in [
            'pubspec.yaml', 'pubspec.lock', 'assets/version_codenames.json',
            '.github/workflows/ci.yml', 'scripts/ci_changes.py',
            'scripts/cache_sqlite3_native_assets.sh',
            'third_party/permission_handler_apple/ios/Package.swift',
            'third_party/in_app_purchase_android/android/build.gradle',
        ]:
            with self.subTest(path=path):
                result = self.assert_platforms([path], changes.PLATFORMS)
                self.assertTrue(result['run_check'])

    def test_helper_inputs_also_run_go_tests(self):
        for path in [*changes.PAYLOAD_SCRIPTS, 'remote/monkeymux/go.mod',
                     'remote/monkeymux/conpty/ConPTY.dll', 'remote/monkeymux/main.go']:
            with self.subTest(path=path):
                result = self.assert_platforms([path], changes.PLATFORMS)
                self.assertTrue(result['go'])

    def test_vendored_terminal_inputs_keep_test_coverage(self):
        for path in ['third_party/xterm/pubspec.yaml', 'third_party/xterm/pubspec.lock',
                     'third_party/xterm/lib/src/terminal.dart']:
            self.assertTrue(changes.classify([path])['run_check'])


class GitDiffTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.git('init', '-q')
        self.git('config', 'user.email', 'ci-test@example.invalid')
        self.git('config', 'user.name', 'CI test')
        self.write('android/old.cpp', 'old source')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def write(self, path, text):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)

    def classify(self, event='pull_request', base=None):
        output = self.root / 'output'
        output.write_text('')
        env = {
            **os.environ, 'EVENT_NAME': event,
            'PR_BASE_SHA': base or self.base, 'MG_BASE_SHA': base or self.base,
            'PUSH_BEFORE_SHA': base or self.base, 'HEAD_SHA': self.git('rev-parse', 'HEAD'),
            'GITHUB_OUTPUT': str(output),
        }
        subprocess.run([sys.executable, str(ROOT / 'scripts/ci_changes.py')],
                       cwd=self.root, env=env, check=True, capture_output=True)
        return dict(line.split('=') for line in output.read_text().splitlines())

    def test_pr_push_and_merge_group_diff_include_both_sides_of_a_rename(self):
        (self.root / 'docs').mkdir()
        self.git('mv', 'android/old.cpp', 'docs/old.cpp')
        self.git('commit', '-qm', 'move')
        for event in ['pull_request', 'merge_group', 'push']:
            with self.subTest(event=event):
                result = self.classify(event)
                self.assertEqual(result['android'], 'true')
                self.assertEqual(result['ios'], 'false')

    def test_nul_separation_prevents_newlines_in_names_from_inventing_paths(self):
        self.write('docs/newline\nlib/fake.dart', 'documentation')
        self.git('add', '.')
        self.git('commit', '-qm', 'newline')
        # It is a .dart path, so analysis is conservative, but it must not
        # invent a native path from the newline inside a single filename.
        result = self.classify()
        self.assertEqual(result['android'], 'false')
        self.assertEqual(result['go'], 'false')

    def test_missing_shallow_base_and_first_push_fail_open(self):
        for base in ['0' * 40, 'f' * 40]:
            self.assertEqual(set(self.classify('push', base).values()), {'true'})

    def test_empty_diff_skips_every_job(self):
        self.assertEqual(set(self.classify().values()), {'false'})


class WorkflowContractsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = "require 'yaml'; require 'json'; puts JSON.generate(ARGV.to_h { |f| [File.basename(f), YAML.load_file(f)] })"
        cls.workflows = json.loads(subprocess.check_output(
            ['ruby', '-e', script, *map(str, (ROOT / '.github/workflows').glob('*.yml'))],
            text=True,
        ))

    def test_mobile_triggers_share_all_compile_and_packaging_inputs(self):
        for file, event in [('preview.yml', 'pull_request'), ('deploy-private.yml', 'push'),
                            ('preview-ios.yml', 'pull_request')]:
            with self.subTest(file=file):
                workflow = self.workflows[file]
                triggers = workflow.get('on', workflow.get('true'))
                self.assertEqual(triggers[event]['paths'], changes.MOBILE_PATHS)
                self.assertNotIn('**.dart', triggers[event]['paths'])
                self.assertIn('remote/monkeymux/**', triggers[event]['paths'])
                self.assertIn('third_party/**', triggers[event]['paths'])

    def test_gate_waits_for_independent_tooling_and_terminal_checks(self):
        jobs = self.workflows['ci.yml']['jobs']
        self.assertIn('tooling', jobs['ci']['needs'])
        self.assertIn('terminal-test', jobs['ci']['needs'])
        self.assertEqual(jobs['tooling']['needs'], 'changes')
        self.assertNotIn('monkeymux-assets', jobs['terminal-test']['needs'])

    def test_payload_cache_can_only_be_saved_by_push_to_main_ci(self):
        for filename, workflow in self.workflows.items():
            for job in workflow['jobs'].values():
                for step in job.get('steps', []):
                    if step.get('with', {}).get('path') != 'assets/monkeymux/':
                        continue
                    uses = step.get('uses', '')
                    if uses.startswith('actions/cache/save@'):
                        self.assertEqual(filename, 'ci.yml')
                        self.assertIn("github.event_name == 'push'", step['if'])
                        self.assertIn("github.ref == 'refs/heads/main'", step['if'])
                    self.assertFalse(uses.startswith('actions/cache@'))
                    if uses.startswith('actions/upload-artifact@'):
                        self.assertTrue(step['with']['include-hidden-files'])

    def test_deployment_source_is_an_immutable_commit(self):
        for job in self.workflows['deploy-private.yml']['jobs'].values():
            if 'uses' in job:
                self.assertEqual(job['with']['source-ref'], '${{ github.sha }}')
        for job in self.workflows['build-deploy.yml']['jobs'].values():
            for step in job.get('steps', []):
                if step.get('uses', '').startswith('actions/checkout@'):
                    self.assertNotEqual(step.get('with', {}).get('ref'), '${{ github.ref }}')

    def test_profile_maintenance_supports_both_distribution_types(self):
        workflow = self.workflows['regenerate-ios-profiles.yml']
        triggers = workflow.get('on', workflow.get('true'))
        self.assertEqual(triggers['workflow_dispatch']['inputs']['profile-type']['options'],
                         ['appstore', 'adhoc'])


if __name__ == '__main__':
    unittest.main()
