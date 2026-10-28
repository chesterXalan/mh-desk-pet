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
  "emID": 57,
  "displayScale": 1.0,
  "names": {
    "en": "Zinogre",
    "zh-Hant": "雷狼龍",
    "ja": "ジンオウガ"
  },
  "aliases": ["雷狼龍"]
}
```

- `emID`: numeric base-species EM resource ID (`57` means `em057`). Required for bundled monsters;
  optional for imported characters. See [Monster numbering](#monster-numbering).
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
The 2026-10-28 expansion adds two more groups of eight; their exact prompts, spacing repairs, and metadata
are recorded in [batch 1](artwork-prompts/expansion-2026-10-28-batch-1.json) and
[batch 2](artwork-prompts/expansion-2026-10-28-batch-2.json).

Dozens of characters at this resolution fit comfortably in regular Git. Avoid committing app bundles and
repeated exports; reconsider Git LFS if individual source assets or accumulated history become substantially larger.

UI translations live in `Resources/{en,zh-Hant,ja}.lproj/Localizable.strings`.
Keep keys and format placeholders consistent across languages; `make test` checks them.

## Monster numbering

The app and generated roster sort monsters by the numeric `emID` in `character.json`.
Built-in characters come first; characters without an ID sort after numbered characters within
their group, with folder names breaking ties. Custom characters remain after the built-in roster.
Folder IDs and localized display names stay unchanged, so existing bindings keep working.

EM IDs identify game resources, rather than encyclopedia entries, icon indices, or popularity ranks.
The roster displays a normalized `emNNN` code for each base species; for example, Rathalos is
`em002` and Zinogre is `em057`. Different games may pad the number differently or append form suffixes.

Mappings are checked against these community-maintained game-data references:

- [World / Iceborne EM mapping](https://mhw.poedb.tw/eng/em)
- [Rise / Sunbreak monster resources](https://mhrise.mhrice.info/monster.html)
- [GU / XX monster model IDs](https://github.com/Alexander-Lancellott/MHGU-MHXX-HP-Overlay-For-Switch-Emulator/blob/main/modules/models.py)
  for Lagiacrus, Gammoth, and Valstrax
- [Wilds EM enum mapping](https://github.com/dtlnor/MonsterHunterWildsModding/wiki/Monster-IDs)
  for Arkveld (`EM0160_00_0`)

Add the verified EM ID when adding a built-in monster, then run `make catalog` to regenerate the roster.
