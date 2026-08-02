# ComiNavi map icons

ComiNavi uses the filled
[Material Symbols](https://icon-sets.iconify.design/material-symbols/) Rounded
family supplied through Iconify. These symbols are designed as one coherent
set, have enough visual weight to survive at map-marker size, and cover the
venue-specific facility vocabulary without mixing unrelated icon styles.

`Scripts/generate-bigsight-icons.mjs` maps every stable asset-catalog name to
an explicit Iconify identifier and vendors the resulting SVG into the app:

- a consistent `24 × 24` coordinate system;
- no embedded marker background;
- no font or runtime network dependency;
- semantic tint applied by the map renderer for halls, transit, accessibility,
  warnings, and medical facilities;
- East (`#D80B2A`), West (`#00559D`), and South (`#00A93A`) are rendered in
  app code as original bilingual badges (`東 / EAST`, `西 / WEST`, and
  `南 / SOUTH`) with a white outer inset;
- venue badges deliberately use no imported source artwork or Iconify glyph;
- the source guide's `#FAC02C` circular backdrop retained for bus, taxi, train,
  and water-bus markers, with dark foreground glyphs;
- source metadata retained in every generated SVG comment.

Regenerate the complete set with:

```sh
node Scripts/generate-bigsight-icons.mjs
```

Regeneration requires network access to `api.iconify.design`; the generated
assets are checked into the app and remain fully offline at runtime. Material
Symbols are copyright Google and licensed under Apache 2.0. The script
deliberately preserves every asset-catalog name so map data and call sites stay
independent from the artwork implementation.
