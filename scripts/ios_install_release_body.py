#!/usr/bin/env python3
"""Render the release body for one ad hoc iOS build.

The body carries a machine-readable block so
``scripts/generate_ios_install_site.py`` can rebuild every install page from a
single paginated releases API call, without downloading any assets.
"""

from __future__ import annotations

import json
import os

METADATA_BEGIN = '<!-- ios-install-metadata'
METADATA_END = '-->'

FIELDS = (
    'slug',
    'tag',
    'title',
    'subtitle',
    'bundle_id',
    'build_name',
    'build_number',
    'flavor',
    'source_sha',
    'ipa_asset',
    'run_url',
    'pr_number',
)


def parse_metadata(body: str) -> dict[str, str] | None:
    """Recover the metadata block from a release body, or None if absent."""
    start = body.find(METADATA_BEGIN)
    if start == -1:
        return None
    start += len(METADATA_BEGIN)
    end = body.find(METADATA_END, start)
    if end == -1:
        return None
    try:
        parsed = json.loads(body[start:end])
    except json.JSONDecodeError:
        return None
    return parsed if isinstance(parsed, dict) else None


def main() -> None:
    metadata = {field: os.environ.get(field.upper(), '') for field in FIELDS}
    repo_slug = os.environ['REPO_SLUG']
    sha = metadata['source_sha']

    lines = [
        f"Ad hoc signed iOS build of `{metadata['bundle_id']}`, published by CI "
        'for over-the-air installs.',
        '',
        f"- Version `{metadata['build_name']}` (build `{metadata['build_number']}`)",
        f"- Commit [`{sha[:7]}`](https://github.com/{repo_slug}/commit/{sha})",
    ]
    if metadata['pr_number']:
        lines.append(
            f"- Pull request [#{metadata['pr_number']}]"
            f"(https://github.com/{repo_slug}/pull/{metadata['pr_number']})"
        )
    if metadata['run_url']:
        lines.append(f"- Built by [workflow run]({metadata['run_url']})")
    lines += [
        '',
        'Only devices registered in the MonkeySSH Apple Developer account can run '
        'this build. Install it from the linked install page in Safari rather than '
        'downloading the IPA directly.',
        '',
        'Deleting this release retires the build and removes its install page on the '
        'next site publish.',
        '',
        METADATA_BEGIN,
        json.dumps(metadata, indent=2, sort_keys=True),
        METADATA_END,
    ]
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
