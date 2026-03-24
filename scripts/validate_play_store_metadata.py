#!/usr/bin/env python3

from __future__ import annotations

import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
METADATA_DIRS = {
    'production': ROOT / 'android/fastlane/metadata-production/android',
    'private': ROOT / 'android/fastlane/metadata-private/android',
}
TEXT_LIMITS = {
    'title.txt': 30,
    'short_description.txt': 80,
    'full_description.txt': 4000,
}


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description='Validate Android Play Store metadata length limits.',
    )
    parser.add_argument(
        'variant',
        choices=['production', 'private', 'both'],
        nargs='?',
        default='both',
        help='Which app metadata set to validate.',
    )
    return parser.parse_args()


def _validate_locale(variant: str, locale_dir: Path) -> None:
    for file_name, max_length in TEXT_LIMITS.items():
        file_path = locale_dir / file_name
        if not file_path.exists():
            raise FileNotFoundError(f'Missing metadata file for {variant}: {file_path}')

        raw_value = file_path.read_text(encoding='utf-8')
        value = raw_value.rstrip('\r\n')
        if not value.strip():
            raise ValueError(f'{file_path.relative_to(ROOT)} must not be empty')

        length = len(value)
        if length > max_length:
            raise ValueError(
                f'{file_path.relative_to(ROOT)} is {length} characters long; '
                f'Google Play allows at most {max_length}',
            )

        print(
            f'Validated {file_path.relative_to(ROOT)} '
            f'({length}/{max_length} characters)',
        )


def _validate_variant(variant: str) -> None:
    metadata_dir = METADATA_DIRS[variant]
    if not metadata_dir.exists():
        raise FileNotFoundError(f'Missing metadata directory for {variant}: {metadata_dir}')

    locale_dirs = sorted(path for path in metadata_dir.iterdir() if path.is_dir())
    if not locale_dirs:
        raise FileNotFoundError(
            f'Missing locale directories for {variant}: expected at least one under {metadata_dir}',
        )

    for locale_dir in locale_dirs:
        _validate_locale(variant, locale_dir)


def main() -> None:
    args = _parse_args()
    variants = METADATA_DIRS.keys() if args.variant == 'both' else (args.variant,)
    for variant in variants:
        _validate_variant(variant)


if __name__ == '__main__':
    main()
