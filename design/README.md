# The Avo mark

## Concept

A lowercase **a** followed by a voice level meter.

The bowl is one open stroke — an arc, not a closed loop — whose 60° aperture faces due right and
is covered by a full-height stem. The stem's left edge is tangent to the counter, so the counter
closes as a clean circle and the letter reads as an **a** before anything else. Three short bars
stand to the right of it on the letter's own baseline, climbing left to right.

No circle, no sphere, no ball gradient. Nothing in the mark is filled — it is five strokes of a
single weight with round caps, so it survives being scaled, tinted, and knocked down to a
monochrome template without redrawing.

### The one rule: nothing rises above the stem

Two earlier constructions failed on the same point, in opposite directions.

- Replacing the stem with the first bar made the letter incomplete: it read as **G**, then as
  **C** plus a signal meter.
- Giving the letter a real stem and then letting bars 2 and 3 rise *above* it made them letters
  in their own right: two ascender-height verticals after an "a" read as the word **all**, at
  every pitch (92, 108, 140) and every height ratio (1.3×, 1.5×, 1.8×) tried. Lifting them clear
  of the baseline weakened the read but did not delete it.

What kills it is height, not spacing. **No vertical stroke in the mark rises as high as the
letter's own stem.** The stem is the tallest thing in the drawing; the meter tops out at 191
against its 248, still 57 grid units short of the crown. Nothing next to the letter can be
mistaken for a second letter, because nothing next to it is letter-height. The bars share the
letter's baseline, which is what makes them read as one mark rather than as two objects.

## Colours

| Token | Value | Where |
| --- | --- | --- |
| Accent | `#378FFF` | the glyph. Identical to `Theme.accent` = `Color(red: 0.216, green: 0.561, blue: 1.0)`. |
| Tile | `#0B0D12` | the icon plate. |
| Tile tint | `#378FFF` at 8% → 0% | radial, centred at 30%/24% of the tile, radius 82%. Light from the upper left; never stronger than 8%. |
| Tile edge | `#FFFFFF` at 7%, 3 px | a hairline so a near-black tile still has an edge on a dark desktop. |

## Grid

Everything is drawn on the 1024 px grid macOS app icons use.

- **Tile** — 824 × 824 at (100, 100), i.e. a 100 px margin, corner radius 185.4 (0.225 × 824).
  A circular-arc corner rather than Apple's continuous-curvature squircle; at every size the
  icon actually ships at, the two are indistinguishable.
- **Glyph** — stroke 62, round caps and joins. Ink bounds **668 × 310** at (178, 357), centred
  on (512, 512). Wide and short: height is 0.46 of width.
- **Bowl** — radius 124 about (333, 512), drawn from 30° round to 330° (300° of arc, angles
  measured anticlockwise from east). Crown 388, baseline 636.
- **Stem** — x 457, 388 → 636. Its x is `bowl centre + r`, which puts its left edge exactly
  tangent to the counter: the counter stays a circle, with no wedge where the arc terminals
  disappear behind it. It is the tallest vertical in the mark and it never animates.
- **Meter** — x 579 / 697 / 815, all ending on the baseline at 636, tops at 540 / 490 / 445.
  Lengths 96 / 146 / 191 against the stem's 248.
- **Pitch** — centres 118 apart, i.e. a gap of 56 between bars, just under one stroke width.
  Chosen from the 32 px render, not from taste: it is the tightest spacing that still leaves a
  visible pixel of tile between bars at 32 px. A pitch of literally one stroke width (62) fuses
  them into a single block. The gap between the stem and the first bar is 60, a hair wider, so
  the letter separates from the meter without detaching from it.

### The glyph is placed in the tile at 0.92

`avo-mark.svg` holds the glyph at the sizes above. `avo-icon.svg` draws the same paths inside
`translate(512,512) scale(0.92) translate(-512,-512)`, which is the only difference between the
two files. At natural size a 668-wide glyph leaves 78 of sidebearing in an 824 tile and looks
jammed; at 0.92 it leaves 105, which is the proportion a mark this wide wants. The scale is
uniform, so the stroke scales with it (62 → 57) and nothing about the drawing changes but its
size. `AvoMark.swift` and the menu bar template both use the *unscaled* mark, because neither is
inside a tile.

## Files

| File | What it is |
| --- | --- |
| `avo-mark.svg` | the glyph alone, transparent, on the 1024 grid. Source for the menu bar template. |
| `avo-icon.svg` | tile + glyph at 0.92. Source for the app icon at every size above 16 px. |
| `avo-icon-small.svg` | simplified artwork for the 16 px slot only. See below. |
| `../Avo/Notch/AvoMark.swift` | the same geometry as a SwiftUI `Shape`, for use inside the app. |
| `../scripts/render-icon.swift` | SVG → `.icns`, asset catalog, menu bar template. |

**The geometry lives in two places: the SVGs and `AvoMark.swift`.** The app must not have to load
an SVG to draw its own mark, so the numbers are written out twice on purpose. If you move a point,
move it in both. `render-icon.swift` used to be a third place — it hard-coded the glyph's ink rect
in order to crop the menu bar template — and no longer is: it measures those bounds off a render
of `avo-mark.svg` and prints them, so the crop cannot drift from the artwork. The check is easy:
the bounds it prints must match `AvoGlyph.visualWidth` / `visualHeight` and the origin constants.

## Call sites

`AvoMark(size:)` takes a **width**; the mark is 0.46 as tall as it is wide, so a call site that
assumes a square lays out wrong. The four sizes in the app were set by eye against the type
beside them: onboarding welcome 120, onboarding ready 80, About 56, settings sidebar 26. If the
glyph's aspect ever changes again, look at all four before shipping.

## Re-rendering

```sh
swift scripts/render-icon.swift
```

From the repo root. It writes:

- `/tmp/avo-icon/Avo.iconset/` — the ten iconset slots
- `Avo/Resources/Avo.icns` — via `iconutil -c icns`
- `Avo/Resources/Assets.xcassets/AppIcon.appiconset/*.png` — the same pixels under the catalog's
  `@1x`/`@2x` names
- `Avo/Resources/Assets.xcassets/MenuBarIcon.imageset/*.png` — 18 pt template, 1x and 2x, black
  with alpha, 1 pt of clear space on every side
- `/tmp/avo-icon/review/*.png` — every size to look at before committing, including
  nearest-neighbour blow-ups of the 16, 32 and 64 px renders and of the 18 pt template

The script loads the SVGs with `NSImage(contentsOf:)`, which decodes them as vectors, and falls
back to `qlmanage -t` if that ever stops working (it prints which path it took).

The status item is `NSStatusItem.squareLength`, so the 18 pt template is a square canvas and a
wide mark is limited by width, not height: the glyph fills 16 of the 18 pt across and ends up
about 7 pt tall, in the same visual register as `wifi`. That is why the inset is 1 pt and not
more.

**Both icon sources have to stay in sync.** `project.yml` sets `CFBundleIconFile: Avo` (the
`.icns`, copied in as a resource) *and* `CFBundleIconName: AppIcon` with
`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` (the asset catalog). macOS reads different ones in
different places, so both must carry the same artwork. `render-icon.swift` writes each size once
and saves those exact pixels under both names, so running it is the only thing needed to keep
them identical. Do not hand-edit either one.

### The 16 px artwork

`avo-icon-small.svg` replaces the master for the 16 px slot, and only that slot. At 16 px the
whole tile is 13 px across, the master's stroke lands on 0.9 of a pixel and its bar pitch on 1.8,
and the result is a blob with smeared bars. The small artwork is the same mark redrawn on the
16 px pixel grid — at 64 grid units to the pixel, every edge falls on a pixel boundary:

- tile 832 (13 px, px 1 to 14) instead of 824, so its edges are whole pixels
- stroke 64, exactly 1 px
- bowl r = 128 about (288, 480) — px 4.5, 7.5. **Centring the bowl on a half pixel is the whole
  trick:** with r = 2 px and a 1 px stroke, the 5 px outer edge *and* the 3 px counter both land
  on pixel boundaries. A whole-pixel centre gives you one or the other, and the counter is what
  makes the shape a letter rather than a blob.
- bars at x 544 / 672 / 800 — pitch 2 px, one clear pixel of tile beside each
- the meter is 1 / 2 / 3 px of ink against the stem's 5, so the rise is stated in whole pixels
  and the tallest bar still stops 2 px short of the crown. The first bar is a single round cap.
- no hairline edge — at 13 px it is a half-pixel smudge

Everything from 32 px up renders the master untouched. If a future change makes 32 px mush too,
add `avo-icon-32.svg` on the same principle and raise `smallArtworkMaxSize` in the script rather
than tuning the master.
