#!/usr/bin/env python3

from __future__ import annotations

import argparse
import platform
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SCREENSHOT_COUNT = 6
IOS_SCREENSHOTS = {
    ROOT / 'ios/fastlane/screenshots/en-US': {
        'iphone_6_9': (1320, 2868),
        'ipad_13': (2064, 2752),
    },
}
ANDROID_SCREENSHOTS = {
    'phoneScreenshots': (1440, 2560),
    'sevenInchScreenshots': (1200, 1920),
    'tenInchScreenshots': (1600, 2560),
}
BAD_OCR_PATTERNS = {
    'splash screen': re.compile(r'MonkeySSH\s*[βB]\s+SSH Terminal', re.IGNORECASE),
    'old prompt transcript': re.compile(
        r'Next two checks|release[- ]readiness|64 concise|sign[- ]off',
        re.IGNORECASE,
    ),
    'old AGENTS text scene': re.compile(
        r'Do not show emails|store-demo agents %|shared agent instructions',
        re.IGNORECASE,
    ),
    'notification prompt': re.compile(
        r'Would Like to Send You Notifications|Notifications may include',
        re.IGNORECASE,
    ),
    'private local path': re.compile(r'/Users/depoll|/private/var/folders', re.IGNORECASE),
    'disabled streamer mode': re.compile(r'Streamer mode disabled', re.IGNORECASE),
    'visible API key': re.compile(r'ANTHROPIC_API_KEY|sk-ant-', re.IGNORECASE),
    'Claude account banner': re.compile(
        r'Account\s+(?:settings|details|email|plan|billing)',
        re.IGNORECASE,
    ),
    'Claude plan-mode footer': re.compile(r'plan mode on', re.IGNORECASE),
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


def _ocr_texts(paths: list[Path]) -> dict[Path, str]:
    if platform.system() != 'Darwin' or shutil.which('swift') is None:
        raise RuntimeError(
            'OCR screenshot validation requires macOS with Swift/Vision. '
            'Run this validator on a macOS runner before syncing metadata.',
        )

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
                check=True,
                stdout=subprocess.PIPE,
                text=True,
            )

    texts: dict[Path, str] = {}
    for block in result.stdout.split('END_FILE'):
        lines = [line for line in block.strip().splitlines() if line]
        if not lines or not lines[0].startswith('FILE\t'):
            continue
        path = Path(lines[0].split('\t', 1)[1])
        texts[path] = ' '.join(lines[1:])
    return texts


def _validate_ocr_content(paths: list[Path]) -> None:
    texts = _ocr_texts(paths)
    missing_paths = [path for path in paths if path not in texts]
    if missing_paths:
        formatted_paths = ', '.join(
            str(path.relative_to(ROOT)) for path in missing_paths
        )
        raise ValueError(f'OCR did not return text for {formatted_paths}.')

    for path, text in texts.items():
        for label, pattern in BAD_OCR_PATTERNS.items():
            if pattern.search(text):
                raise ValueError(
                    f'{path.relative_to(ROOT)} appears to contain {label}; '
                    'regenerate store-quality screenshots before syncing metadata',
                )

    for path, text in texts.items():
        filename = path.name
        if filename in {'01_iphone_6_9.png', '01_ipad_13.png', '1.png'}:
            _require_ocr_markers(path, text, ['GitHub Copilot'])
        elif filename in {'02_iphone_6_9.png', '02_ipad_13.png', '2.png'}:
            _require_ocr_markers(path, text, ['Hosts', 'New Host'])
        elif filename in {'03_iphone_6_9.png', '03_ipad_13.png', '3.png'}:
            _require_ocr_markers(path, text, ['Snippets'])
        elif filename in {'04_iphone_6_9.png', '04_ipad_13.png', '4.png'}:
            _require_ocr_markers(path, text, ['copilot', 'gemini', 'claude', 'codex'])
        elif filename in {'05_iphone_6_9.png', '05_ipad_13.png', '5.png'}:
            _require_ocr_markers(path, text, ['AGENTS.md'])
        elif filename in {'06_iphone_6_9.png', '06_ipad_13.png', '6.png'}:
            _require_ocr_markers(path, text, ['Claude Code'])


def _require_ocr_markers(path: Path, text: str, markers: list[str]) -> None:
    normalized_text = text.casefold()
    missing = [
        marker for marker in markers if marker.casefold() not in normalized_text
    ]
    if missing:
        raise ValueError(
            f'{path.relative_to(ROOT)} is missing expected store screenshot '
            f'content: {", ".join(missing)}',
        )


def _validate_ios() -> None:
    paths = []
    for locale_dir, devices in IOS_SCREENSHOTS.items():
        for index in range(1, SCREENSHOT_COUNT + 1):
            for device_name, expected_size in devices.items():
                path = locale_dir / f'{index:02d}_{device_name}.png'
                _validate_file(path, expected_size)
                paths.append(path)
    _validate_ocr_content(paths)


def _validate_android() -> None:
    paths = []
    for variant in ('production', 'private'):
        images_dir = ROOT / f'android/fastlane/metadata-{variant}/android/en-US/images'
        for screenshot_dir, expected_size in ANDROID_SCREENSHOTS.items():
            for index in range(1, SCREENSHOT_COUNT + 1):
                path = images_dir / screenshot_dir / f'{index}.png'
                _validate_file(path, expected_size)
                paths.append(path)
    _validate_ocr_content(paths)


def main() -> None:
    args = _parse_args()
    if args.platform in ('ios', 'both'):
        _validate_ios()
    if args.platform in ('android', 'both'):
        _validate_android()


if __name__ == '__main__':
    main()
