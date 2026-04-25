#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
METADATA_DIRS = {
    'production': ROOT / 'ios/fastlane/metadata-production',
    'private': ROOT / 'ios/fastlane/metadata-private',
}
TEXT_LIMITS = {
    'name.txt': 30,
    'subtitle.txt': 30,
    'keywords.txt': 100,
    'description.txt': 4000,
    'release_notes.txt': 4000,
}
ROOT_TEXT_LIMITS = {
    'primary_category.txt': 64,
    'copyright.txt': 64,
}


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Validate App Store metadata length limits.',
    )
    parser.add_argument(
        'variant',
        choices=['production', 'private', 'both'],
        nargs='?',
        default='both',
        help='Which app metadata set to validate.',
    )
    return parser.parse_args()


def _validate_text_file(file_path: Path, max_length: int) -> None:
    if not file_path.exists():
        raise FileNotFoundError(f'Missing metadata file: {file_path}')

    raw_value = file_path.read_text(encoding='utf-8')
    value = raw_value.rstrip('\r\n')
    if not value.strip():
        raise ValueError(f'{file_path.relative_to(ROOT)} must not be empty')

    length = len(value)
    if length > max_length:
        raise ValueError(
            f'{file_path.relative_to(ROOT)} is {length} characters long; '
            f'the App Store allows at most {max_length}',
        )

    print(
        f'Validated {file_path.relative_to(ROOT)} '
        f'({length}/{max_length} characters)',
    )


def _validate_variant(variant: str) -> None:
    metadata_dir = METADATA_DIRS[variant]
    locale_dir = metadata_dir / 'en-US'
    if not locale_dir.exists():
        raise FileNotFoundError(f'Missing locale directory for {variant}: {locale_dir}')

    for file_name, max_length in TEXT_LIMITS.items():
        _validate_text_file(locale_dir / file_name, max_length)

    for file_name, max_length in ROOT_TEXT_LIMITS.items():
        _validate_text_file(metadata_dir / file_name, max_length)


def main() -> None:
    args = _parse_args()
    variants = METADATA_DIRS.keys() if args.variant == 'both' else (args.variant,)
    for variant in variants:
        _validate_variant(variant)


if __name__ == '__main__':
    main()
