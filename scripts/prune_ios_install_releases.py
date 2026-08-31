#!/usr/bin/env python3
"""Delete `ios-install-pr-<n>` releases whose pull request is no longer open.

Runs before every site regeneration rather than only on the PR-closed event, so
a missed or failed cleanup still converges: a build's release, tag, IPA, and
install page all disappear once its PR is merged or closed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

PR_TAG = re.compile(r'^ios-install-pr-(\d+)$')


def gh_json(args: list[str]) -> object:
    raw = subprocess.run(['gh', *args], capture_output=True, text=True, check=True).stdout
    decoder = json.JSONDecoder()
    pages: list = []
    index = 0
    while index < len(raw):
        while index < len(raw) and raw[index].isspace():
            index += 1
        if index >= len(raw):
            break
        page, index = decoder.raw_decode(raw, index)
        pages.extend(page if isinstance(page, list) else [page])
    return pages


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', ''))
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()

    repo = args.repo
    if not repo:
        raise SystemExit('--repo or GITHUB_REPOSITORY is required')

    releases = gh_json(['api', f'/repos/{repo}/releases', '--paginate'])
    candidates = {}
    for release in releases:
        match = PR_TAG.match(release.get('tag_name', ''))
        if match:
            candidates[int(match.group(1))] = release['tag_name']

    if not candidates:
        print('No per-PR install releases to check.')
        return

    open_prs = {
        pr['number']
        for pr in gh_json(['api', f'/repos/{repo}/pulls?state=open&per_page=100', '--paginate'])
    }

    stale = sorted(number for number in candidates if number not in open_prs)
    if not stale:
        print(f'All {len(candidates)} per-PR install release(s) belong to open PRs.')
        return

    for number in stale:
        tag = candidates[number]
        print(f'Retiring {tag} (PR #{number} is no longer open)')
        if args.dry_run:
            continue
        result = subprocess.run(
            ['gh', 'release', 'delete', tag, '--repo', repo, '--cleanup-tag', '--yes'],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            # A concurrent run may have deleted it already; the next regeneration
            # re-checks either way.
            print(f'  warning: {result.stderr.strip()}', file=sys.stderr)


if __name__ == '__main__':
    main()
