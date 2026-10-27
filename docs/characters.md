# Character assets

Looking for the available companions? See the [monster roster](monsters.md).

Built-in monsters use stable, lowercase English folder IDs. Display names belong in metadata,
so changing the UI language does not change session bindings.

```text
Resources/Characters/zinogre/
├── character.json
├── idle/       # 0.png, 1.png, 2.png, 3.png
├── working/    # 0.png, 1.png, 2.png, 3.png
└── waiting/    # 0.png, 1.png, 2.png, 3.png
```

Each action has four 256 × 256 PNG frames with transparent backgrounds.
Use a consistent position and scale across frames to avoid jitter.

```json
{
  "displayScale": 1.0,
  "names": {
    "en": "Zinogre",
    "zh-Hant": "雷狼龍",
    "ja": "ジンオウガ"
  },
  "aliases": ["雷狼龍"]
}
```

- `displayScale`: multiplier for the selected pet size, from 0.5 to 2; defaults to 1.
- `names`: localized labels; missing translations fall back to English, then the folder ID.
- `aliases`: previous folder IDs for built-in characters. Existing bindings migrate automatically;
  new characters can omit this field. Keep aliases unique and avoid other character IDs.

Add a folder with this layout and run `make app`. No character list is hard-coded.
Run `make catalog` after adding or renaming a character to update [the roster](monsters.md).
`make sprites` only generates `.build/Characters/`; `make app` also bundles the results.
Generated GIFs use a 1.6-second loop, which the app can override without rebuilding images.
Do not commit generated character GIFs, app bundles, ZIPs, drafts, or local session data.

The README preview is a versioned exception: `make preview` rebuilds `docs/assets/preview.gif`
from the PNG frames at 1.2 seconds per loop. Choose the featured characters and states in
`tools/build-preview.swift`; intermediate frames stay in `.build/readme-preview/`.

For a generated 4-column × 3-row sprite sheet, inspect anatomy and transparent gutters first, then use
`swift tools/import-sprite-sheet.swift SHEET.png OUTPUT_DIRECTORY` to extract idle, working, and waiting rows.
The importer preserves alpha and uses one scale across all frames with a shared ground baseline.
Keep original sheets and drafts outside Git; version the selected PNG frames and metadata only.
The [2026-10-27 prompt set](artwork-prompts/flagship-expansion.json) records the built-in image generation
and spacing repairs used for the flagship expansion.

Dozens of characters at this resolution fit comfortably in regular Git. Avoid committing app bundles and
repeated exports; reconsider Git LFS if individual source assets or accumulated history become substantially larger.

UI translations live in `Resources/{en,zh-Hant,ja}.lproj/Localizable.strings`.
Keep keys and format placeholders consistent across languages; `make test` checks them.
