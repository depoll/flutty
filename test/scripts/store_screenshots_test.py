"""Store caption and scene-contract checks. Run on macOS with Pillow."""

import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image, ImageChops, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import generate_store_screenshots as capture
import validate_store_screenshots as validate


class ProCaptionTest(unittest.TestCase):
    def test_every_target_preserves_complete_app_and_dimensions(self):
        for target in capture.TARGETS.values():
            for scene in capture.PRO_SCENE_CAPTIONS:
                with self.subTest(target=target.name, scene=scene):
                    source = Image.new('RGB', target.size, '#123456')
                    before = source.copy()
                    result = capture._add_pro_caption(source, scene)
                    self.assertEqual(result.size, target.size)
                    self.assertIsNone(ImageChops.difference(source, before).getbbox())
                    width, height = source.size
                    band_height = round(width * 0.16)
                    app = ImageOps.contain(
                        source, (width, height - band_height),
                        Image.Resampling.LANCZOS,
                    )
                    x = (width - app.width) // 2
                    actual = result.crop((x, 0, x + app.width, app.height))
                    self.assertIsNone(ImageChops.difference(actual, app).getbbox())
                    badge = (round(width * 0.88), height - band_height + round(width * 0.04))
                    self.assertEqual(result.getpixel(badge), (88, 163, 140))

    def test_android_capture_rejects_another_foreground_app(self):
        states = [
            ('topResumedActivity=ActivityRecord{ xyz.depollsoft.monkeyssh/.MainActivity }', True),
            ('mResumedActivity: ActivityRecord{ xyz.depollsoft.monkeyssh/.MainActivity }', True),
            ('topResumedActivity=ActivityRecord{ another.app/.MainActivity }', False),
            ('mResumedActivity: ActivityRecord{ xyz.depollsoft.monkeyssh/.MainActivity }\n'
             'topResumedActivity=ActivityRecord{ another.app/.MainActivity }', False),
            ('', False),
        ]
        for activity, valid in states:
            with self.subTest(activity=activity):
                with patch.object(capture, '_adb_path', return_value=Path('/test/adb')):
                    with patch.object(capture.subprocess, 'check_output', return_value=activity):
                        if valid:
                            capture._assert_android_capture_foreground('emulator-5580')
                        else:
                            with self.assertRaisesRegex(RuntimeError, 'dedicated emulator'):
                                capture._assert_android_capture_foreground('emulator-5580')

    def test_gallery_uses_current_capture_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / 'ios/fastlane/screenshots/en-US'
            folder.mkdir(parents=True)
            for index, color in ((7, '#123456'), (8, '#654321')):
                Image.new('RGB', (1320, 2868), color).save(folder / f'{index:02d}_iphone_6_9.png')
            with patch.object(capture, 'ROOT', root):
                output = capture._write_iphone_gallery()
                with Image.open(output) as image:
                    self.assertEqual(image.size, (1356, 1458))
                    self.assertEqual(image.getpixel((100, 100)), (18, 52, 86))
                    self.assertEqual(image.getpixel((800, 100)), (101, 67, 33))
                (folder / '08_iphone_6_9.png').unlink()
                with self.assertRaises(FileNotFoundError):
                    capture._write_iphone_gallery()

    def test_scene_option_matches_registered_app_scenes(self):
        source = (ROOT / 'tool/store_screenshot_app.dart').read_text()
        block = source.split('const _sceneNames = <String>[', 1)[1].split('];', 1)[0]
        scenes = re.findall(r"'([^']+)'", block)
        for scene in scenes:
            with patch.object(sys, 'argv', ['capture', 'ios', '--scene', scene]):
                self.assertEqual(capture._parse_args().scene, scene)
        self.assertIn('_sceneNames[index] != _selectedScene', source)
        script = (ROOT / 'scripts/generate_store_screenshots.py').read_text()
        self.assertIn('STORE_SCREENSHOT_SCENE={scene}', script)
        self.assertIn('--bare --model sonnet', script)

    def test_gallery_only_never_launches_a_demo_workspace(self):
        with patch.object(sys, 'argv', ['capture', '--gallery-only']):
            with patch.object(capture, '_write_iphone_gallery') as gallery:
                with patch.object(capture, 'StoreDemoEnvironment') as environment:
                    capture.main()
                    gallery.assert_called_once_with()
                    environment.assert_not_called()

    def test_caption_text_fits_every_target(self):
        for target in capture.TARGETS.values():
            width = target.size[0]
            title_font = ImageFont.load_default(size=round(width * 0.035))
            subtitle_font = ImageFont.load_default(size=round(width * 0.023))
            for title, subtitle in capture.PRO_SCENE_CAPTIONS.values():
                self.assertLess(title_font.getlength(title), width * 0.8)
                self.assertLess(subtitle_font.getlength(subtitle), width * 0.93)

    def test_eight_scenes_registered_in_capture_and_validator(self):
        source = (ROOT / 'tool/store_screenshot_app.dart').read_text()
        scene_block = source.split('const _sceneNames = <String>[', 1)[1].split('];', 1)[0]
        scenes = re.findall(r"'([^']+)'", scene_block)
        self.assertEqual(len(scenes), validate.SCREENSHOT_COUNT)
        self.assertEqual(scenes[-2:], ['native_copilot', 'agent_management'])
        announced = re.findall(r'await _announceScene\((\d+)\)', source)
        self.assertEqual([int(index) for index in announced], list(range(8)))

    def test_agent_scenes_resolve_live_names_not_stale_numeric_indices(self):
        source = (ROOT / 'tool/store_screenshot_app.dart').read_text()
        self.assertNotRegex(source, r'_selectMonkeyMuxWindow\(\d+')
        for agent in ('copilot', 'claude', 'opencode'):
            self.assertIn(f"_selectMonkeyMuxWindow('{agent}')", source)
        self.assertIn('window.name == windowName', source)
        self.assertIn('selectWindow(session, _muxSessionName, window.index)', source)
        self.assertNotIn('onTimeout: () {}', source)

    def test_claude_trust_prompt_handles_old_and_new_defaults(self):
        for prompt, keys in (
            ('❯ No, exit\n  Yes, I trust this folder', ['Down', 'Enter']),
            ('❯ Yes, I trust this folder\n  No, exit', ['Enter']),
        ):
            with self.subTest(prompt=prompt):
                demo = object.__new__(capture.StoreDemoEnvironment)
                with patch.object(demo, '_capture_visible_pane', side_effect=[prompt, 'Claude Code shortcuts']):
                    with patch.object(demo, '_monkeymux_send_keys') as send:
                        with patch.object(capture.time, 'sleep'):
                            demo._drive_claude_to_ready_prompt()
                        self.assertEqual(
                            [call.args for call in send.call_args_list],
                            [('claude', key) for key in keys],
                        )

    def test_native_scene_has_no_badge_when_available_free(self):
        self.assertNotIn('native_copilot', capture.PRO_SCENE_CAPTIONS)
        self.assertEqual(set(capture.PRO_SCENE_CAPTIONS), {'agent_management'})
        path = ROOT / 'ios/fastlane/screenshots/en-US/07_iphone_6_9.png'
        valid = 'Message the agent reconnect'
        with patch.object(validate, '_ocr_texts', return_value={path: valid}):
            validate._validate_ocr_content([path])
        for missing in ('Message the agent', 'reconnect'):
            with self.subTest(missing=missing):
                with patch.object(validate, '_ocr_texts', return_value={path: valid.replace(missing, '')}):
                    with self.assertRaisesRegex(ValueError, 'missing expected'):
                        validate._validate_ocr_content([path])

    def test_manager_scene_requires_real_app_labels_and_badge(self):
        path = ROOT / 'ios/fastlane/screenshots/en-US/08_iphone_6_9.png'
        valid = 'Agent Management PRO Copilot CLI Claude Code'
        with patch.object(validate, '_ocr_texts', return_value={path: valid}):
            validate._validate_ocr_content([path])
        for missing in ('PRO', 'Copilot CLI', 'Claude Code'):
            with self.subTest(missing=missing):
                with patch.object(validate, '_ocr_texts', return_value={path: valid.replace(missing, '') + ' prompt progress provider'}):
                    with self.assertRaisesRegex(ValueError, 'missing expected'):
                        validate._validate_ocr_content([path])


class CaptureLaunchTest(unittest.TestCase):
    def test_ansi_strips_complete_osc_sequences(self):
        for sequence in ('\x1b]0;hidden title\x07', '\x1b]7;file:///hidden/path\x1b\\'):
            with self.subTest(sequence=sequence):
                self.assertEqual(capture._strip_terminal_output(sequence + '\x1b[32mvisible\x1b[0m'), 'visible')

    def test_control_hello_timeout_closes_process_and_reader(self):
        from unittest.mock import Mock
        process = Mock()
        process.poll.return_value = None
        with patch.object(capture.subprocess, 'Popen', return_value=process), \
             patch.object(capture.threading, 'Thread') as thread, \
             patch.object(capture._MonkeyMuxControl, '_wait_for_hello', side_effect=RuntimeError('hello timeout')):
            with self.assertRaisesRegex(RuntimeError, 'hello timeout'):
                capture._MonkeyMuxControl(Path('/test/monkeymux'), 'demo', {})
        process.stdin.close.assert_called_once()
        process.send_signal.assert_called_once_with(capture.signal.SIGTERM)
        process.wait.assert_called_once_with(timeout=2)
        thread.return_value.join.assert_called_once_with(timeout=1)

    def test_shared_flutter_launch_configuration(self):
        from types import SimpleNamespace
        demo = SimpleNamespace(port=2223, username='demo', private_key_b64='key',
                               host_key_b64='host', host_key_fingerprint='fingerprint',
                               mux_session='demo', demo_dir=Path('/demo'))
        with patch.object(capture, '_java_home_17', return_value='/jdk17'):
            env = capture._flutter_environment()
        self.assertEqual(env['JAVA_HOME'], '/jdk17')
        for target in capture.TARGETS.values():
            with self.subTest(target=target.name), \
                 patch.object(capture, '_build_android_screenshot_apk', return_value=Path('/app.apk')) as build:
                defines = capture._capture_defines(target, demo)
                self.assertEqual(len(defines), 10)
                self.assertIn(f'--dart-define=STORE_SCREENSHOT_TARGET={target.name}', defines)
                self.assertIn('--dart-define=STORE_SCREENSHOT_SSH_PORT=2223', defines)
                self.assertIn('--dart-define=STORE_SCREENSHOT_WORKSPACE_PATH=/demo', defines)
                command = capture._flutter_command(target, 'device', env, defines)
                if target.platform == 'android':
                    self.assertEqual(command, ['flutter', 'run', '-d', 'device', '--use-application-binary', '/app.apk', '--no-pub'])
                    build.assert_called_once_with(env, defines)
                else:
                    self.assertEqual(command, ['flutter', 'run', '--debug', '-d', 'device', '-t', 'tool/store_screenshot_app.dart', *defines, '--flavor', 'production'])
                    build.assert_not_called()

    def test_capture_consumes_markers_and_terminates_flutter(self):
        from unittest.mock import Mock
        demo = Mock(demo_image_b64='image')
        process = Mock(stdout=iter([
            capture.READY_MARKER + '{"paths":["capture.png"],"scene":"hosts"}\n',
            capture.DONE_MARKER + '\n',
        ]))
        with patch.object(capture, '_flutter_environment', return_value={}), \
             patch.object(capture, '_capture_defines', return_value=[]), \
             patch.object(capture, '_flutter_command', return_value=['flutter']) as command, \
             patch.object(capture.subprocess, 'Popen', return_value=process), \
             patch.object(capture, '_capture_native_screenshot') as screenshot, \
             patch.object(capture, '_terminate_process') as terminate, \
             patch.object(capture.time, 'sleep'):
            target = capture.TARGETS['ios_phone']
            capture._run_flutter_capture(target, 'device', demo, scene='hosts')
        screenshot.assert_called_once_with(target=target, device_id='device', paths=[ROOT / 'capture.png'], scene='hosts')
        self.assertIn('--dart-define=STORE_SCREENSHOT_SCENE=hosts', command.call_args.args[3])
        terminate.assert_called_once_with(process, timeout=20)


if __name__ == '__main__':
    unittest.main()
