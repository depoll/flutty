#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SCREENSHOT_COUNT = 5
IOS_SCREENSHOTS = {
    ROOT / 'ios/fastlane/screenshots/en-US': {
        'iphone_6_9': (1320, 2868),
        'ipad_13': (2064, 2752),
    },
}
ANDROID_SCREENSHOTS = {
    'phoneScreenshots': (1080, 1920),
    'sevenInchScreenshots': (1200, 1920),
    'tenInchScreenshots': (1600, 2560),
}


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Validate generated store screenshot counts and dimensions.',
    )
    parser.add_argument(
        'platform',
        choices=['ios', 'android', 'both'],
        nargs='?',
        default='both',
        help='Which store screenshot set to validate.',
    )
    return parser.parse_args()


def _image_size(path: Path) -> tuple[int, int]:
    if not path.exists():
        raise FileNotFoundError(f'Missing screenshot: {path}')

    with Image.open(path) as image:
        return image.size


def _validate_file(path: Path, expected_size: tuple[int, int]) -> None:
    actual_size = _image_size(path)
    if actual_size != expected_size:
        raise ValueError(
            f'{path.relative_to(ROOT)} is {actual_size[0]}x{actual_size[1]}; '
            f'expected {expected_size[0]}x{expected_size[1]}',
        )
    if path.stat().st_size < 10_000:
        raise ValueError(
            f'{path.relative_to(ROOT)} is unexpectedly small; '
            'regenerate real app screenshots before syncing metadata',
        )

    print(
        f'Validated {path.relative_to(ROOT)} '
        f'({actual_size[0]}x{actual_size[1]})',
    )


def _validate_ios() -> None:
    for locale_dir, devices in IOS_SCREENSHOTS.items():
        for index in range(1, SCREENSHOT_COUNT + 1):
            for device_name, expected_size in devices.items():
                _validate_file(locale_dir / f'{index:02d}_{device_name}.png', expected_size)


def _validate_android() -> None:
    for variant in ('production', 'private'):
        images_dir = ROOT / f'android/fastlane/metadata-{variant}/android/en-US/images'
        for screenshot_dir, expected_size in ANDROID_SCREENSHOTS.items():
            for index in range(1, SCREENSHOT_COUNT + 1):
                _validate_file(images_dir / screenshot_dir / f'{index}.png', expected_size)


def main() -> None:
    args = _parse_args()
    if args.platform in ('ios', 'both'):
        _validate_ios()
    if args.platform in ('android', 'both'):
        _validate_android()


if __name__ == '__main__':
    main()
