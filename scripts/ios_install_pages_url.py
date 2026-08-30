#!/usr/bin/env python3
"""Print the base URL GitHub Pages serves this repository from."""

from __future__ import annotations

import os


def pages_base_url(repo_slug: str, override: str = '') -> str:
    if override:
        return override.rstrip('/')
    owner, _, name = repo_slug.partition('/')
    owner = owner.lower()
    if name.lower() == f'{owner}.github.io':
        return f'https://{name.lower()}'
    return f'https://{owner}.github.io/{name}'


if __name__ == '__main__':
    print(
        pages_base_url(
            os.environ['REPO_SLUG'],
            os.environ.get('IOS_INSTALL_PAGES_BASE_URL', ''),
        )
    )
