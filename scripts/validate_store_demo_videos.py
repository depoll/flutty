#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import platform
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIR = ROOT / 'build/store-demo-videos'
IOS_APP_PREVIEW_DIR = ROOT / 'ios/fastlane/app-previews/en-US'


@dataclass(frozen=True)
class VideoTarget:
    platform: str
    relative_path: Path
    size: tuple[int, int]


DEFAULT_TARGETS = {
    'ios': VideoTarget(
        platform='ios',
        relative_path=Path('ios/monkeyssh-ios-demo.mov'),
        size=(1320, 2868),
    ),
    'android': VideoTarget(
        platform='android',
        relative_path=Path('android/monkeyssh-android-demo.mp4'),
        size=(1440, 2560),
    ),
}
IOS_APP_PREVIEW_TARGET = VideoTarget(
    platform='ios',
    relative_path=Path('iphone_67_1.mov'),
    size=(1320, 2868),
)


@dataclass(frozen=True)
class VideoInfo:
    width: int
    height: int
    duration: float


def main() -> None:
    args = _parse_args()
    targets = _targets_for_platform(args.platform, args.ios_app_previews)
    root = IOS_APP_PREVIEW_DIR if args.ios_app_previews else Path(args.output_dir)
    root = root.expanduser().resolve()

    paths = [root / target.relative_path for target in targets]
    for path in paths:
        if not path.exists():
            raise FileNotFoundError(f'Missing demo video: {path}')
    infos = _probe_videos(paths)
    for target, path in zip(targets, paths, strict=True):
        _validate_video(
            path=path,
            expected_size=target.size,
            min_duration=args.min_duration,
            max_duration=args.max_duration,
            info=infos[path],
        )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Validate generated MonkeySSH store demo videos.',
    )
    parser.add_argument(
        'platform',
        choices=['ios', 'android', 'both'],
        nargs='?',
        default='both',
        help='Which generated demo video to validate.',
    )
    parser.add_argument(
        '--output-dir',
        default=str(DEFAULT_OUTPUT_DIR),
        help='Directory containing generated videos. Defaults to build/store-demo-videos.',
    )
    parser.add_argument(
        '--ios-app-previews',
        action='store_true',
        help='Validate committed iOS App Preview videos under ios/fastlane/app-previews.',
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


def _targets_for_platform(
    selected_platform: str,
    ios_app_previews: bool,
) -> list[VideoTarget]:
    if ios_app_previews:
        if selected_platform == 'android':
            raise ValueError('--ios-app-previews can only validate iOS videos')
        return [IOS_APP_PREVIEW_TARGET]
    if selected_platform == 'ios':
        return [DEFAULT_TARGETS['ios']]
    if selected_platform == 'android':
        return [DEFAULT_TARGETS['android']]
    return [DEFAULT_TARGETS['ios'], DEFAULT_TARGETS['android']]


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
