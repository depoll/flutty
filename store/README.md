# Store media

Regenerated store screenshots, App Preview videos, and demo videos are **not
tracked in git**.

Publish them with:

```bash
./scripts/store_assets.sh publish --generate all --platform both
```

Restore the latest published archive into this checkout with:

```bash
./scripts/store_assets.sh download
```

CI downloads the rolling GitHub Release tag `store-assets` during Sync Store
Metadata and production releases, and re-hosts the media as Actions artifacts
from the Publish Store Assets workflow.

Listing copy stays in:

- `ios/fastlane/metadata-*`
- `android/fastlane/metadata-*`
