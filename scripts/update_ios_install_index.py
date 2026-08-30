#!/usr/bin/env python3
"""Maintain the published index of ad hoc iOS install pages.

Called by ``scripts/publish_ios_install.sh`` from inside a checkout of the Pages
branch. It upserts one entry, trims the history to the newest N builds, deletes
the pages that fell off the end, and writes ``retained-ipas.txt`` so the caller
knows which release assets are still referenced.
"""

from __future__ import annotations

import html
import json
import os
import shutil
from pathlib import Path

INDEX_JSON = 'index.json'
INDEX_HTML = 'index.html'
RETAINED_IPAS = 'retained-ipas.txt'
RESERVED_NAMES = {INDEX_JSON, INDEX_HTML, RETAINED_IPAS}

PAGE_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>MonkeySSH iOS installs</title>
<style>
  :root {{ color-scheme: light dark; }}
  body {{
    margin: 0;
    padding: 2.5rem 1.25rem;
    font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    background: Canvas;
    color: CanvasText;
    display: flex;
    justify-content: center;
  }}
  main {{ width: 100%; max-width: 34rem; }}
  h1 {{ font-size: 1.35rem; margin: 0 0 0.4rem; }}
  p.lede {{ margin: 0 0 2rem; opacity: 0.65; font-size: 0.95rem; }}
  ul {{ list-style: none; margin: 0; padding: 0; }}
  li {{ padding: 0.85rem 0; border-top: 1px solid color-mix(in srgb, CanvasText 15%, transparent); }}
  a {{ color: #0a84ff; text-decoration: none; font-weight: 600; }}
  .meta {{ display: block; opacity: 0.6; font-size: 0.85rem; font-weight: 400; }}
</style>
</head>
<body>
<main>
  <h1>MonkeySSH iOS installs</h1>
  <p class="lede">Ad hoc builds published by CI. Open a build on an iPhone or iPad in Safari to install it. Only devices registered in the MonkeySSH Apple Developer account can run these builds.</p>
  <ul>
{items}
  </ul>
</main>
</body>
</html>
"""


def render_index(entries: list[dict[str, str]]) -> str:
    if not entries:
        items = '    <li>No builds published yet.</li>'
    else:
        items = '\n'.join(
            '    <li><a href="{slug}/">{title}</a>'
            '<span class="meta">{subtitle} &middot; published {published}</span></li>'.format(
                slug=html.escape(entry['slug'], quote=True),
                title=html.escape(entry['title']),
                subtitle=html.escape(entry.get('subtitle', '')),
                published=html.escape(entry.get('published_at', '')),
            )
            for entry in entries
        )
    return PAGE_TEMPLATE.format(items=items)


def main() -> None:
    root = Path(os.environ['INSTALL_ROOT'])
    slug = os.environ['ENTRY_SLUG']
    keep = max(1, int(os.environ.get('ENTRY_KEEP', '25')))

    index_path = root / INDEX_JSON
    entries: list[dict[str, str]] = []
    if index_path.exists():
        try:
            loaded = json.loads(index_path.read_text(encoding='utf-8'))
        except json.JSONDecodeError:
            loaded = []
        if isinstance(loaded, list):
            entries = [entry for entry in loaded if isinstance(entry, dict) and entry.get('slug')]

    entry = {
        'slug': slug,
        'title': os.environ['ENTRY_TITLE'],
        'subtitle': os.environ.get('ENTRY_SUBTITLE', ''),
        'page_url': os.environ.get('ENTRY_PAGE_URL', ''),
        'ipa_asset': os.environ.get('ENTRY_IPA_ASSET', ''),
        'published_at': os.environ['ENTRY_PUBLISHED_AT'],
    }
    # published_at only has second resolution, so several builds can tie. Put
    # the entry being published first outright rather than relying on sort
    # stability, which would otherwise let a build prune its own page.
    others = [existing for existing in entries if existing['slug'] != slug]
    others.sort(key=lambda item: item.get('published_at', ''), reverse=True)

    retained = ([entry] + others)[:keep]
    retained_slugs = {item['slug'] for item in retained}

    for child in root.iterdir():
        if child.name in RESERVED_NAMES or child.is_file():
            continue
        if child.name not in retained_slugs:
            shutil.rmtree(child)

    index_path.write_text(json.dumps(retained, indent=2) + '\n', encoding='utf-8')
    (root / INDEX_HTML).write_text(render_index(retained), encoding='utf-8')
    (root / RETAINED_IPAS).write_text(
        ''.join(f'{item["ipa_asset"]}\n' for item in retained if item.get('ipa_asset')),
        encoding='utf-8',
    )


if __name__ == '__main__':
    main()
