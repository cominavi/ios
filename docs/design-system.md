# Design system

This document is the single source for spacing, type, shape, surfaces,
components, and text layout in ComiNavi. The Swift tokens and components live
in `ComiNavi/DesignSystem/`. New code uses them. Existing code moves to them
when a screen is touched.

A value that is off a scale needs a one-line comment that explains why.

## Principles

1. **One job per screen.** Each screen and each card has one primary action.
   Only that action uses the lime fill (`.primaryAction`).
2. **Plain event context.** Show the event as `C104 · Day 1 · Aug 11`. Show a
   space as one unit (`West あ01a`). Do not mix three formats of one space on
   one path through the app.
3. **Labeled actions.** Buttons have a text title. Icon-only buttons are for
   system chrome (close, back, share, toolbar) and always have an
   accessibility label.
4. **Text never wraps by surprise.** Every text view has a decided policy:
   wrap fully, one line with truncation, or a non-breaking token. See
   [Text layout rules](#text-layout-rules).
5. **Light and dark parity, iPhone and iPad parity.** Use semantic colors only.
   On iPad, constrain reading content to `ReadableWidth` and align every block
   in the column to the same edges.

## Spacing scale

| Token | pt | Use |
| --- | --- | --- |
| `Spacing.xxSmall` | 2 | Title to subtitle inside one text block. |
| `Spacing.xSmall` | 4 | Icon to short caption; inside a badge. |
| `Spacing.small` | 8 | Related controls, chips, lines of a row. |
| `Spacing.medium` | 12 | Icon to row text; stacked buttons; inset tile padding. |
| `Spacing.large` | 16 | Card padding; gap between cards. |
| `Spacing.xLarge` | 20 | Horizontal screen gutter on iPhone. |
| `Spacing.xxLarge` | 24 | Gap between sections. |
| `Spacing.xxxLarge` | 32 | Above a hero block or an empty state. |

Semantic aliases: `Spacing.screenGutter` (20), `Spacing.cardPadding` (16),
`Spacing.iconToText` (12), `Spacing.sectionGap` (24).

Migration map for the values found in the round-2 survey: 3 → 4, 5/6 → 4 or 8,
10 → 8 or 12, 14 → 12 or 16, 18 → 16 or 20, 28/30 → 24 or 32. Inside a `List`,
keep the system row insets and do not add padding.

## Type roles

Every role maps to a Dynamic Type text style. Never use `.system(size:)`
except in the documented exceptions below.

| Role | Font | Use |
| --- | --- | --- |
| Screen title | navigation title | Set by `.navigationTitle`. Do not draw it. |
| `Font.sectionTitle` | `.title3.semibold` | Section title in a non-`List` scroll view. |
| `Font.rowTitle` | `.headline` | Title of a card, row, or large action. |
| `Font.rowSubtitle` | `.subheadline` | Second line of a row or card; banners. |
| `Font.meta` | `.footnote` | Dates, counts, hall names, captions under controls. |
| `Font.badge` | `.caption2.semibold` | Badge and count capsule text. |
| `Font.control` | `.subheadline.semibold` | Button and chip titles. |
| `Font.largeControl` | `.headline` | Large primary buttons (onboarding, sign-in). |
| `Font.spaceCode` | `.headline.monospacedDigit()` | Space codes such as `東A01a`. |

`Font.focusedSurfaceTitle` (`.largeTitle`, rounded, bold) is the one
non-system role. It is only the hero title of a `FocusedActionSurface`
("Downloading catalog"). It still scales with Dynamic Type.

Exceptions to Dynamic Type: map chrome that is drawn in map coordinates
(`MapView`, `UnifiedBigSightMapView`), venue badges (`BigSightVenueBadge`), and
the circle cut image. These use fixed sizes because they scale with the map,
not with the reader setting.

## Corner radius

All shapes use `style: .continuous`.

| Token | pt | Use |
| --- | --- | --- |
| `Radius.xSmall` | 6 | Badges, tiny thumbnails. |
| `Radius.small` | 8 | Thumbnails, tiles nested inside a control. |
| `Radius.control` | 12 | Buttons, inset rows, text fields, inset tiles. |
| `Radius.card` | 16 | Cards and grouped surfaces. |
| `Radius.panel` | 24 | Floating panels over the map; app-drawn sheets. |
| `Capsule` | — | Chips, badges, search fields, pills. |

Concentric rule: a shape nested inside another shape uses
`Radius.concentric(outer:inset:)`, so both corners share one center. Example:
a thumbnail 8 pt inside a 16 pt card uses radius 8.

Migration map: 4 → 6, 7/9/10 → 8 or 12, 13/14 → 12 (control) or 16 (card),
18/20 → 16 or 24, 32 → 24.

## Surfaces

| Surface | API | Look |
| --- | --- | --- |
| Screen | `Color(.systemGroupedBackground)` | Grouped background. |
| Card | `.surface(.card)` | Secondary grouped fill, 16 pt radius, 0.5 pt hairline, 16 pt padding. |
| Inset tile | `.surface(.inset)` | Tertiary fill, 12 pt radius, no stroke, 12 pt padding. Only inside a card. |
| Floating map chrome | `.surface(.floating)` | Liquid Glass on iOS 26, `.regularMaterial` before it, 24 pt radius. |
| Map control | `.mapChromeSurface(.capsule / .circle / .card)` | The floating surface for controls over the map. In `Features/Map/MapChrome.swift`. |
| Focused state | `FocusedActionSurface(symbolName:) { … }` | Full-screen, one message. In `DownloadProgressView.swift`. |
| Sheet | system `.sheet` | Use detents. Do not draw a custom sheet background. |

Rules:

- Do not put a card inside a card. Use an inset tile or a divider.
- Do not add shadows to cards. Shadows are only for floating map chrome and the
  toast.
- The hairline (`Color.hairline`) keeps a white card visible on a white sheet in
  light mode. It is nearly invisible in dark mode, which is intended.

## Components

| Component | API | Rule |
| --- | --- | --- |
| Primary button | `.buttonStyle(.primaryAction)` | Lime fill, dark text. One per screen or card. |
| Secondary button | `.buttonStyle(.secondaryAction)` | Grouped fill, hairline, primary text. |
| Tertiary button | `.buttonStyle(.tertiaryAction)` | Accent text, no fill ("Show on map"). |
| Destructive button | `.buttonStyle(.destructiveAction)` | Red text on a 0.12 red fill. Use with `Button(role: .destructive)`. |
| Large button | `ActionButtonStyle(role: .primary, size: .large)` | 50 pt min height for onboarding and sign-in. |
| Button row | `AdaptiveButtonRow { … }` | Equal widths, or a column when a title would wrap. |
| Chip | `.buttonStyle(.chip(selected:))` | 32 pt capsule, 44 pt hit area, one line. |
| Badge | `StatusBadge("Demo", tone: .accent)` | Never wraps, never truncates. One or two words. |
| Section header | `SectionHeader("Quick access")` | Only outside a `List`. In a `List`, use `Section`. |
| Empty state | `EmptyStateView("No favorites yet", icon: "star")` | Wraps `ContentUnavailableView`. |
| Banner | `InlineBanner("…", icon: "info.circle")` | A notice, not a button. |
| Row | `List` row or `Label` | Icon `IconSize.row`, 12 pt to text, title `rowTitle`. |
| Icon row | `IconRow(icon:textStyle:) { … }` | Icon centered on the first text line; the text column starts at one x in every row. Use when the text can wrap. |
| Title with glyph | `TrailingGlyphText(Text(title), glyph: "external-link")` | A glyph inside the text run, joined to the last word. |
| Progress bar | `CapsuleProgressBar(segments:)` | The one custom progress track, 8 pt (scaled), capsule. |
| Color swatch | `ColorSwatch(color:size:)` | A favorite label color: filled circle, hairline. `IconSize.row` in rows. |
| Focused action | `FocusedActionButton { … }` | Full-width large action of a `FocusedActionSurface`. |
| Map icon control | `MapChromeIconLabel`, `MapSheetCloseButton` | 44 pt round map controls and the close "x" of sheets over the map. In `Features/Map/MapChrome.swift`. |
| Readable list | `.readableFormWidth()` | Centers a `Form` or `List` at `ReadableWidth.content` on iPad by content margins. In `Screens/ReadableFormWidth.swift`. |

### Focused states

`FocusedActionSurface` is the hero style for a screen with one message and
one or two actions: catalog download, errors, sign-in prompts, and
invitations. Its layout is fixed:

- An `IconSize.hero` Lucide glyph in the tint color at the top leading edge,
  and a faint, large copy of it as the backdrop.
- The message at the bottom: an optional eyebrow, the
  `Font.focusedSurfaceTitle` title, and a `rowSubtitle` subtitle.
- `FocusedActionButton` actions under the message, at full width
  (`ActionButtonStyle` large). A destructive primary action uses the
  destructive role. Do not put white text on a red fill.
- The content stays in `ReadableWidth.form` on iPad.

Do not use the hero style for a notice inside a screen. Use `InlineBanner` or
`EmptyStateView` there.

System `.bordered` and `.borderedProminent` stay valid inside alerts, forms,
and `List` rows. Do not use `.bordered` over the map: its translucent grey fill
has low contrast on map tiles. Use `.surface(.floating)` or `.glass` there.

## Icons

`LucideIcon(name, size:)` scales its design size with Dynamic Type.

| Token | pt | Next to |
| --- | --- | --- |
| `IconSize.chipAccessory` | 12 | Remove "x" inside a chip. |
| `IconSize.caption` | 14 | `caption` and `footnote` text. |
| `IconSize.inline` | 17 | `body`, `subheadline`, and button titles. |
| `IconSize.row` | 20 | Leading icon of a row or card. |
| `IconSize.action` | 22 | Leading icon of a large action card; toolbar glyphs. |
| `IconSize.hero` | 34 | Empty-state glyph. |

Icons without an `accessibilityLabel` are decorative: `LucideIcon` hides them
from accessibility, so a row or a `LucideLabel` exposes its text once.

Every row in one list uses the same icon size, so the text column starts at one
x position. Banners use the same leading inset as the rows below them.

## Hit areas

Every interactive element is at least 44 × 44 pt. Use `.minimumHitArea()` on
icon-only buttons. Chips draw 32 pt and pad to 44 pt.

## Color

- `Color.accentColor` (dark olive): accent **text** and icons on a plain
  surface.
- `Color.accentFill` (lime): a **fill** only. Text on it is always
  `Color.onAccentFill` (near black). Never put white text on lime.
- Status: `.orange` for warnings, `.red` for destructive. Use them as text or
  icon color, or at 0.08–0.14 opacity as a fill.
- Everything else uses semantic system colors (`.primary`, `.secondary`,
  `secondarySystemGroupedBackground`, `tertiarySystemFill`).

## Text layout rules

Decide the policy for every text view. The default SwiftUI behavior is to wrap,
then to truncate when the parent proposes a limited height. That default causes
most of the "mysterious" wraps.

### Wrap or truncate

| Content | Policy |
| --- | --- |
| Sentences: body, subtitles, captions, banners, error text | Wrap fully. `.wrapsFully()`. No `lineLimit`. |
| Titles of rows and cards | Wrap fully. A circle name may use `lineLimit(2)` in a dense grid only. |
| Button titles | Wrap only as a last resort. Put sibling buttons in `AdaptiveButtonRow`. |
| Chip and segmented titles | One line. Let the chip row scroll or flow. |
| Badges, counts, space codes, times | Non-breaking token. `.singleLineToken()`. |
| Values from data (URLs, handles, file names) | One line, `.truncationMode(.middle)`. |

Rules:

- `lineLimit(1)` needs a reason. Translations are often 30–60 % longer than
  English, and Japanese has no spaces at which to break.
- Use `.wrapsFully()` (`fixedSize(horizontal: false, vertical: true)`) on wrapping
  text inside a `ScrollView`, a `Button` label, or a fixed-height container.
  This stops truncation with "…" where a wrap is correct.
- Do not give a text view a fixed width. Use `frame(maxWidth: .infinity,
  alignment: .leading)` and let the container decide.
- A banner or card fills the column width. Do not cap its text with a smaller
  `maxWidth`. That makes the text wrap early and leaves an empty right side.

### Labels next to accessories

- In an `HStack` with a label and a trailing accessory (count, chevron, toggle,
  badge), give the label `.layoutPriority(1)`, and make the accessory a
  `.singleLineToken()`.
- Align the accessory with `.firstTextBaseline` when the label can wrap.
  Center it only when the label is one line by design.
- When a title and a count must share one line, use
  `ViewThatFits(in: .horizontal) { HStack { title; count } VStack { title; count } }`.
  The count moves under the title as a `Font.meta` line before the title
  breaks inside a word. See `ToolboxHubRow`.

### Glyphs after a title

- A glyph that follows a title (external link, lock, badge) goes inside the
  text run with `TrailingGlyphText`. It is joined to the last word with a
  no-break space and wraps with that word.
- Do not put such a glyph in its own `HStack` column. The column sits next to
  the first line, so the title splits around it and its last word can end
  up alone on the next line.
- The glyph is hidden from VoiceOver. Say what it means in the hint, for
  example "Opens in browser".

### Button rows

- Two or more buttons side by side go in `AdaptiveButtonRow`. It keeps equal
  widths and switches to a column when the widest title does not fit on one
  line. A plain `ViewThatFits { HStack; VStack }` is not enough: it checks the
  total width, so one title still wraps in its half next to a one-line
  sibling.
- Inside the row, every button gets the same height.

### Units that must not break

- Dates: use `Date.FormatStyle` (`.dateTime.month(.abbreviated).day()`) and pass
  the result through `NonBreaking.spaces(_:)` when it appears inside a sentence.
  Never build a date from pieces with ordinary spaces.
- Space codes: display with `Text(nonBreaking: code)`. This joins every
  character with U+2060, so `西あ01a` never splits. Copy and search the
  original string, not the display string.
- Hall names such as `West 1–2` and event context such as `C104 · Day 1`:
  `NonBreaking.spaces(_:)` on each unit. Keep the ` · ` separators as ordinary
  spaces, so the line can break between units.

### System line breaking

- iOS avoids a single short word on the last line of a paragraph. It moves
  the word before it down too ("…to set / your position."). The text box is
  then narrower than its column. This is not a layout fault: check the frame
  of the container, not the measured width of the text.
- Japanese text breaks at phrase boundaries ("…現在地を設定 / できます。").
  Do not fight either rule with manual breaks or a smaller font.

### CJK

- Japanese and Chinese break between any two characters. A short trailing
  fragment ("ありません。" alone on a line) is normal. A fragment that splits a
  word or a code is not. Protect codes and names with `NonBreaking.unit(_:)`.
- Do not insert manual line breaks in translations.
- Check every new screen in Japanese at the default size and at XXXL.

### Scaling

- `minimumScaleFactor` is only for fixed-size chrome: map badges, the tab
  accessory, and the circle-cut overlay. Never use it on body text or on
  button titles. Scaled-down text breaks Dynamic Type.
- At accessibility sizes, `ViewThatFits` and `AdaptiveButtonRow` switch to a
  column. Horizontal rows of metadata switch to a `VStack` with
  `dynamicTypeSize.isAccessibilitySize`.

## Review checklist

- [ ] Spacing, radius, and icon sizes use tokens.
- [ ] Only one primary (lime) button per screen or card.
- [ ] No white text on lime.
- [ ] Every text view has a decided wrap policy.
- [ ] Sibling buttons are in `AdaptiveButtonRow`.
- [ ] Dates and space codes cannot split.
- [ ] Checked in English, Japanese, XXXL, AX3, light, dark, iPhone, iPad.
