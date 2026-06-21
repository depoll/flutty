#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

import generate_store_screenshots as store_screenshots

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIR = ROOT / 'build/store-demo-videos'
DEFAULT_SCENE_HOLD_MS = 1600
ANDROID_RECORDING_BIT_RATE = 8_000_000
IOS_APP_PREVIEW_NAME = 'iphone_67_1.mov'
PIXEL_LAUNCHER_PACKAGE = 'com.google.android.apps.nexuslauncher'


@dataclass(frozen=True)
class DemoVideoTarget:
    name: str
    screenshot_target: store_screenshots.ScreenshotTarget
    output_name: str
    ios_app_preview_name: str | None = None


@dataclass(frozen=True)
class PromoSegment:
    headline: str
    body: str
    eyebrow: str
    accent: tuple[int, int, int]


TARGETS = {
    'ios': DemoVideoTarget(
        name='ios',
        screenshot_target=store_screenshots.TARGETS['ios_phone'],
        output_name='monkeyssh-ios-demo.mov',
        ios_app_preview_name=IOS_APP_PREVIEW_NAME,
    ),
    'android': DemoVideoTarget(
        name='android',
        screenshot_target=store_screenshots.TARGETS['android_phone'],
        output_name='monkeyssh-android-demo.mp4',
    ),
}


def main() -> None:
    store_screenshots._prefer_stable_xcode()
    args = _parse_args()
    targets = _targets_for_platform(args.platform)
    output_dir = Path(args.output_dir).expanduser().resolve()

    with store_screenshots.StoreDemoEnvironment() as demo:
        for target in targets:
            _run_target(
                target=target,
                demo=demo,
                output_dir=output_dir,
                scene_hold_ms=args.scene_hold_ms,
                write_ios_app_preview=args.ios_app_preview,
            )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Record short real-device MonkeySSH product demo videos.',
    )
    parser.add_argument(
        'platform',
        choices=['ios', 'android', 'both'],
        nargs='?',
        default='both',
        help='Which demo video to record.',
    )
    parser.add_argument(
        '--output-dir',
        default=str(DEFAULT_OUTPUT_DIR),
        help='Directory for generated videos. Defaults to build/store-demo-videos.',
    )
    parser.add_argument(
        '--scene-hold-ms',
        type=int,
        default=DEFAULT_SCENE_HOLD_MS,
        help='Milliseconds to hold each settled scene while recording.',
    )
    parser.add_argument(
        '--ios-app-preview',
        action='store_true',
        help=(
            'Also copy the iOS video into ios/fastlane/app-previews/en-US '
            f'as {IOS_APP_PREVIEW_NAME}.'
        ),
    )
    return parser.parse_args()


def _targets_for_platform(platform: str) -> list[DemoVideoTarget]:
    if platform == 'ios':
        return [TARGETS['ios']]
    if platform == 'android':
        return [TARGETS['android']]
    return [TARGETS['ios'], TARGETS['android']]


def _run_target(
    *,
    target: DemoVideoTarget,
    demo: store_screenshots.StoreDemoEnvironment,
    output_dir: Path,
    scene_hold_ms: int,
    write_ios_app_preview: bool,
) -> None:
    print(f'Recording {target.name} demo video...')
    demo.reset_monkeymux()
    screenshot_target = target.screenshot_target
    if screenshot_target.platform == 'ios':
        device_id = store_screenshots._boot_ios_simulator(
            store_screenshots._ios_simulator_name(screenshot_target),
        )
        store_screenshots._reset_ios_app_state(device_id)
        restore_android = None
    else:
        device_id = store_screenshots._android_device_id()
        restore_android = store_screenshots._configure_android_display(
            screenshot_target,
            device_id,
        )

    output_path = output_dir / target.name / target.output_name
    output_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='monkeyssh-demo-video-') as tmpdir:
            raw_path = Path(tmpdir) / f'raw{output_path.suffix}'
            _run_flutter_recording(
                target=screenshot_target,
                device_id=device_id,
                demo=demo,
                output_path=raw_path,
                scene_hold_ms=scene_hold_ms,
            )
            _compose_promotional_video(
                target=screenshot_target,
                raw_path=raw_path,
                output_path=output_path,
            )
    finally:
        if restore_android is not None:
            restore_android()

    if (
        write_ios_app_preview
        and target.ios_app_preview_name is not None
        and screenshot_target.platform == 'ios'
    ):
        app_preview_path = (
            ROOT
            / 'ios/fastlane/app-previews/en-US'
            / target.ios_app_preview_name
        )
        app_preview_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(output_path, app_preview_path)
        print(f'Wrote {app_preview_path.relative_to(ROOT)}')


def _run_flutter_recording(
    *,
    target: store_screenshots.ScreenshotTarget,
    device_id: str,
    demo: store_screenshots.StoreDemoEnvironment,
    output_path: Path,
    scene_hold_ms: int,
) -> None:
    env = os.environ.copy()
    java_home = store_screenshots._java_home_17()
    if java_home:
        env['JAVA_HOME'] = java_home
    if target.platform == 'android':
        _dismiss_android_system_dialogs(device_id, force=True)

    dart_defines = [
        f'--dart-define=STORE_SCREENSHOT_TARGET={target.name}',
        f'--dart-define=STORE_SCREENSHOT_SSH_PORT={demo.port}',
        f'--dart-define=STORE_SCREENSHOT_SSH_USERNAME={demo.username}',
        f'--dart-define=STORE_SCREENSHOT_SSH_PRIVATE_KEY_B64={demo.private_key_b64}',
        f'--dart-define=STORE_SCREENSHOT_SSH_HOST_KEY_B64={demo.host_key_b64}',
        (
            '--dart-define=STORE_SCREENSHOT_SSH_HOST_KEY_FINGERPRINT='
            f'{demo.host_key_fingerprint}'
        ),
        f'--dart-define=STORE_SCREENSHOT_MUX_SESSION={demo.mux_session}',
        f'--dart-define=STORE_SCREENSHOT_WORKSPACE_PATH={demo.demo_dir}',
        '--dart-define=STORE_SCREENSHOT_REDACT_IDENTITIES=true',
        '--dart-define=STORE_SCREENSHOT_HIDE_KEYBOARD_TOOLBAR=true',
        '--dart-define=STORE_SCREENSHOT_DISABLE_NOTIFICATIONS=true',
        f'--dart-define=STORE_SCREENSHOT_SCENE_HOLD_MS={scene_hold_ms}',
    ]
    command = _flutter_command(target, device_id, env, dart_defines)
    watchdog = (
        _AndroidSystemDialogWatchdog(device_id)
        if target.platform == 'android'
        else None
    )
    if watchdog is not None:
        watchdog.start()
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None

    recorder: _NativeScreenRecorder | None = None
    saw_done = False
    try:
        for raw_line in process.stdout:
            print(raw_line, end='')
            line = raw_line.strip()
            if store_screenshots.READY_MARKER in line and recorder is None:
                if target.platform == 'android':
                    _dismiss_android_system_dialogs(device_id, force=True)
                pending_recorder = _recorder_for_target(target, device_id, output_path)
                pending_recorder.start()
                recorder = pending_recorder
            if store_screenshots.DONE_MARKER in line:
                saw_done = True
                break
    finally:
        if recorder is not None:
            recorder.stop()
        if watchdog is not None:
            watchdog.stop()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=20)

    if not saw_done:
        if process.returncode not in (0, None):
            raise subprocess.CalledProcessError(process.returncode, command)
        raise RuntimeError(f'{target.name} run ended before the video was complete')
    if recorder is None:
        raise RuntimeError(f'{target.name} run ended before recording started')
    if output_path.stat().st_size < 500_000:
        raise RuntimeError(f'{output_path} is too small to be a real screen recording')

    print(f'Wrote {_display_path(output_path)}')


def _compose_promotional_video(
    *,
    target: store_screenshots.ScreenshotTarget,
    raw_path: Path,
    output_path: Path,
) -> None:
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg is None:
        raise RuntimeError('ffmpeg is required to compose store demo videos.')

    duration = _video_duration(raw_path)
    with tempfile.TemporaryDirectory(prefix='monkeyssh-demo-compose-') as tmpdir:
        tmpdir_path = Path(tmpdir)
        layout = _promo_layout(target)
        base_path, overlay_specs = _write_promo_assets(
            target=target,
            duration=duration,
            layout=layout,
            directory=tmpdir_path,
        )
        command = [
            ffmpeg,
            '-y',
            '-loglevel',
            'error',
            '-i',
            str(raw_path),
            '-loop',
            '1',
            '-t',
            f'{duration:.3f}',
            '-i',
            str(base_path),
        ]
        for overlay_path, _, _ in overlay_specs:
            command.extend(
                [
                    '-loop',
                    '1',
                    '-t',
                    f'{duration:.3f}',
                    '-i',
                    str(overlay_path),
                ]
            )

        filter_parts = [
            (
                f'[0:v]scale={layout["screen_width"]}:{layout["screen_height"]}:'
                'force_original_aspect_ratio=decrease,'
                f'pad={layout["screen_width"]}:{layout["screen_height"]}:'
                '(ow-iw)/2:(oh-ih)/2:color=0x050816,setsar=1[app]'
            ),
            '[1:v]format=rgba[stage0]',
            (
                f'[stage0][app]overlay={layout["screen_x"]}:{layout["screen_y"]}:'
                'shortest=1[stage1]'
            ),
        ]
        stage = 'stage1'
        for index, (_, start, end) in enumerate(overlay_specs, start=2):
            next_stage = f'stage{index}'
            filter_parts.append(
                f'[{stage}][{index}:v]overlay=0:0:'
                f"enable='between(t,{start:.3f},{end:.3f})'[{next_stage}]"
            )
            stage = next_stage
        filter_parts.append(f'[{stage}]format=yuv420p[out]')

        output_path.parent.mkdir(parents=True, exist_ok=True)
        command.extend(
            [
                '-filter_complex',
                ';'.join(filter_parts),
                '-map',
                '[out]',
                '-an',
                '-r',
                '30',
                '-c:v',
                'libx264',
                '-profile:v',
                'high',
                '-pix_fmt',
                'yuv420p',
                '-movflags',
                '+faststart',
                str(output_path),
            ]
        )
        subprocess.run(command, cwd=ROOT, check=True)

    if output_path.stat().st_size < 500_000:
        raise RuntimeError(f'{output_path} is too small to be a composed demo video')
    print(f'Wrote {_display_path(output_path)}')


def _video_duration(path: Path) -> float:
    ffprobe = shutil.which('ffprobe')
    if ffprobe is None:
        raise RuntimeError('ffprobe is required to read demo video duration.')
    result = subprocess.run(
        [
            ffprobe,
            '-v',
            'error',
            '-show_entries',
            'format=duration',
            '-of',
            'default=noprint_wrappers=1:nokey=1',
            str(path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    return float(result.stdout.strip())


def _promo_layout(target: store_screenshots.ScreenshotTarget) -> dict[str, int]:
    canvas_width, canvas_height = target.size
    if target.platform == 'ios':
        screen_height = int(canvas_height * 0.61)
        top = int(canvas_height * 0.28)
    else:
        screen_height = int(canvas_height * 0.60)
        top = int(canvas_height * 0.29)
    screen_width = int(screen_height * canvas_width / canvas_height)
    screen_width = min(screen_width, int(canvas_width * 0.68))
    left = (canvas_width - screen_width) // 2
    return {
        'canvas_width': canvas_width,
        'canvas_height': canvas_height,
        'screen_width': screen_width,
        'screen_height': screen_height,
        'screen_x': left,
        'screen_y': top,
    }


def _write_promo_assets(
    *,
    target: store_screenshots.ScreenshotTarget,
    duration: float,
    layout: dict[str, int],
    directory: Path,
) -> tuple[Path, list[tuple[Path, float, float]]]:
    base_path = directory / 'base.png'
    base = _create_promo_base(target, layout)
    base.save(base_path)

    segments = _promo_segments()
    segment_duration = duration / len(segments)
    overlay_specs: list[tuple[Path, float, float]] = []
    for index, segment in enumerate(segments):
        start = index * segment_duration
        end = duration if index == len(segments) - 1 else (index + 1) * segment_duration
        overlay_path = directory / f'overlay-{index:02d}.png'
        _create_promo_overlay(segment, index, len(segments), layout).save(overlay_path)
        overlay_specs.append((overlay_path, start, end))
    return base_path, overlay_specs


def _promo_segments() -> list[PromoSegment]:
    return [
        PromoSegment(
            eyebrow='Mobile SSH',
            headline='Your servers, now pocket-sized.',
            body='Secure terminals, files, keys, snippets, and tunnels in one focused workspace.',
            accent=(0, 201, 255),
        ),
        PromoSegment(
            eyebrow='Agent workspaces',
            headline='Keep AI coding agents alive remotely.',
            body='Run Copilot, Claude, Gemini, Codex, OpenCode, and Antigravity side by side.',
            accent=(167, 139, 250),
        ),
        PromoSegment(
            eyebrow='Fast launch',
            headline='Jump from host to workflow in seconds.',
            body='Favorites, trusted keys, and reusable commands are ready when incidents hit.',
            accent=(52, 211, 153),
        ),
        PromoSegment(
            eyebrow='MonkeyMux',
            headline='Switch long-running sessions instantly.',
            body='Move between agent windows without losing panes, scrollback, or context.',
            accent=(244, 114, 182),
        ),
        PromoSegment(
            eyebrow='SFTP included',
            headline='Fix files without leaving SSH.',
            body='Browse, edit, and move remote files right beside the terminal.',
            accent=(96, 165, 250),
        ),
        PromoSegment(
            eyebrow='Reconnect',
            headline='Pick up exactly where you left off.',
            body='Persistent remote panes make mobile networks and app switches less scary.',
            accent=(251, 113, 133),
        ),
        PromoSegment(
            eyebrow='MonkeySSH',
            headline='Agentic mobile SSH for builders.',
            body='A complete command center for real work away from the desk.',
            accent=(34, 211, 238),
        ),
    ]


def _create_promo_base(
    target: store_screenshots.ScreenshotTarget,
    layout: dict[str, int],
) -> Image.Image:
    width = layout['canvas_width']
    height = layout['canvas_height']
    image = Image.new('RGB', (width, height), (8, 10, 24))
    draw = ImageDraw.Draw(image)
    for y in range(height):
        ratio = y / max(height - 1, 1)
        red = int(9 + ratio * 15)
        green = int(12 + ratio * 8)
        blue = int(31 + ratio * 24)
        draw.line([(0, y), (width, y)], fill=(red, green, blue))

    glows = Image.new('RGBA', image.size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glows)
    glow_draw.ellipse(
        (-width // 3, -height // 8, width // 2, height // 3),
        fill=(0, 201, 255, 72),
    )
    glow_draw.ellipse(
        (width // 2, height // 5, width + width // 4, height),
        fill=(167, 139, 250, 56),
    )
    glow_draw.ellipse(
        (-width // 4, height // 2, width // 3, height + height // 5),
        fill=(244, 114, 182, 36),
    )
    image = Image.alpha_composite(
        image.convert('RGBA'),
        glows.filter(ImageFilter.GaussianBlur(radius=90)),
    )
    draw = ImageDraw.Draw(image)

    brand_font = _load_font(40 if target.platform == 'ios' else 36, bold=True)
    tagline_font = _load_font(22 if target.platform == 'ios' else 20)
    margin = int(width * 0.08)
    draw.text((margin, int(height * 0.045)), 'MonkeySSH', font=brand_font, fill=(255, 255, 255))
    draw.text(
        (margin, int(height * 0.073)),
        'SSH + agents + files, built for mobile work',
        font=tagline_font,
        fill=(208, 213, 221),
    )

    screen_x = layout['screen_x']
    screen_y = layout['screen_y']
    screen_width = layout['screen_width']
    screen_height = layout['screen_height']
    shadow = Image.new('RGBA', image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    frame_rect = [
        screen_x - 18,
        screen_y - 18,
        screen_x + screen_width + 18,
        screen_y + screen_height + 18,
    ]
    shadow_draw.rounded_rectangle(frame_rect, radius=48, fill=(0, 0, 0, 160))
    image = Image.alpha_composite(
        image,
        shadow.filter(ImageFilter.GaussianBlur(radius=22)),
    )
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        frame_rect,
        radius=48,
        outline=(255, 255, 255, 70),
        width=4,
        fill=(5, 8, 22, 255),
    )

    chip_y = int(height * 0.93)
    chip_font = _load_font(22 if target.platform == 'ios' else 20, bold=True)
    chips = ['SSH', 'SFTP', 'Agents', 'Snippets', 'Keys', 'Tunnels']
    x = margin
    for chip in chips:
        bbox = draw.textbbox((0, 0), chip, font=chip_font)
        chip_width = bbox[2] - bbox[0] + 34
        draw.rounded_rectangle(
            [x, chip_y, x + chip_width, chip_y + 48],
            radius=24,
            fill=(255, 255, 255, 28),
            outline=(255, 255, 255, 48),
            width=1,
        )
        draw.text((x + 17, chip_y + 12), chip, font=chip_font, fill=(239, 246, 255))
        x += chip_width + 12
        if x > width - margin - 80:
            break

    return image


def _create_promo_overlay(
    segment: PromoSegment,
    index: int,
    count: int,
    layout: dict[str, int],
) -> Image.Image:
    width = layout['canvas_width']
    height = layout['canvas_height']
    image = Image.new('RGBA', (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    margin = int(width * 0.08)
    top = int(height * 0.11)
    accent = (*segment.accent, 255)

    eyebrow_font = _load_font(20 if height > 2600 else 18, bold=True)
    headline_font = _load_font(58 if height > 2600 else 48, bold=True)
    body_font = _load_font(29 if height > 2600 else 25)
    small_font = _load_font(20 if height > 2600 else 18, bold=True)

    pill_text = f'{index + 1}/{count}  {segment.eyebrow.upper()}'
    pill_bbox = draw.textbbox((0, 0), pill_text, font=eyebrow_font)
    pill_width = pill_bbox[2] - pill_bbox[0] + 34
    draw.rounded_rectangle(
        [margin, top, margin + pill_width, top + 44],
        radius=22,
        fill=(*segment.accent, 52),
        outline=(*segment.accent, 180),
        width=2,
    )
    draw.text((margin + 17, top + 12), pill_text, font=eyebrow_font, fill=accent)

    headline_y = top + 66
    _draw_wrapped_text(
        draw,
        segment.headline,
        font=headline_font,
        xy=(margin, headline_y),
        max_width=width - 2 * margin,
        fill=(255, 255, 255, 255),
        line_spacing=8,
    )
    body_y = headline_y + _wrapped_text_height(
        draw,
        segment.headline,
        headline_font,
        width - 2 * margin,
        8,
    ) + 18
    _draw_wrapped_text(
        draw,
        segment.body,
        font=body_font,
        xy=(margin, body_y),
        max_width=width - 2 * margin,
        fill=(226, 232, 240, 255),
        line_spacing=7,
    )

    callout_y = layout['screen_y'] + layout['screen_height'] + 54
    callout_height = 132 if height > 2600 else 118
    draw.rounded_rectangle(
        [margin, callout_y, width - margin, callout_y + callout_height],
        radius=28,
        fill=(8, 11, 27, 218),
        outline=(*segment.accent, 150),
        width=2,
    )
    draw.text(
        (margin + 28, callout_y + 24),
        'LIVE APP CAPTURE',
        font=small_font,
        fill=accent,
    )
    _draw_wrapped_text(
        draw,
        _segment_detail(index),
        font=body_font,
        xy=(margin + 28, callout_y + 58),
        max_width=width - 2 * margin - 56,
        fill=(248, 250, 252, 255),
        line_spacing=5,
    )

    progress_x = margin
    progress_y = callout_y + callout_height + 24
    progress_width = width - 2 * margin
    draw.rounded_rectangle(
        [progress_x, progress_y, progress_x + progress_width, progress_y + 7],
        radius=4,
        fill=(255, 255, 255, 42),
    )
    fill_width = int(progress_width * (index + 1) / count)
    draw.rounded_rectangle(
        [progress_x, progress_y, progress_x + fill_width, progress_y + 7],
        radius=4,
        fill=accent,
    )
    return image


def _segment_detail(index: int) -> str:
    details = [
        'Start from a real terminal session, not a mockup.',
        'Persistent remote windows keep every agent ready.',
        'Hosts and snippets make repeat work feel instant.',
        'MonkeyMux turns one SSH connection into a mobile workspace.',
        'SFTP sits beside the terminal for quick fixes.',
        'Reconnect and continue from the same remote context.',
        'Made for production work when your laptop is not open.',
    ]
    return details[index]


def _draw_wrapped_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    *,
    font: ImageFont.ImageFont,
    xy: tuple[int, int],
    max_width: int,
    fill: tuple[int, int, int, int],
    line_spacing: int,
) -> None:
    x, y = xy
    for line in _wrap_text(draw, text, font, max_width):
        draw.text((x, y), line, font=font, fill=fill)
        bbox = draw.textbbox((0, 0), line, font=font)
        y += bbox[3] - bbox[1] + line_spacing


def _wrapped_text_height(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    max_width: int,
    line_spacing: int,
) -> int:
    height = 0
    lines = _wrap_text(draw, text, font, max_width)
    for line in lines:
        bbox = draw.textbbox((0, 0), line, font=font)
        height += bbox[3] - bbox[1] + line_spacing
    return max(height - line_spacing, 0)


def _wrap_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    max_width: int,
) -> list[str]:
    lines: list[str] = []
    current = ''
    for word in text.split():
        candidate = word if not current else f'{current} {word}'
        bbox = draw.textbbox((0, 0), candidate, font=font)
        if bbox[2] - bbox[0] <= max_width:
            current = candidate
            continue
        if current:
            lines.append(current)
        current = word
    if current:
        lines.append(current)
    return lines


def _load_font(size: int, *, bold: bool = False) -> ImageFont.ImageFont:
    candidates = [
        Path('/System/Library/Fonts/Supplemental/Arial Bold.ttf')
        if bold
        else Path('/System/Library/Fonts/Supplemental/Arial.ttf'),
        Path('/System/Library/Fonts/Helvetica.ttc'),
        Path('/Library/Fonts/Arial.ttf'),
        Path('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf')
        if bold
        else Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'),
    ]
    for path in candidates:
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default()


def _display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def _flutter_command(
    target: store_screenshots.ScreenshotTarget,
    device_id: str,
    env: dict[str, str],
    dart_defines: list[str],
) -> list[str]:
    if target.platform == 'android':
        apk_path = store_screenshots._build_android_screenshot_apk(env, dart_defines)
        return [
            'flutter',
            'run',
            '-d',
            device_id,
            '--use-application-binary',
            str(apk_path),
            '--no-pub',
        ]

    command = [
        'flutter',
        'run',
        '--debug',
        '-d',
        device_id,
        '-t',
        'tool/store_screenshot_app.dart',
        *dart_defines,
    ]
    if target.platform == 'ios':
        command.extend(['--flavor', 'production'])
    return command


def _recorder_for_target(
    target: store_screenshots.ScreenshotTarget,
    device_id: str,
    output_path: Path,
) -> _NativeScreenRecorder:
    if target.platform == 'ios':
        return _IosSimulatorRecorder(device_id=device_id, output_path=output_path)
    return _AndroidScreenRecorder(
        device_id=device_id,
        output_path=output_path,
        size=target.size,
    )


class _NativeScreenRecorder:
    def start(self) -> None:
        raise NotImplementedError

    def stop(self) -> None:
        raise NotImplementedError


class _IosSimulatorRecorder(_NativeScreenRecorder):
    def __init__(self, *, device_id: str, output_path: Path) -> None:
        self._device_id = device_id
        self._output_path = output_path
        self._process: subprocess.Popen[str] | None = None

    def start(self) -> None:
        if self._output_path.exists():
            self._output_path.unlink()
        self._process = subprocess.Popen(
            [
                'xcrun',
                'simctl',
                'io',
                self._device_id,
                'recordVideo',
                '--codec=h264',
                '--force',
                str(self._output_path),
            ],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        time.sleep(0.5)
        if self._process.poll() is not None:
            stderr = self._process.stderr.read() if self._process.stderr else ''
            raise RuntimeError(f'iOS screen recording failed to start: {stderr}')

    def stop(self) -> None:
        process = self._process
        self._process = None
        if process is None:
            return
        if process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        if process.stderr is not None:
            process.stderr.close()


class _AndroidScreenRecorder(_NativeScreenRecorder):
    def __init__(
        self,
        *,
        device_id: str,
        output_path: Path,
        size: tuple[int, int],
    ) -> None:
        self._adb = store_screenshots._adb_path()
        self._device_id = device_id
        self._output_path = output_path
        self._size = size
        self._process: subprocess.Popen[str] | None = None
        suffix = f'{os.getpid()}-{int(time.time())}'
        self._remote_path = f'/sdcard/monkeyssh-store-demo-{suffix}.mp4'
        self._pid_path = f'/data/local/tmp/monkeyssh-store-demo-{suffix}.pid'
        self._remote_pid: int | None = None

    def start(self) -> None:
        if self._output_path.exists():
            self._output_path.unlink()
        width, height = self._size
        remote_command = (
            f'echo $$ > {self._pid_path}; '
            'exec screenrecord '
            f'--bit-rate {ANDROID_RECORDING_BIT_RATE} '
            f'--size {width}x{height} '
            f'{self._remote_path}'
        )
        self._process = subprocess.Popen(
            [
                str(self._adb),
                '-s',
                self._device_id,
                'shell',
                remote_command,
            ],
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        self._remote_pid = self._wait_for_remote_pid()

    def stop(self) -> None:
        process = self._process
        self._process = None
        if process is not None and process.poll() is None:
            if self._remote_pid is not None:
                subprocess.run(
                    [
                        str(self._adb),
                        '-s',
                        self._device_id,
                        'shell',
                        'kill',
                        '-2',
                        str(self._remote_pid),
                    ],
                    cwd=ROOT,
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

        subprocess.run(
            [
                str(self._adb),
                '-s',
                self._device_id,
                'pull',
                self._remote_path,
                str(self._output_path),
            ],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            [
                str(self._adb),
                '-s',
                self._device_id,
                'shell',
                'rm',
                '-f',
                self._remote_path,
                self._pid_path,
            ],
            cwd=ROOT,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _wait_for_remote_pid(self) -> int:
        deadline = time.time() + 10
        while time.time() < deadline:
            process = self._process
            if process is not None and process.poll() is not None:
                raise RuntimeError('Android screenrecord exited before recording started')
            result = subprocess.run(
                [
                    str(self._adb),
                    '-s',
                    self._device_id,
                    'shell',
                    'cat',
                    self._pid_path,
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )
            if result.returncode == 0:
                value = result.stdout.strip()
                if value.isdigit():
                    return int(value)
            time.sleep(0.2)
        raise RuntimeError('Timed out waiting for Android screenrecord to start')


class _AndroidSystemDialogWatchdog:
    def __init__(self, device_id: str) -> None:
        self._device_id = device_id
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=3)

    def _run(self) -> None:
        while not self._stop.wait(0.75):
            _dismiss_android_system_dialogs(self._device_id)


def _dismiss_android_system_dialogs(device_id: str, *, force: bool = False) -> None:
    adb = store_screenshots._adb_path()
    if force:
        _force_stop_android_launcher(adb, device_id)
    if not _android_has_system_error_dialog(adb, device_id):
        return
    _force_stop_android_launcher(adb, device_id)
    _press_android_back(adb, device_id)


def _android_has_system_error_dialog(adb: Path, device_id: str) -> bool:
    try:
        result = subprocess.run(
            [str(adb), '-s', device_id, 'shell', 'dumpsys', 'window', 'windows'],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    text = result.stdout.casefold()
    return (
        'application error' in text
        or 'apperrordialog' in text
        or "isn't responding" in text
        or 'not responding' in text
    )


def _force_stop_android_launcher(adb: Path, device_id: str) -> None:
    subprocess.run(
        [
            str(adb),
            '-s',
            device_id,
            'shell',
            'am',
            'force-stop',
            PIXEL_LAUNCHER_PACKAGE,
        ],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def _press_android_back(adb: Path, device_id: str) -> None:
    subprocess.run(
        [str(adb), '-s', device_id, 'shell', 'input', 'keyevent', 'BACK'],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'error: {error}', file=sys.stderr)
        raise
