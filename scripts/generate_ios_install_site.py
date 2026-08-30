#!/usr/bin/env python3
"""Rebuild the whole iOS install site from the `ios-install-*` releases.

Those releases are the source of truth: each one carries an IPA plus a metadata
block describing the build, so the site is a pure function of the release list.
Nothing here reads previous site state, which means a regeneration is
idempotent, self-healing after a failed deploy, and safe to run concurrently --
whichever run publishes last simply has the most complete view.

Retiring a build is therefore just deleting its release.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from generate_ios_install_manifest import build_manifest, build_page  # noqa: E402
from ios_install_pages_url import pages_base_url  # noqa: E402
from ios_install_release_body import parse_metadata  # noqa: E402

TAG_PREFIX = 'ios-install-'

INDEX_TEMPLATE = """<!doctype html>
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
  <p class="lede">Ad hoc builds published by CI. Open one on an iPhone or iPad in Safari to install it. Only devices registered in the MonkeySSH Apple Developer account can run these builds.</p>
  <ul>
{items}
  </ul>
</main>
</body>
</html>
"""


def list_install_releases(repo_slug: str) -> list[dict]:
    """Every ios-install-* release, newest first, with its metadata parsed."""
    raw = subprocess.run(
        ['gh', 'api', f'/repos/{repo_slug}/releases', '--paginate'],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    # --paginate concatenates one JSON array per page.
    releases: list[dict] = []
    decoder = json.JSONDecoder()
    index = 0
    while index < len(raw):
        while index < len(raw) and raw[index].isspace():
            index += 1
        if index >= len(raw):
            break
        page, index = decoder.raw_decode(raw, index)
        releases.extend(page)

    builds = []
    for release in releases:
        tag = release.get('tag_name', '')
        if not tag.startswith(TAG_PREFIX) or release.get('draft'):
            continue
        metadata = parse_metadata(release.get('body') or '')
        if not metadata or not metadata.get('slug') or not metadata.get('ipa_asset'):
            print(f'Skipping {tag}: no usable install metadata.', file=sys.stderr)
            continue
        metadata['tag'] = tag
        metadata['published_at'] = release.get('published_at') or release.get('created_at') or ''
        builds.append(metadata)

    builds.sort(key=lambda build: build.get('published_at', ''), reverse=True)
    return builds


def render_index(builds: list[dict]) -> str:
    if not builds:
        items = '    <li>No builds published yet.</li>'
    else:
        items = '\n'.join(
            '    <li><a href="{slug}/">{title}</a>'
            '<span class="meta">{subtitle} &middot; published {published}</span></li>'.format(
                slug=html.escape(build['slug'], quote=True),
                title=html.escape(build.get('title', build['slug'])),
                subtitle=html.escape(build.get('subtitle', '')),
                published=html.escape(build.get('published_at', '')),
            )
            for build in builds
        )
    return INDEX_TEMPLATE.format(items=items)


def write_build(build: dict, *, repo_slug: str, base_url: str, install_root: Path) -> None:
    slug = build['slug']
    flavor = build.get('flavor') or 'private'
    build_dir = install_root / slug
    build_dir.mkdir(parents=True, exist_ok=True)

    ipa_url = (
        f"https://github.com/{repo_slug}/releases/download/"
        f"{build['tag']}/{build['ipa_asset']}"
    )
    manifest_url = f'{base_url}/install/{slug}/manifest.plist'
    icon_url = f'{base_url}/install/icon-{flavor}.png'
    sha = build.get('source_sha', '')

    details = [
        ('Version', f"<code>{html.escape(build.get('build_name', ''))}</code>"),
        ('Build', f"<code>{html.escape(build.get('build_number', ''))}</code>"),
        ('Bundle ID', f"<code>{html.escape(build.get('bundle_id', ''))}</code>"),
    ]
    if sha:
        details.append(
            ('Commit', f'<a href="https://github.com/{repo_slug}/commit/{sha}">'
                       f'<code>{sha[:7]}</code></a>')
        )
    if build.get('pr_number'):
        details.append(
            ('Pull request', f'<a href="https://github.com/{repo_slug}/pull/'
                             f"{build['pr_number']}\">#{build['pr_number']}</a>")
        )
    if build.get('run_url'):
        details.append(('Built by', f"<a href=\"{build['run_url']}\">workflow run</a>"))

    (build_dir / 'manifest.plist').write_bytes(
        build_manifest(
            ipa_url=ipa_url,
            bundle_id=build.get('bundle_id', ''),
            bundle_version=build.get('build_name', ''),
            title=build.get('title', ''),
            display_image_url=icon_url,
            full_size_image_url=icon_url,
        )
    )
    (build_dir / 'index.html').write_text(
        build_page(
            manifest_url=manifest_url,
            title=build.get('title', slug),
            subtitle=build.get('subtitle', ''),
            icon_url=icon_url,
            details=details,
        ),
        encoding='utf-8',
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path, help='Site directory to write')
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY', ''))
    args = parser.parse_args()

    repo_slug = args.repo
    if not repo_slug:
        repo_slug = subprocess.run(
            ['gh', 'repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'],
            capture_output=True, text=True, check=True,
        ).stdout.strip()

    base_url = pages_base_url(repo_slug, os.environ.get('IOS_INSTALL_PAGES_BASE_URL', ''))
    builds = list_install_releases(repo_slug)

    site = args.output
    if site.exists():
        shutil.rmtree(site)
    install_root = site / 'install'
    install_root.mkdir(parents=True)

    # actions/upload-pages-artifact does not run Jekyll, but .nojekyll keeps the
    # same content usable if Pages is ever pointed at a branch instead.
    (site / '.nojekyll').write_text('', encoding='utf-8')

    repo_root = Path(__file__).resolve().parent.parent
    for flavor, icon in (
        ('private', 'monkeyssh_icon_private.png'),
        ('production', 'monkeyssh_icon.png'),
    ):
        if any(build.get('flavor', 'private') == flavor for build in builds):
            shutil.copyfile(repo_root / 'assets' / 'icons' / icon,
                            install_root / f'icon-{flavor}.png')

    for build in builds:
        write_build(build, repo_slug=repo_slug, base_url=base_url, install_root=install_root)

    (install_root / 'index.html').write_text(render_index(builds), encoding='utf-8')
    (site / 'index.html').write_text(render_index(builds), encoding='utf-8')

    print(f'Rendered {len(builds)} install page(s) into {site}')
    for build in builds:
        print(f"  {build['slug']}  <- {build['tag']}")


if __name__ == '__main__':
    main()
