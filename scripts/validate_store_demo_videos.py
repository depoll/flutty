#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import platform
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BAD_VIDEO_OCR_PATTERNS = {
    'Android system error dialog': re.compile(
        r"Pixel Launcher|isn[’']t responding|not responding|Close app",
        re.IGNORECASE,
    ),
    'private local path': re.compile(r'/Users/depoll|/private/var/folders', re.IGNORECASE),
    'visible API key': re.compile(r'ANTHROPIC_API_KEY|sk-ant-', re.IGNORECASE),
}


@dataclass(frozen=True)
class VideoTarget:
    name: str
    platform: str
    rel_path: str
    size: tuple[int, int]
    live_crop: str
    slot: str
    requires_audio: bool = False
    animated_bg: bool = True


# Crop expressions isolating the live app region for motion/progression checks.
_APP_PREVIEW_CROP = 'crop=iw*0.62:ih*0.40:iw*0.19:ih*0.30'
_PORTRAIT_ADS_CROP = 'crop=iw*0.58:ih*0.46:iw*0.21:ih*0.31'
_LANDSCAPE_CROP = 'crop=iw*0.20:ih*0.62:iw*0.066:ih*0.19'

TARGETS = [
    VideoTarget(
        name='iphone_app_preview',
        platform='ios',
        rel_path='ios/fastlane/app-previews/en-US/iphone_67_1.mov',
        size=(886, 1920),
        live_crop=_APP_PREVIEW_CROP,
        slot='App Store iPhone 6.9" app preview',
        requires_audio=True,
        animated_bg=False,
    ),
    VideoTarget(
        name='ipad_app_preview',
        platform='ios',
        rel_path='ios/fastlane/app-previews/en-US/ipad_13_1.mov',
        size=(1200, 1600),
        live_crop=_APP_PREVIEW_CROP,
        slot='App Store iPad 13" app preview',
        requires_audio=True,
        animated_bg=False,
    ),
    VideoTarget(
        name='google_play_promo',
        platform='android',
        rel_path='store/demo-videos/google-play/monkeyssh-google-play-promo.mp4',
        size=(1920, 1080),
        live_crop=_LANDSCAPE_CROP,
        slot='Google Play landscape promo (YouTube)',
    ),
    VideoTarget(
        name='ios_ads',
        platform='ios',
        rel_path='store/demo-videos/ads/monkeyssh-ios-ads.mp4',
        size=(1320, 2868),
        live_crop=_PORTRAIT_ADS_CROP,
        slot='iOS portrait ad/marketing',
    ),
    VideoTarget(
        name='android_ads',
        platform='android',
        rel_path='store/demo-videos/ads/monkeyssh-android-ads.mp4',
        size=(1440, 2560),
        live_crop=_PORTRAIT_ADS_CROP,
        slot='Android portrait ad/marketing',
    ),
]


@dataclass(frozen=True)
class VideoInfo:
    width: int
    height: int
    duration: float


def main() -> None:
    args = _parse_args()
    targets = _filter_targets(args.platform)
    paths = [ROOT / target.rel_path for target in targets]
    for path in paths:
        if not path.exists():
            raise FileNotFoundError(f'Missing demo video: {path}')
    infos = _probe_videos(paths)
    for index, target in enumerate(targets):
        path = paths[index]
        _validate_video(
            path=path,
            expected_size=target.size,
            min_duration=args.min_duration,
            max_duration=args.max_duration,
            info=infos[path],
        )
        if target.requires_audio:
            _validate_audio_track(path, target.slot)
        _validate_dynamics(path, check_freeze=target.animated_bg)
        _validate_live_region_motion(path, crop=target.live_crop)
        _validate_live_region_progression(path, crop=target.live_crop)
    _validate_sampled_ocr_content(paths)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Validate generated MonkeySSH store demo videos.',
    )
    parser.add_argument(
        'platform',
        choices=['ios', 'android', 'all'],
        nargs='?',
        default='all',
        help='Which slots to validate (default: all store + ads outputs).',
    )
    parser.add_argument(
        '--min-duration',
        type=float,
        default=15,
        help='Minimum acceptable duration in seconds.',
    )
    parser.add_argument(
        '--max-duration',
        type=float,
        default=30,
        help='Maximum acceptable duration in seconds.',
    )
    return parser.parse_args()


def _filter_targets(platform: str) -> list[VideoTarget]:
    if platform == 'all':
        return TARGETS
    return [target for target in TARGETS if target.platform == platform]


def _validate_video(
    *,
    path: Path,
    expected_size: tuple[int, int],
    min_duration: float,
    max_duration: float,
    info: VideoInfo,
) -> None:
    if not path.exists():
        raise FileNotFoundError(f'Missing demo video: {path}')
    if path.stat().st_size < 500_000:
        raise ValueError(f'{_display_path(path)} is too small for a real recording')
    actual_size = (info.width, info.height)
    if actual_size != expected_size:
        raise ValueError(
            f'{_display_path(path)} is {info.width}x{info.height}; '
            f'expected {expected_size[0]}x{expected_size[1]}',
        )
    if info.duration < min_duration or info.duration > max_duration:
        raise ValueError(
            f'{_display_path(path)} is {info.duration:.1f}s; '
            f'expected {min_duration:.1f}-{max_duration:.1f}s',
        )
    print(
        f'Validated {_display_path(path)} '
        f'({info.width}x{info.height}, {info.duration:.1f}s)',
    )


def _probe_videos(paths: list[Path]) -> dict[Path, VideoInfo]:
    if ffprobe := shutil.which('ffprobe'):
        return _probe_videos_with_ffprobe(ffprobe, paths)
    if platform.system() == 'Darwin' and shutil.which('swift') is not None:
        return _probe_videos_with_avfoundation(paths)
    raise RuntimeError(
        'Video validation requires ffprobe or macOS with Swift/AVFoundation.',
    )


def _validate_audio_track(path: Path, slot: str) -> None:
    ffprobe = shutil.which('ffprobe')
    if ffprobe is None:
        print('Skipping audio-track validation; requires ffprobe.')
        return
    result = subprocess.run(
        [
            ffprobe,
            '-v',
            'error',
            '-select_streams',
            'a',
            '-show_entries',
            'stream=codec_name',
            '-of',
            'default=noprint_wrappers=1:nokey=1',
            str(path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    if not result.stdout.strip():
        raise ValueError(
            f'{_display_path(path)} ({slot}) has no audio track; App Store app '
            'previews require an audio track — regenerate the preview',
        )
    print(f'Validated audio track for {_display_path(path)} ({result.stdout.strip()})')


def _validate_dynamics(path: Path, *, check_freeze: bool) -> None:
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg is None:
        print('Skipping motion/black validation; requires ffmpeg.')
        return
    result = subprocess.run(
        [
            ffmpeg,
            '-hide_banner',
            '-nostats',
            '-i',
            str(path),
            '-vf',
            'blackdetect=d=0.4:pic_th=0.98,freezedetect=n=0.003:d=2.0',
            '-an',
            '-f',
            'null',
            '-',
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    stderr = result.stderr
    black_total = sum(
        float(value)
        for value in re.findall(r'black_duration:(\d+(?:\.\d+)?)', stderr)
    )
    if black_total > 1.0:
        raise ValueError(
            f'{_display_path(path)} contains {black_total:.1f}s of near-black '
            'frames; the screen capture likely failed — regenerate the demo video',
        )
    # The branded outputs always animate their backdrop, so a whole-frame freeze
    # means the promo animation is missing. Native app previews are intentionally
    # just the app (no animated backdrop) and hold still during scene reads, so
    # the freeze gate is skipped for them; their motion is covered by the
    # live-region progression check instead.
    if check_freeze and 'freeze_start' in stderr:
        raise ValueError(
            f'{_display_path(path)} contains a frozen/static segment of 2s or '
            'more; the promotional animation is missing — regenerate the demo video',
        )
    print(f'Validated motion for {_display_path(path)} (no black or frozen segments)')


def _validate_live_region_motion(path: Path, *, crop: str) -> None:
    """Ensure the embedded live app capture actually moves over time."""
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg is None:
        print('Skipping live-region motion validation; requires ffmpeg.')
        return
    max_frozen_fraction = 0.97
    duration = _video_duration(path)
    if duration <= 0:
        return
    result = subprocess.run(
        [
            ffmpeg,
            '-hide_banner',
            '-nostats',
            '-i',
            str(path),
            '-vf',
            f'{crop},freezedetect=n=0.003:d=1.0',
            '-an',
            '-f',
            'null',
            '-',
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    frozen = sum(
        float(value)
        for value in re.findall(
            r'freeze_duration:\s*(\d+(?:\.\d+)?)',
            result.stderr,
        )
    )
    fraction = frozen / duration
    if fraction > max_frozen_fraction:
        raise ValueError(
            f'{_display_path(path)} live app region is frozen '
            f'{fraction * 100:.0f}% of the time; the device capture likely '
            'failed or stalled — regenerate the demo video',
        )
    print(
        f'Validated live app motion for {_display_path(path)} '
        f'(live region frozen {fraction * 100:.0f}% of the time)',
    )


def _validate_live_region_progression(path: Path, *, crop: str) -> None:
    """Ensure the live app capture advances through several distinct screens.

    The frozen-fraction check above is defeated by a blinking cursor or spinner
    that registers as motion while the screen is structurally stalled on one
    scene (exactly how an earlier broken iOS capture slipped through). This
    counts substantial scene changes inside the cropped device region: a real
    walkthrough visits five screens and trips many scene changes, while a
    stalled or blank capture barely changes at all.
    """
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg is None:
        print('Skipping live-region progression validation; requires ffmpeg.')
        return
    min_scene_changes = 4
    result = subprocess.run(
        [
            ffmpeg,
            '-hide_banner',
            '-nostats',
            '-i',
            str(path),
            '-vf',
            f"{crop},select='gt(scene,0.10)',metadata=print",
            '-an',
            '-f',
            'null',
            '-',
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    scene_changes = len(re.findall(r'scene_score', result.stderr))
    if scene_changes < min_scene_changes:
        raise ValueError(
            f'{_display_path(path)} live app region only changes '
            f'{scene_changes} time(s); the device capture likely stalled on '
            'a single screen — regenerate the demo video',
        )
    print(
        f'Validated live app progression for {_display_path(path)} '
        f'({scene_changes} scene changes)',
    )


def _validate_sampled_ocr_content(paths: list[Path]) -> None:
    ffmpeg = shutil.which('ffmpeg')
    if platform.system() != 'Darwin' or shutil.which('swift') is None or ffmpeg is None:
        print('Skipping video OCR validation; requires macOS, Swift, and ffmpeg.')
        return

    with tempfile.TemporaryDirectory(prefix='monkeyssh-demo-video-ocr-') as tmpdir:
        frame_paths: list[Path] = []
        tmpdir_path = Path(tmpdir)
        for video_path in paths:
            duration = _video_duration(video_path)
            for index, timestamp in enumerate(_sample_times(duration)):
                frame_path = tmpdir_path / f'{video_path.stem}-{index}.png'
                subprocess.run(
                    [
                        ffmpeg,
                        '-y',
                        '-loglevel',
                        'error',
                        '-ss',
                        f'{timestamp:.3f}',
                        '-i',
                        str(video_path),
                        '-frames:v',
                        '1',
                        str(frame_path),
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=True,
                )
                frame_paths.append(frame_path)

        texts = _ocr_texts(frame_paths)
        for frame_path, text in texts.items():
            for label, pattern in BAD_VIDEO_OCR_PATTERNS.items():
                if pattern.search(text):
                    raise ValueError(
                        f'{frame_path.name} appears to contain {label}; '
                        'regenerate store-quality demo videos before syncing assets',
                    )


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


def _sample_times(duration: float) -> list[float]:
    if duration <= 4:
        return [max(duration / 2, 0)]
    return [
        min(max(1.0, duration * ratio), max(duration - 0.5, 0))
        for ratio in (0.1, 0.25, 0.42, 0.58, 0.75, 0.9)
    ]


def _ocr_texts(paths: list[Path]) -> dict[Path, str]:
    swift_source = r'''
import Foundation
import Vision
import AppKit

let listPath = CommandLine.arguments[1]
let contents = try String(contentsOfFile: listPath, encoding: .utf8)
let urls = contents.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US"]

for url in urls {
    guard let image = NSImage(contentsOf: url),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let cgImage = bitmap.cgImage else {
        print("FILE\t\(url.path)\tERROR\tCould not load image")
        continue
    }
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])
    let text = (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
        .replacingOccurrences(of: "\n", with: " ")
    print("FILE\t\(url.path)")
    print(text)
    print("END_FILE")
}
'''
    with tempfile.NamedTemporaryFile('w', suffix='.swift') as script:
        with tempfile.NamedTemporaryFile('w') as file_list:
            script.write(swift_source)
            script.flush()
            file_list.write('\n'.join(str(path) for path in paths))
            file_list.flush()
            result = subprocess.run(
                ['swift', script.name, file_list.name],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=True,
            )

    texts: dict[Path, str] = {}
    for block in result.stdout.split('END_FILE'):
        lines = [line for line in block.strip().splitlines() if line]
        if not lines or not lines[0].startswith('FILE\t'):
            continue
        path = Path(lines[0].split('\t', 1)[1])
        texts[path] = ' '.join(lines[1:])
    return texts


def _probe_videos_with_ffprobe(
    ffprobe: str,
    paths: list[Path],
) -> dict[Path, VideoInfo]:
    infos: dict[Path, VideoInfo] = {}
    for path in paths:
        result = subprocess.run(
            [
                ffprobe,
                '-v',
                'error',
                '-select_streams',
                'v:0',
                '-show_entries',
                'stream=width,height,duration:format=duration',
                '-of',
                'json',
                str(path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        )
        payload = json.loads(result.stdout)
        streams = payload.get('streams')
        if not streams:
            raise ValueError(f'{_display_path(path)} does not contain a video stream')
        stream = streams[0]
        duration = _float_or_none(stream.get('duration'))
        if duration is None:
            duration = _float_or_none(payload.get('format', {}).get('duration'))
        if duration is None:
            raise ValueError(f'Could not read duration for {_display_path(path)}')
        infos[path] = VideoInfo(
            width=int(stream['width']),
            height=int(stream['height']),
            duration=duration,
        )
    return infos


def _probe_videos_with_avfoundation(paths: list[Path]) -> dict[Path, VideoInfo]:
    swift_source = r'''
import AVFoundation
import Foundation

let listPath = CommandLine.arguments[1]
let contents = try String(contentsOfFile: listPath, encoding: .utf8)
let paths = contents.split(separator: "\n").map { String($0) }

for path in paths {
    let url = URL(fileURLWithPath: path)
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else {
        print("FILE\t\(path)\tERROR\tmissing video track")
        continue
    }
    let transformedSize = track.naturalSize.applying(track.preferredTransform)
    let width = Int(abs(transformedSize.width).rounded())
    let height = Int(abs(transformedSize.height).rounded())
    let duration = CMTimeGetSeconds(asset.duration)
    print("FILE\t\(path)\t\(width)\t\(height)\t\(duration)")
}
'''
    with tempfile.NamedTemporaryFile('w', suffix='.swift') as script:
        with tempfile.NamedTemporaryFile('w') as file_list:
            script.write(swift_source)
            script.flush()
            file_list.write('\n'.join(str(path) for path in paths))
            file_list.flush()
            result = subprocess.run(
                ['swift', script.name, file_list.name],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=True,
            )

    infos: dict[Path, VideoInfo] = {}
    for line in result.stdout.splitlines():
        parts = line.split('\t')
        if len(parts) < 3 or parts[0] != 'FILE':
            continue
        path = Path(parts[1])
        if len(parts) >= 4 and parts[2] == 'ERROR':
            raise ValueError(f'{_display_path(path)}: {parts[3]}')
        if len(parts) != 5:
            raise ValueError(f'Unexpected AVFoundation probe output: {line}')
        infos[path] = VideoInfo(
            width=int(parts[2]),
            height=int(parts[3]),
            duration=float(parts[4]),
        )

    missing_paths = [path for path in paths if path not in infos]
    if missing_paths:
        formatted_paths = ', '.join(_display_path(path) for path in missing_paths)
        raise ValueError(f'Video probe did not return metadata for {formatted_paths}')
    return infos


def _float_or_none(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (float, int)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _display_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


if __name__ == '__main__':
    main()
