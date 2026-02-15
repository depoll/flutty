#!/usr/bin/env python3

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ICON_SIZE = (512, 512)
RESAMPLING = getattr(Image, 'Resampling', Image).LANCZOS

ICON_VARIANTS = {
    'production': {
        'source': ROOT / 'assets/icons/monkeyssh_icon.png',
        'targets': [
            ROOT / 'android/fastlane/metadata-production/android/en-US/icon.png',
            ROOT / 'android/fastlane/metadata-production/android/en-US/images/icon.png',
        ],
    },
    'private': {
        'source': ROOT / 'assets/icons/monkeyssh_icon_private.png',
        'targets': [
            ROOT / 'android/fastlane/metadata-private/android/en-US/icon.png',
            ROOT / 'android/fastlane/metadata-private/android/en-US/images/icon.png',
        ],
    },
}


def _write_icon(source_path: Path, target_path: Path) -> None:
    target_path.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(source_path) as image:
        resized = image.convert('RGBA').resize(ICON_SIZE, RESAMPLING)
        resized.save(target_path, format='PNG', optimize=True)


def main() -> None:
    for variant, config in ICON_VARIANTS.items():
        source_path = config['source']
        if not source_path.exists():
            raise FileNotFoundError(f'Missing source icon for {variant}: {source_path}')

        for target_path in config['targets']:
            _write_icon(source_path, target_path)
            print(f'Updated {target_path.relative_to(ROOT)} from {source_path.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
