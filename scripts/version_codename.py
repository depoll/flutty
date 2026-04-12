#!/usr/bin/env python3

from __future__ import annotations

import json
import pathlib
import sys


def parse_major(version: str) -> int | None:
    value = version.strip()
    if not value:
        return None

    major_segment = value.split('.', 1)[0].strip()
    if not major_segment:
        return None

    try:
        return int(major_segment)
    except ValueError:
        return None


def load_mapping() -> dict[int, str]:
    mapping_path = pathlib.Path(__file__).resolve().parent.parent / 'assets' / 'version_codenames.json'
    payload = json.loads(mapping_path.read_text(encoding='utf-8'))
    result: dict[int, str] = {}

    for entry in payload.get('codenames', []):
        if not isinstance(entry, dict):
            continue

        major = entry.get('major')
        name = entry.get('name')
        if isinstance(major, int) and isinstance(name, str) and name.strip():
            result[major] = name.strip()

    return result


def main() -> int:
    if len(sys.argv) != 2:
        print('usage: version_codename.py <version>', file=sys.stderr)
        return 1

    major = parse_major(sys.argv[1])
    if major is None:
        return 0

    codename = load_mapping().get(major)
    if codename:
        print(codename)

    return 0


if __name__ == '__main__':
    raise SystemExit(main())
