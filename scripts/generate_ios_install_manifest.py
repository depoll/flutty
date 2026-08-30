#!/usr/bin/env python3
"""Generate the itms-services manifest and landing page for an ad hoc iOS build.

iOS installs an ad hoc signed IPA over the air when Safari opens an
``itms-services://?action=download-manifest&url=<manifest>`` link. Both the
manifest and the IPA it points at must be reachable over public HTTPS, and the
link itself has to be clicked from Safari -- GitHub strips non-HTTP schemes from
comment bodies, so the manifest is paired with a small landing page that CI
publishes to GitHub Pages and links from PR comments and deployments.
"""

from __future__ import annotations

import argparse
import html
import plistlib
import urllib.parse
from pathlib import Path


def build_manifest(
    *,
    ipa_url: str,
    bundle_id: str,
    bundle_version: str,
    title: str,
    display_image_url: str | None,
    full_size_image_url: str | None,
) -> bytes:
    assets: list[dict[str, str]] = [
        {'kind': 'software-package', 'url': ipa_url},
    ]
    if display_image_url:
        assets.append({'kind': 'display-image', 'url': display_image_url})
    if full_size_image_url:
        assets.append({'kind': 'full-size-image', 'url': full_size_image_url})

    manifest = {
        'items': [
            {
                'assets': assets,
                'metadata': {
                    'bundle-identifier': bundle_id,
                    'bundle-version': bundle_version,
                    'kind': 'software',
                    # Without an explicit platform, a Mac with Apple silicon or a
                    # Vision Pro can claim the install and fail.
                    'platform-identifier': 'com.apple.platform.iphoneos',
                    'title': title,
                },
            },
        ],
    }
    return plistlib.dumps(manifest)


PAGE_TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Install {title_escaped}</title>
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
  main {{ width: 100%; max-width: 26rem; }}
  header {{ display: flex; align-items: center; gap: 0.9rem; margin-bottom: 1.75rem; }}
  header img {{ width: 64px; height: 64px; border-radius: 14px; }}
  h1 {{ font-size: 1.35rem; margin: 0; }}
  .subtitle {{ margin: 0.15rem 0 0; opacity: 0.65; font-size: 0.95rem; }}
  a.install {{
    display: block;
    text-align: center;
    padding: 0.85rem 1rem;
    border-radius: 12px;
    background: #0a84ff;
    color: #fff;
    font-weight: 600;
    text-decoration: none;
  }}
  dl {{ display: grid; grid-template-columns: auto 1fr; gap: 0.4rem 1rem; margin: 1.75rem 0 0; font-size: 0.9rem; }}
  dt {{ opacity: 0.6; }}
  dd {{ margin: 0; overflow-wrap: anywhere; }}
  code {{ font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85em; }}
  .notes {{ margin-top: 1.75rem; font-size: 0.85rem; opacity: 0.7; }}
  .notes li {{ margin-bottom: 0.4rem; }}
</style>
</head>
<body>
<main>
  <header>
    {icon_markup}
    <div>
      <h1>{title_escaped}</h1>
      <p class="subtitle">{subtitle_escaped}</p>
    </div>
  </header>

  <a class="install" href="{install_href}">Install on this iPhone or iPad</a>

  <dl>
{detail_rows}
  </dl>

  <ul class="notes">
    <li>Open this page in Safari on the device. Other browsers cannot start an over-the-air install.</li>
    <li>The device UDID must be registered in the MonkeySSH Apple Developer account, otherwise the app installs but refuses to launch.</li>
    <li>If the install fails, delete any existing copy of this app first — a TestFlight build cannot be replaced in place by an ad hoc build.</li>
  </ul>
</main>
</body>
</html>
"""


def build_page(
    *,
    manifest_url: str,
    title: str,
    subtitle: str,
    icon_url: str | None,
    details: list[tuple[str, str]],
) -> str:
    install_href = 'itms-services://?action=download-manifest&url=' + urllib.parse.quote(
        manifest_url, safe=''
    )
    icon_markup = (
        f'<img src="{html.escape(icon_url, quote=True)}" alt="">' if icon_url else ''
    )
    detail_rows = '\n'.join(
        f'    <dt>{html.escape(name)}</dt><dd>{value}</dd>' for name, value in details
    )
    return PAGE_TEMPLATE.format(
        title_escaped=html.escape(title),
        subtitle_escaped=html.escape(subtitle),
        install_href=html.escape(install_href, quote=True),
        icon_markup=icon_markup,
        detail_rows=detail_rows,
    )


def parse_details(raw: list[str]) -> list[tuple[str, str]]:
    details: list[tuple[str, str]] = []
    for entry in raw:
        name, separator, value = entry.partition('=')
        if not separator:
            raise SystemExit(f'--detail expects NAME=VALUE, got: {entry}')
        details.append((name, value))
    return details


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa-url', required=True)
    parser.add_argument('--manifest-url', required=True)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--bundle-version', required=True)
    parser.add_argument('--title', required=True)
    parser.add_argument('--subtitle', default='')
    parser.add_argument('--icon-url', default='')
    parser.add_argument('--output-manifest', required=True, type=Path)
    parser.add_argument('--output-page', required=True, type=Path)
    parser.add_argument(
        '--detail',
        action='append',
        default=[],
        metavar='NAME=VALUE',
        help='Landing page detail row; VALUE may contain HTML (repeatable)',
    )
    args = parser.parse_args()

    args.output_manifest.parent.mkdir(parents=True, exist_ok=True)
    args.output_page.parent.mkdir(parents=True, exist_ok=True)

    args.output_manifest.write_bytes(
        build_manifest(
            ipa_url=args.ipa_url,
            bundle_id=args.bundle_id,
            bundle_version=args.bundle_version,
            title=args.title,
            display_image_url=args.icon_url or None,
            full_size_image_url=args.icon_url or None,
        )
    )
    args.output_page.write_text(
        build_page(
            manifest_url=args.manifest_url,
            title=args.title,
            subtitle=args.subtitle,
            icon_url=args.icon_url or None,
            details=parse_details(args.detail),
        ),
        encoding='utf-8',
    )


if __name__ == '__main__':
    main()
