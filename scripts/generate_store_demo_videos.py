#!/usr/bin/env python3

from __future__ import annotations

import argparse
import math
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
# Hard ceiling for the composed promo so a slow live-agent capture can never
# exceed the store validation maximum. Normal runs finish well under this.
MAX_COMPOSE_DURATION = 28.0
PIXEL_LAUNCHER_PACKAGE = 'com.google.android.apps.nexuslauncher'
OVERLAY_FPS = 30
COPILOT_PROMPT = 'Draft a release checklist for this SSH app'
CLAUDE_PROMPT = 'Summarize the riskiest release checks'


@dataclass(frozen=True)
class DemoVideoTarget:
    name: str
    screenshot_target: store_screenshots.ScreenshotTarget
    output_name: str
    ios_app_preview_name: str | None = None


@dataclass(frozen=True)
class PromoSegment:
    eyebrow: str
    headline: str
    body: str
    label: str
    accent: tuple[int, int, int]
    interaction: str


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
    restore_error_dialogs = None
    if target.platform == 'android':
        restore_error_dialogs = _suppress_android_error_dialogs(device_id)
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
        '--dart-define=STORE_SCREENSHOT_VIDEO_DEMO=true',
        f'--dart-define=STORE_SCREENSHOT_COPILOT_PROMPT={COPILOT_PROMPT}',
        f'--dart-define=STORE_SCREENSHOT_CLAUDE_PROMPT={CLAUDE_PROMPT}',
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
        if restore_error_dialogs is not None:
            restore_error_dialogs()

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
    duration = min(duration, MAX_COMPOSE_DURATION)
    with tempfile.TemporaryDirectory(prefix='monkeyssh-demo-compose-') as tmpdir:
        tmpdir_path = Path(tmpdir)
        layout = _promo_layout(target)

        base_path = tmpdir_path / 'base.png'
        _create_promo_base(target, layout).save(base_path)

        frames_dir = tmpdir_path / 'overlay-frames'
        frames_dir.mkdir(parents=True, exist_ok=True)
        _render_overlay_frames(
            target=target,
            layout=layout,
            duration=duration,
            fps=OVERLAY_FPS,
            directory=frames_dir,
        )

        screen_w = layout['screen_width']
        screen_h = layout['screen_height']
        screen_x = layout['screen_x']
        screen_y = layout['screen_y']

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
            '-framerate',
            str(OVERLAY_FPS),
            '-i',
            str(frames_dir / 'frame-%05d.png'),
        ]

        filter_parts = [
            (
                f'[0:v]scale={screen_w}:{screen_h}:'
                'force_original_aspect_ratio=decrease,setsar=1[app]'
            ),
            # Gentle living color drift plus imperceptible temporal grain keeps
            # the gradient backdrop measurably in motion every frame, even during
            # long static app holds, so freeze validation stays meaningful.
            "[1:v]format=rgba,hue=h='14*sin(2*PI*t/16)':s=1.06,"
            "noise=alls=8:allf=t[bg]",
            (
                f'[bg][app]overlay=x={screen_x}+({screen_w}-w)/2:'
                f'y={screen_y}+({screen_h}-h)/2:shortest=1[comp]'
            ),
            '[comp][2:v]overlay=0:0:shortest=1[ov]',
            '[ov]format=yuv420p[out]',
        ]

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
                '-t',
                f'{duration:.3f}',
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
        screen_height = int(canvas_height * 0.575)
        top = int(canvas_height * 0.255)
    else:
        screen_height = int(canvas_height * 0.565)
        top = int(canvas_height * 0.262)
    screen_width = int(screen_height * canvas_width / canvas_height)
    screen_width = min(screen_width, int(canvas_width * 0.66))
    left = (canvas_width - screen_width) // 2
    return {
        'canvas_width': canvas_width,
        'canvas_height': canvas_height,
        'screen_width': screen_width,
        'screen_height': screen_height,
        'screen_x': left,
        'screen_y': top,
    }


def _clamp01(value: float) -> float:
    return 0.0 if value < 0 else 1.0 if value > 1 else value


def _ease_in_out(value: float) -> float:
    value = _clamp01(value)
    return value * value * (3 - 2 * value)


def _scale_alpha(image: Image.Image, factor: float) -> None:
    if factor >= 1.0:
        return
    alpha = image.getchannel('A').point(lambda v: int(v * factor))
    image.putalpha(alpha)


def _text_w(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> int:
    bbox = draw.textbbox((0, 0), text, font=font)
    return bbox[2] - bbox[0]


def _text_h(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> int:
    bbox = draw.textbbox((0, 0), text, font=font)
    return bbox[3] - bbox[1]


def _glow_sprite(accent: tuple[int, int, int], size: int, alpha: int) -> Image.Image:
    sprite = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(sprite)
    pad = int(size * 0.18)
    draw.ellipse([pad, pad, size - pad, size - pad], fill=(*accent, alpha))
    return sprite.filter(ImageFilter.GaussianBlur(radius=size * 0.16))


def _render_overlay_frames(
    *,
    target: store_screenshots.ScreenshotTarget,
    layout: dict[str, int],
    duration: float,
    fps: int,
    directory: Path,
) -> int:
    width = layout['canvas_width']
    height = layout['canvas_height']
    big = height > 2600
    segments = _promo_segments()
    seg_count = len(segments)
    seg_dur = duration / seg_count
    margin = int(width * 0.072)
    fonts = {
        'eyebrow': _load_font(28 if big else 23, bold=True),
        'headline': _load_font(66 if big else 54, bold=True),
        'body': _load_font(32 if big else 27),
        'label': _load_font(30 if big else 24, bold=True),
    }

    glow_size = int(width * 0.5)
    glow_sprites = [
        _glow_sprite(segment.accent, glow_size, alpha=80) for segment in segments
    ]

    text_top = int(height * 0.103)

    frame_count = int(math.ceil(duration * fps)) + 1
    for index in range(frame_count):
        t = min(index / fps, duration)
        frame = Image.new('RGBA', (width, height), (0, 0, 0, 0))
        _draw_drift_glow(frame, t, seg_dur, seg_count, glow_sprites, layout)
        _draw_top_text(frame, t, segments, seg_dur, margin, text_top, width, fonts)
        _draw_interaction(frame, t, segments, seg_dur, layout)
        _draw_timeline(frame, t, segments, seg_dur, duration, margin, width, height, fonts)
        frame.save(directory / f'frame-{index:05d}.png')
    return frame_count


def _draw_drift_glow(
    frame: Image.Image,
    t: float,
    seg_dur: float,
    seg_count: int,
    glow_sprites: list[Image.Image],
    layout: dict[str, int],
) -> None:
    width = layout['canvas_width']
    height = layout['canvas_height']
    index = min(int(t / seg_dur), seg_count - 1)
    sprite = glow_sprites[index]
    size = sprite.width
    phase = 2 * math.pi * t
    top_x = int(width * 0.20 + math.sin(phase / 9) * width * 0.10) - size // 2
    top_y = int(height * 0.06 + math.cos(phase / 11) * height * 0.012) - size // 2
    frame.alpha_composite(sprite, (top_x, top_y))
    bottom_x = int(width * 0.80 + math.sin(phase / 8 + 1.7) * width * 0.10) - size // 2
    bottom_y = int(height * 0.94 + math.cos(phase / 10) * height * 0.012) - size // 2
    frame.alpha_composite(sprite, (bottom_x, bottom_y))


def _screen_point(
    layout: dict[str, int],
    fx: float,
    fy: float,
) -> tuple[int, int]:
    """Map a fraction of the live phone-screen rectangle to canvas pixels."""
    return (
        layout['screen_x'] + int(layout['screen_width'] * fx),
        layout['screen_y'] + int(layout['screen_height'] * fy),
    )


def _draw_interaction(
    frame: Image.Image,
    t: float,
    segments: list[PromoSegment],
    seg_dur: float,
    layout: dict[str, int],
) -> None:
    """Draw a touch/pointer/clipboard cue tied to the active segment.

    Each cue is positioned inside the live device capture and timed to the
    segment whose narration it illustrates, so the gesture always maps to the
    UI on screen rather than floating over unrelated content.
    """
    count = len(segments)
    index = min(int(t / seg_dur), count - 1)
    segment = segments[index]
    local = _clamp01((t - index * seg_dur) / seg_dur)

    layer = Image.new('RGBA', frame.size, (0, 0, 0, 0))
    if segment.interaction == 'tap_input':
        _draw_tap(layer, layout, fx=0.5, fy=0.6, local=local, accent=segment.accent)
    elif segment.interaction == 'tap_window':
        _draw_tap(layer, layout, fx=0.5, fy=0.56, local=local, accent=segment.accent)
    elif segment.interaction == 'pointer':
        _draw_pointer(layer, layout, local=local, accent=segment.accent)
    elif segment.interaction == 'image_paste':
        _draw_image_paste(layer, layout, local=local, accent=segment.accent)

    env = min(_clamp01(local / 0.12), _clamp01((1 - local) / 0.12))
    _scale_alpha(layer, env)
    frame.alpha_composite(layer)


def _draw_tap(
    frame: Image.Image,
    layout: dict[str, int],
    *,
    fx: float,
    fy: float,
    local: float,
    accent: tuple[int, int, int],
) -> None:
    """Draw a single finger-tap ripple in the middle of the segment."""
    start, end = 0.30, 0.74
    if local < start or local > end:
        return
    progress = (local - start) / (end - start)
    cx, cy = _screen_point(layout, fx, fy)
    draw = ImageDraw.Draw(frame)
    base = max(int(layout['screen_width'] * 0.052), 18)
    light = _lighten(accent)

    contact = _clamp01(1.0 - abs(progress - 0.18) / 0.55)
    dot_alpha = int(150 * contact)
    if dot_alpha > 0:
        draw.ellipse(
            [cx - base, cy - base, cx + base, cy + base],
            fill=(*light, min(90, dot_alpha)),
            outline=(*light, min(235, dot_alpha + 70)),
            width=max(3, int(base * 0.16)),
        )

    for offset in (0.0, 0.34):
        ripple = progress - offset
        if ripple <= 0 or ripple >= 1:
            continue
        radius = int(base * (1.0 + ripple * 2.7))
        alpha = int(175 * (1 - ripple))
        if alpha <= 0:
            continue
        draw.ellipse(
            [cx - radius, cy - radius, cx + radius, cy + radius],
            outline=(*light, alpha),
            width=max(3, int(base * 0.16)),
        )


def _draw_pointer(
    frame: Image.Image,
    layout: dict[str, int],
    *,
    local: float,
    accent: tuple[int, int, int],
) -> None:
    """Glide an external mouse pointer across the live TUI and click once."""
    travel = _ease_in_out(_clamp01(local / 0.66))
    start_fx, start_fy = 0.74, 0.52
    end_fx, end_fy = 0.40, 0.30
    fx = start_fx + (end_fx - start_fx) * travel
    fy = start_fy + (end_fy - start_fy) * travel
    cx, cy = _screen_point(layout, fx, fy)
    light = _lighten(accent)
    draw = ImageDraw.Draw(frame)

    if local > 0.66:
        click = _clamp01((local - 0.66) / 0.26)
        radius = int(layout['screen_width'] * 0.045 * (1 + click * 2.2))
        alpha = int(180 * (1 - click))
        if alpha > 0:
            draw.ellipse(
                [cx - radius, cy - radius, cx + radius, cy + radius],
                outline=(*light, alpha),
                width=max(3, int(layout['screen_width'] * 0.008)),
            )

    _draw_cursor_arrow(frame, cx, cy, layout)


def _draw_cursor_arrow(
    frame: Image.Image,
    x: int,
    y: int,
    layout: dict[str, int],
) -> None:
    size = max(int(layout['screen_width'] * 0.07), 34)
    shape = [
        (0.0, 0.0),
        (0.0, 1.0),
        (0.26, 0.74),
        (0.42, 1.08),
        (0.56, 1.02),
        (0.40, 0.68),
        (0.72, 0.68),
    ]
    points = [(x + int(px * size), y + int(py * size)) for px, py in shape]
    cursor = Image.new('RGBA', frame.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(cursor)
    shadow = [(px + 3, py + 4) for px, py in points]
    draw.polygon(shadow, fill=(0, 0, 0, 150))
    draw.polygon(
        points,
        fill=(255, 255, 255, 245),
        outline=(15, 18, 32, 245),
    )
    frame.alpha_composite(
        cursor.filter(ImageFilter.GaussianBlur(radius=0.6)),
    )


def _draw_image_paste(
    frame: Image.Image,
    layout: dict[str, int],
    *,
    local: float,
    accent: tuple[int, int, int],
) -> None:
    """Slide a clipboard image card toward the terminal input and drop it."""
    appear = _ease_in_out(_clamp01(local / 0.34))
    drop = _ease_in_out(_clamp01((local - 0.6) / 0.3))
    card_w = max(int(layout['screen_width'] * 0.58), 220)
    card_h = int(card_w * 0.34)
    center_x, center_y = _screen_point(layout, 0.5, 0.52)
    start_x = layout['screen_x'] + int(layout['screen_width'] * 1.25)
    cx = int(start_x + (center_x - start_x) * appear)
    cy = int(center_y + layout['screen_height'] * 0.16 * drop)
    light = _lighten(accent)
    draw = ImageDraw.Draw(frame)

    box = [cx - card_w // 2, cy - card_h // 2, cx + card_w // 2, cy + card_h // 2]
    draw.rounded_rectangle(
        box,
        radius=int(card_h * 0.22),
        fill=(14, 18, 34, 235),
        outline=(*light, 235),
        width=max(2, int(card_h * 0.05)),
    )

    pad = int(card_h * 0.16)
    thumb = [
        box[0] + pad,
        box[1] + pad,
        box[0] + pad + (card_h - 2 * pad),
        box[3] - pad,
    ]
    draw.rounded_rectangle(
        thumb,
        radius=int(card_h * 0.12),
        fill=(*accent, 235),
    )
    # Tiny mountain + sun so the thumbnail reads as an image, not a swatch.
    tw = thumb[2] - thumb[0]
    th = thumb[3] - thumb[1]
    sun_r = int(th * 0.12)
    draw.ellipse(
        [
            thumb[0] + int(tw * 0.62),
            thumb[1] + int(th * 0.2),
            thumb[0] + int(tw * 0.62) + sun_r * 2,
            thumb[1] + int(th * 0.2) + sun_r * 2,
        ],
        fill=(255, 255, 255, 230),
    )
    draw.polygon(
        [
            (thumb[0] + int(tw * 0.12), thumb[3] - int(th * 0.14)),
            (thumb[0] + int(tw * 0.42), thumb[1] + int(th * 0.42)),
            (thumb[0] + int(tw * 0.72), thumb[3] - int(th * 0.14)),
        ],
        fill=(13, 17, 31, 230),
    )

    label_font = _load_font(
        30 if layout['canvas_height'] > 2600 else 25,
        bold=True,
    )
    sub_font = _load_font(
        24 if layout['canvas_height'] > 2600 else 20,
    )
    text_x = thumb[2] + int(card_h * 0.2)
    draw.text(
        (text_x, box[1] + int(card_h * 0.22)),
        'Paste image',
        font=label_font,
        fill=(255, 255, 255, 245),
    )
    draw.text(
        (text_x, box[1] + int(card_h * 0.56)),
        'into your agent',
        font=sub_font,
        fill=(*light, 235),
    )

    if drop > 0:
        input_x, input_y = _screen_point(layout, 0.5, 0.72)
        radius = int(layout['screen_width'] * 0.05 * drop)
        alpha = int(170 * (1 - drop))
        if alpha > 0:
            draw.ellipse(
                [
                    input_x - radius,
                    input_y - radius,
                    input_x + radius,
                    input_y + radius,
                ],
                outline=(*light, alpha),
                width=max(3, int(layout['screen_width'] * 0.008)),
            )


def _draw_top_text(
    frame: Image.Image,
    t: float,
    segments: list[PromoSegment],
    seg_dur: float,
    margin: int,
    text_top: int,
    width: int,
    fonts: dict[str, ImageFont.ImageFont],
) -> None:
    region_w = width - 2 * margin
    fade = 0.5
    for index, segment in enumerate(segments):
        start = index * seg_dur
        local = t - start
        if local < -fade or local > seg_dur + fade:
            continue
        alpha_in = _clamp01(local / fade)
        alpha_out = (
            1.0
            if index == len(segments) - 1
            else _clamp01((seg_dur - local) / fade)
        )
        env = min(alpha_in, alpha_out)
        if env <= 0.01:
            continue
        slide = int((1 - _ease_in_out(alpha_in)) * 48) - int(
            (1 - _ease_in_out(alpha_out)) * 48,
        )
        layer = _render_segment_text(
            segment, index + 1, len(segments), region_w, fonts,
        )
        _scale_alpha(layer, env)
        frame.alpha_composite(layer, (margin, text_top + slide))


def _render_segment_text(
    segment: PromoSegment,
    number: int,
    count: int,
    region_w: int,
    fonts: dict[str, ImageFont.ImageFont],
) -> Image.Image:
    measure = ImageDraw.Draw(Image.new('RGBA', (region_w, 8)))
    eyebrow_font = fonts['eyebrow']
    headline_font = fonts['headline']
    body_font = fonts['body']

    pill_text = f'{number:02d} · {segment.eyebrow.upper()}'
    pill_h = _text_h(measure, 'Ag', eyebrow_font) + 26
    head_h = _wrapped_text_height(measure, segment.headline, headline_font, region_w, 10)
    body_h = _wrapped_text_height(measure, segment.body, body_font, region_w, 8)
    gap1 = 26
    gap2 = 22
    total = pill_h + gap1 + head_h + gap2 + body_h + 8

    layer = Image.new('RGBA', (region_w, total), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    accent = segment.accent

    pill_w = _text_w(draw, pill_text, eyebrow_font) + 40
    draw.rounded_rectangle(
        [0, 0, pill_w, pill_h],
        radius=pill_h // 2,
        fill=(*accent, 46),
        outline=(*accent, 210),
        width=2,
    )
    draw.text((20, (pill_h - _text_h(draw, 'Ag', eyebrow_font)) // 2 - 2),
              pill_text, font=eyebrow_font, fill=(*_lighten(accent), 255))

    headline_y = pill_h + gap1
    _draw_wrapped_text(
        draw,
        segment.headline,
        font=headline_font,
        xy=(0, headline_y),
        max_width=region_w,
        fill=(255, 255, 255, 255),
        line_spacing=10,
    )
    body_y = headline_y + head_h + gap2
    _draw_wrapped_text(
        draw,
        segment.body,
        font=body_font,
        xy=(0, body_y),
        max_width=region_w,
        fill=(206, 214, 229, 255),
        line_spacing=8,
    )
    return layer


def _lighten(accent: tuple[int, int, int]) -> tuple[int, int, int]:
    return tuple(min(255, int(c + (255 - c) * 0.45)) for c in accent)


def _promo_segments() -> list[PromoSegment]:
    return [
        PromoSegment(
            eyebrow='Real SSH',
            headline='Ask an agent over real SSH.',
            body='Type a prompt into a live terminal and your coding agent '
            'answers — right from your phone.',
            label='Copilot',
            accent=(0, 201, 255),
            interaction='tap_input',
        ),
        PromoSegment(
            eyebrow='Always on',
            headline='Keep every agent running in MonkeyMux.',
            body='Switch between long-running agent sessions without dropping '
            'a thing.',
            label='MonkeyMux',
            accent=(244, 114, 182),
            interaction='tap_window',
        ),
        PromoSegment(
            eyebrow='Pointer ready',
            headline='Mouse + keyboard for full TUIs.',
            body='Drive terminal UIs with a real pointer and physical keys, '
            'not just taps.',
            label='Pointer support',
            accent=(129, 140, 248),
            interaction='pointer',
        ),
        PromoSegment(
            eyebrow='Rich clipboard',
            headline='Paste images and context.',
            body='Drop screenshots and snippets straight into your remote '
            'agent workflow.',
            label='Image paste',
            accent=(45, 212, 191),
            interaction='image_paste',
        ),
        PromoSegment(
            eyebrow='Any agent',
            headline='Switch to Claude and keep going.',
            body='Jump from Copilot to Claude or Codex with the whole session '
            'intact.',
            label='Claude',
            accent=(34, 211, 238),
            interaction='tap_input',
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
        'Run coding agents over SSH, from anywhere',
        font=tagline_font,
        fill=(208, 213, 221),
    )

    screen_x = layout['screen_x']
    screen_y = layout['screen_y']
    screen_width = layout['screen_width']
    screen_height = layout['screen_height']

    halo = Image.new('RGBA', image.size, (0, 0, 0, 0))
    halo_draw = ImageDraw.Draw(halo)
    halo_draw.rounded_rectangle(
        [
            screen_x - 70,
            screen_y - 70,
            screen_x + screen_width + 70,
            screen_y + screen_height + 70,
        ],
        radius=120,
        outline=(0, 201, 255, 90),
        width=26,
    )
    image = Image.alpha_composite(
        image,
        halo.filter(ImageFilter.GaussianBlur(radius=60)),
    )

    shadow = Image.new('RGBA', image.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    frame_rect = [
        screen_x - 18,
        screen_y - 18,
        screen_x + screen_width + 18,
        screen_y + screen_height + 18,
    ]
    shadow_draw.rounded_rectangle(frame_rect, radius=48, fill=(0, 0, 0, 170))
    image = Image.alpha_composite(
        image,
        shadow.filter(ImageFilter.GaussianBlur(radius=26)),
    )
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle(
        frame_rect,
        radius=48,
        outline=(255, 255, 255, 80),
        width=4,
        fill=(5, 8, 22, 255),
    )

    return image


def _draw_timeline(
    frame: Image.Image,
    t: float,
    segments: list[PromoSegment],
    seg_dur: float,
    duration: float,
    margin: int,
    width: int,
    height: int,
    fonts: dict[str, ImageFont.ImageFont],
) -> None:
    draw = ImageDraw.Draw(frame)
    count = len(segments)
    seg_index = min(int(t / seg_dur), count - 1)
    accent = segments[seg_index].accent

    track_y = int(height * 0.955)
    x0 = margin
    x1 = width - margin
    draw.rounded_rectangle(
        [x0, track_y - 3, x1, track_y + 3],
        radius=3,
        fill=(255, 255, 255, 40),
    )
    progress = _clamp01(t / duration) if duration > 0 else 0.0
    fill_x = int(x0 + (x1 - x0) * progress)
    draw.rounded_rectangle(
        [x0, track_y - 3, fill_x, track_y + 3],
        radius=3,
        fill=(*accent, 235),
    )

    for index, segment in enumerate(segments):
        cx = int(x0 + (x1 - x0) * (index + 0.5) / count)
        if index < seg_index:
            node_r = 9
            color = (*segment.accent, 235)
        elif index == seg_index:
            pulse = 0.5 + 0.5 * math.sin(2 * math.pi * t / 1.3)
            node_r = int(13 + 3 * pulse)
            ring_r = node_r + 8
            draw.ellipse(
                [cx - ring_r, track_y - ring_r, cx + ring_r, track_y + ring_r],
                outline=(*segment.accent, 180),
                width=3,
            )
            color = (*_lighten(segment.accent), 255)
        else:
            node_r = 8
            color = (255, 255, 255, 70)
        draw.ellipse(
            [cx - node_r, track_y - node_r, cx + node_r, track_y + node_r],
            fill=color,
        )

    label = segments[seg_index].label
    label_font = fonts['label']
    label_w = _text_w(draw, label, label_font)
    label_h = _text_h(draw, label, label_font)
    label_y = track_y - int(height * 0.028) - label_h
    draw.text(
        ((width - label_w) // 2, label_y),
        label,
        font=label_font,
        fill=(*_lighten(accent), 255),
    )


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


def _suppress_android_error_dialogs(device_id: str):
    """Disable system ANR/crash dialogs for the duration of a recording.

    Returns a callable that restores the previous values. Pixel Launcher ANR
    popups are the main offender on a busy headless emulator; hiding error
    dialogs system-wide is far more reliable than racing to dismiss them.
    """
    adb = store_screenshots._adb_path()
    previous = _android_global_setting(adb, device_id, 'hide_error_dialogs')
    _put_android_global_setting(adb, device_id, 'hide_error_dialogs', '1')

    def restore() -> None:
        target = previous if previous in ('0', '1') else '0'
        _put_android_global_setting(adb, device_id, 'hide_error_dialogs', target)

    return restore


def _android_global_setting(adb: Path, device_id: str, key: str) -> str | None:
    try:
        result = subprocess.run(
            [str(adb), '-s', device_id, 'shell', 'settings', 'get', 'global', key],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = result.stdout.strip()
    return value if value and value != 'null' else None


def _put_android_global_setting(
    adb: Path,
    device_id: str,
    key: str,
    value: str,
) -> None:
    subprocess.run(
        [str(adb), '-s', device_id, 'shell', 'settings', 'put', 'global', key, value],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


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
