#!/usr/bin/env python3
"""List `ios-installs` release assets that no published install page references.

Called by ``scripts/publish_ios_install.sh`` with the JSON from
``gh release view --json assets`` and the retained-asset list the Pages branch
just recorded. Prints one asset name per line for the caller to delete.
"""

from __future__ import annotations

import datetime
import json
import sys

# A concurrent run that has uploaded its IPA but has not yet pushed its index
# entry looks like an orphan from here. Leave recent uploads alone.
UPLOAD_GRACE = datetime.timedelta(hours=2)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit('usage: stale_ios_install_assets.py <assets.json> <retained.txt>')

    assets_path, retained_path = sys.argv[1], sys.argv[2]
    with open(assets_path, encoding='utf-8') as handle:
        assets = json.load(handle).get('assets', [])
    with open(retained_path, encoding='utf-8') as handle:
        retained = {line.strip() for line in handle if line.strip()}

    cutoff = (datetime.datetime.now(datetime.timezone.utc) - UPLOAD_GRACE).strftime(
        '%Y-%m-%dT%H:%M:%SZ'
    )

    for asset in assets:
        name = asset.get('name', '')
        if not name.endswith('.ipa') or name in retained:
            continue
        if asset.get('createdAt', '') >= cutoff:
            continue
        print(name)


if __name__ == '__main__':
    main()
