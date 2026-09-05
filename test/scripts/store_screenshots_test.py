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

    def test_native_scene_requires_pro_badge_and_free_chat_disclosure(self):
        path = ROOT / 'ios/fastlane/screenshots/en-US/07_iphone_6_9.png'
        valid = 'Message the agent reconnect PRO Parallel chats One native chat is free'
        with patch.object(validate, '_ocr_texts', return_value={path: valid}):
            validate._validate_ocr_content([path])
        for missing in ('PRO', 'One native chat is free'):
            with self.subTest(missing=missing):
                with patch.object(validate, '_ocr_texts', return_value={path: valid.replace(missing, '') + ' prompt progress provider'}):
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


if __name__ == '__main__':
    unittest.main()
