"""Exercise independent build identity and deployment workflow handoffs."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from metadata_changes import classify
from preview_build_number import build_number


class PreviewVersionTest(unittest.TestCase):
    def test_same_event_is_stable_for_both_platforms_and_retries(self):
        event = {'pull_request': {'updated_at': '2026-09-07T12:34:56Z'}}
        self.assertEqual(build_number(event), 178878449)
        self.assertEqual(build_number(event), build_number(event))
        self.assertEqual(build_number(event), build_number({
            'pull_request': {'updated_at': '2026-09-07T05:34:56-07:00'}}))

    def test_invalid_or_ambiguous_event_does_not_guess_a_version(self):
        for value in ['invalid', '2026-09-07T12:34:56', '1960-01-01T00:00:00Z',
                      '3000-01-01T00:00:00Z']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                build_number({'pull_request': {'updated_at': value}})


class MetadataChangesTest(unittest.TestCase):
    def test_copy_only_changes_skip_all_media(self):
        for platform in ['ios', 'android']:
            result = classify([f'{platform}/fastlane/metadata-private/en-US/description.txt'])
            self.assertTrue(result[platform])
            self.assertFalse(any(result[key] for key in
                                 ['ios_screenshots', 'ios_app_previews', 'android_screenshots']))

    def test_icons_and_android_images_require_android_media(self):
        for path in ['assets/icons/icon.png', 'scripts/sync_play_store_icons.py',
                     'android/fastlane/metadata-production/android/en-US/images/icon.png']:
            result = classify([path])
            self.assertTrue(result['android_screenshots'])
            self.assertFalse(result['ios'])

    def test_missing_base_and_pipeline_edits_validate_all_media(self):
        for paths in [None, ['scripts/store_assets.sh'], ['scripts/validate_store_screenshots.py'],
                      ['.github/workflows/sync-metadata.yml']]:
            result = classify(paths)
            self.assertTrue(all(result[key] for key in
                                ['ios', 'android', 'ios_screenshots', 'ios_app_previews', 'android_screenshots']))

    def test_manual_sync_limits_platform_and_listing(self):
        result = classify(None, 'ios', 'private')
        self.assertEqual(json.loads(result['apps']), ['private'])
        self.assertTrue(result['ios_app_previews'])
        self.assertFalse(result['android_screenshots'])
        self.assertFalse(result['android'])
        self.assertEqual(json.loads(classify([], app='both')['apps']), ['private', 'production'])

    def test_preflight_helper_change_syncs_ios_copy(self):
        self.assertTrue(classify(['scripts/store_metadata.rb'])['ios'])

    def test_invalid_selectors_fail(self):
        with self.assertRaises(ValueError):
            classify([], 'other')
        with self.assertRaises(ValueError):
            classify([], app='other')


class DeploymentContractsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        script = "require 'yaml'; require 'json'; puts JSON.generate(ARGV.to_h { |f| [File.basename(f), YAML.load_file(f)] })"
        cls.workflows = json.loads(subprocess.check_output(
            ['ruby', '-e', script, *map(str, (ROOT / '.github/workflows').glob('*.yml'))], text=True))

    def test_main_builds_once_per_platform_and_reuses_identical_binary(self):
        jobs = self.workflows['deploy-private.yml']['jobs']
        for platform, artifact in [('android', 'aab'), ('ios', 'ipa')]:
            producer = jobs[f'build-{platform}']['with']
            self.assertTrue(producer[f'build-{platform}-unsigned-{artifact}'])
            self.assertNotIn(f'{platform}-reuse-run-id', producer)
            consumers = [jobs[f'distribute-{platform}-{channel}'] for channel in ['store', 'firebase']]
            for consumer in consumers:
                self.assertEqual(consumer['needs'], ['compute-version', f'build-{platform}'])
                inputs = consumer['with']
                for field in ['source-ref', 'build-name', 'build-number', 'build-codename',
                              'pr-number', 'pr-title', 'enable-diagnostics', 'flavor']:
                    self.assertEqual(inputs[field], producer[field])
                self.assertEqual(inputs[f'{platform}-reuse-run-id'], '${{ github.run_id }}')
                self.assertEqual(inputs[f'{platform}-reuse-source-sha'], '${{ github.sha }}')
                self.assertTrue(inputs[f'{platform}-reuse-{artifact}-is-unsigned'])
            self.assertEqual(consumers[0]['with'][f'{platform}-reuse-{artifact}-artifact-name'],
                             consumers[1]['with'][f'{platform}-reuse-{artifact}-artifact-name'])
        firebase = self.workflows['firebase-distribution.yml']
        self.assertNotIn('push', firebase.get('on', firebase.get('true')))
        groups = [job['with']['deployment-concurrency-group'] for job in jobs.values() if 'uses' in job]
        self.assertEqual(len(groups), len(set(groups)))
        self.assertNotEqual(jobs['build-android']['with']['monkeymux-assets-artifact-name'],
                            jobs['build-ios']['with']['monkeymux-assets-artifact-name'])

    def test_platform_previews_start_on_same_event_and_use_same_version_function(self):
        for name in ['preview.yml', 'preview-ios.yml']:
            workflow = self.workflows[name]
            triggers = workflow.get('on', workflow.get('true'))
            self.assertIn('pull_request', triggers)
            self.assertNotIn('workflow_run', triggers)
            job = workflow['jobs']['compute-version']
            self.assertIn('head.repo.full_name == github.repository', job['if'])
            version_step = next(s for s in job['steps'] if s.get('id') == 'version')
            self.assertIn('python3 scripts/preview_build_number.py', version_step['run'])
        self.assertIn('github.event.pull_request.updated_at', self.workflows['preview-ios.yml']['run-name'])

    def test_processing_leaves_mac_but_remains_part_of_final_status(self):
        jobs = self.workflows['build-deploy.yml']['jobs']
        followup = jobs['finish-testflight']
        self.assertEqual(followup['runs-on'], 'ubuntu-latest')
        self.assertEqual(followup['needs'], 'build-ios')
        self.assertIn('finish-testflight', jobs['deploy-status-summary']['needs'])
        self.assertIn('finish-testflight', jobs['update-ios-deploy-comment']['needs'])
        marker = jobs['record-private-deploy-build-number']
        self.assertNotIn('finish-testflight', marker['needs'])
        self.assertIn('always()', marker['if'])
        self.assertIn('outputs.store-uploaded', marker['if'])

    def test_copy_only_metadata_can_run_when_media_jobs_are_skipped(self):
        jobs = self.workflows['sync-metadata.yml']['jobs']
        restore = jobs['restore-store-assets']
        self.assertIn('outputs.ios_screenshots', restore['if'])
        self.assertNotIn("outputs.ios == 'true'", restore['if'])
        for platform in ['ios', 'android']:
            job = jobs[f'sync-{platform}']
            self.assertIn("needs.restore-store-assets.result == 'skipped'", job['if'])
            self.assertIn('!cancelled()', job['if'])
        self.assertEqual(jobs['sync-ios']['strategy']['matrix']['app'],
                         '${{ fromJSON(needs.preflight-ios.outputs.apps) }}')
        self.assertIn('preflight-ios', jobs['metadata-result']['needs'])

    def test_published_validation_applies_to_the_same_artifact_snapshot(self):
        publisher = self.workflows['publish-store-assets.yml']['jobs']['sync-metadata']
        self.assertTrue(publisher['with']['use-validated-store-assets'])
        jobs = self.workflows['sync-metadata.yml']['jobs']
        restore = next(s for s in jobs['restore-store-assets']['steps'] if s.get('name') == 'Download published store assets')
        self.assertIn('download --run-id "$GITHUB_RUN_ID"', restore['run'])
        for job in ['validate_ios_screenshots', 'validate_android_screenshots', 'validate_ios_app_previews']:
            self.assertIn('!inputs.use-validated-store-assets', jobs[job]['if'])

    def test_store_and_profile_writers_share_locks(self):
        builds = self.workflows['build-deploy.yml']['jobs']
        metadata = self.workflows['sync-metadata.yml']['jobs']
        for platform, group in [('ios', 'app-store'), ('android', 'play-store')]:
            self.assertIn(group, builds[f'build-{platform}']['concurrency']['group'])
            self.assertEqual(metadata[f'sync-{platform}']['concurrency']['group'], group + '-${{ matrix.app }}')
        maintenance = self.workflows['regenerate-ios-profiles.yml']['concurrency']['group']
        self.assertIn(maintenance, builds['build-ios']['concurrency']['group'])

    def test_every_runner_job_has_a_bounded_timeout(self):
        for name, workflow in self.workflows.items():
            for job_name, job in workflow['jobs'].items():
                with self.subTest(workflow=name, job=job_name):
                    if 'runs-on' in job:
                        self.assertGreater(job['timeout-minutes'], 0)
                        self.assertLessEqual(job['timeout-minutes'], 30)


if __name__ == '__main__':
    unittest.main()
