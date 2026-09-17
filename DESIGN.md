---
version: 1
name: BigIsland
description: A black island under the MacBook notch, styled after Apple's product-page language adapted to a permanently dark surface. One blue accent, SF Pro at weights 400/600, capsule buttons, 8 pt cells, no shadows. Source of truth for values is `Sources/BigIsland/Island/Theme.swift`.

colors:
  canvas: "#000000"          # island background, must match the notch
  accent: "#2997ff"          # Theme.accent: the only accent (text, icons, links, progress, study)
  action: "#0066cc"          # Theme.action: fill of primary capsule buttons, white label
  on-action: "#ffffff"
  text: "#ffffff"
  muted: "#cccccc"           # Theme.muted: secondary text, idle icons, rest phase
  faint: "#7a7a7a"           # Theme.faint: tertiary labels, empty calendar days, week numbers
  tile: "#272729"            # Theme.tile: selected tab, studied day cell, thumbnail backdrop
  hairline: "rgba(255,255,255,0.10)"  # Theme.hairline: dividers, thumbnail border
  hover: "rgba(255,255,255,0.10)"     # capsule behind a hovered button

typography:
  display-clock:   { size: 44, weight: 600, tracking: -0.5, digits: monospaced }
  title:           { size: 17, weight: 600, tracking: -0.374 }
  body:            { size: 14, weight: 400, tracking: -0.224 }
  body-strong:     { size: 14, weight: 600, tracking: -0.224 }
  nav:             { size: 12, weight: 400, tracking: -0.12 }   # tabs (600 when selected), links
  label:           { size: 12, weight: 600, tracking: -0.12 }   # phase title
  micro:           { size: 10, weight: 400 }                    # weekday and week-number headers
  cell:            { size: 11, weight: 400, digits: monospaced } # day number; 10/600 when showing time

rounded:
  cell: 8          # Theme.radius: calendar cells, screenshot thumbnails
  island: 26       # expanded island bottom corners (8 when collapsed)
  pill: capsule    # every button, tab and hover backdrop

spacing:
  island-inset: 16     # horizontal padding of header and content
  content-top: 6
  content-bottom: 14
  panel-gap: 18        # timer panel | divider | calendar
  stack: 8             # vertical rhythm inside panels
  grid: 2              # calendar cell gap
  thumbnails: 10       # gap between screenshot thumbnails

components:
  tab:
    selected:   { fill: "{colors.tile}", text: "{colors.text}", typography: nav/600, padding: "4 10", rounded: pill }
    unselected: { fill: none, text: "{colors.muted}", typography: nav }
  button-primary:   { fill: "{colors.action}", text: "{colors.on-action}", typography: body, padding: "6 16", rounded: pill }
  button-secondary: { fill: none, stroke: "1 {colors.accent}", text: "{colors.accent}", typography: body, padding: "6 16", rounded: pill }
  button-icon:      { glyph: 12, color: "{colors.muted}", frame: 24 }   # power, reset
  button-nav:       { glyph: 12/600, color: "{colors.accent}", frame: 22 } # calendar chevrons
  text-link:        { text: "{colors.accent}", typography: nav }       # calendar "Сегодня"
  calendar-day:
    empty:   { text: "{colors.faint}", typography: cell }
    studied: { fill: "{colors.tile}", text: "{colors.accent}", typography: cell/10/600 }
    today:   { stroke: "2 {colors.accent}" }
    outside-month: { opacity: 0.35 }
  thumbnail:
    size: 160x110
    rounded: cell
    border: "1 {colors.hairline}"
    hover-border: "2 {colors.accent}"
    hover-scale: 1.03
  empty-state: { icon: "22 {colors.accent}", text: "body {colors.muted}" }
---

## Overview

BigIsland lives in the notch, so the canvas is always pure black and the UI is always dark (`.colorScheme(.dark)`). The look borrows Apple's marketing-page restraint: the content (a timer, a calendar, screenshots) is the product, chrome recedes. Colour carries meaning only through one blue. Everything interactive is a capsule; everything that holds data is an 8 pt cell.

Priorities stay the app's priorities: speed, smoothness, easy to add features. The design system must never cost idle CPU or frame drops.

## Colors

- **One accent.** `accent` #2997ff marks what is interactive or active: links, chevrons, secondary buttons, progress, round dots, studied time, today's cell. No second accent colour exists. Don't add green, orange, red or per-feature colours.
- **Primary fill.** `action` #0066cc is used only as the fill of a primary capsule with a white label (contrast ~5.6:1). Don't use it as text on black; it is too dark there.
- **Phases.** Study = `accent`. Rest = `muted`. Idle title = `muted`.
- **Neutrals.** White for primary text, `muted` for secondary, `faint` for tertiary. `tile` #272729 is the only raised surface.
- **Canvas** stays #000000 so the island merges with the notch.

## Typography

System font only (`.system(size:weight:)`, which resolves to SF Pro Text/Display). No `.rounded` or other designs.

- Weights: **400 and 600 only.** No bold, no medium.
- Negative tracking on everything 12 pt and up (see tokens). None below 12 pt.
- Numbers that change or align (clock, calendar) use `.monospacedDigit()`.
- Selected state is expressed by weight (400 → 600) plus fill, not by size.

## Shapes

- Buttons, tabs, hover backdrops: `Capsule`.
- Data cells and thumbnails: `RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)`.
- Island shape: `UnevenRoundedRectangle`, bottom corners 26 expanded / 8 collapsed.
- Don't introduce other radii.

## Elevation

Flat. **No shadows anywhere**, including the island itself. Hierarchy comes from `tile` fill, hairlines and weight.

## Interaction

All buttons use `PressStyle` (`Theme.swift`):

- **Hover:** a `hover` capsule behind the label, 1.5 pt wider on each side and 1 pt taller, plus `brightness(0.12)`. Animated `easeOut 0.12`. It must not change layout (backdrop uses negative padding).
- **Press:** `scaleEffect(0.95)`, `easeOut 0.1`.
- **Cursor:** stays an arrow. The panel is non-activating, and macOS ignores cursor changes from a background app. Don't add private-API cursor hacks.
- Hit area is the whole label frame (`contentShape(Rectangle())`); small glyph buttons get an explicit 22-24 pt frame.

Screenshot thumbnails are not buttons: hover = 2 pt accent border + scale 1.03; double-click opens; drag out; context menu.

## Motion

Values tuned by hand; don't change them without being asked:

- Island shape: `IslandView.spring` = `spring(response: 0.38, dampingFraction: 0.8)`.
- Content in/out: `.scale(0.3, anchor: .top) + .opacity`, `easeIn 0.15`.
- Never animate the window frame; only the SwiftUI shape inside the fixed-size panel.

## Layout

- Header row height = notch height; tabs on the left, power on the right, the notch-width centre left empty for the camera.
- Feature content: 16 pt side inset, 6 top, 14 bottom, fixed `expandedSize` frame so it scales rather than reflows.
- Pomodoro: 220 pt timer panel, 1 pt hairline, calendar fills the rest. Calendar = header row + weekday row + hairline + 6 ISO weeks with week numbers.

## Copy

- Russian, sentence case ("Сегодня", not "СЕГОДНЯ").
- No em-dashes in UI strings; use a comma or a period.
- At most one middle dot per line ("Учёба · круг 2/4").

## Adding a feature

1. Use only `Theme` tokens; no inline hex.
2. Buttons: `.buttonStyle(PressStyle())`; primary action = `action` capsule, secondary = accent outline capsule.
3. Data in cells: `tile` fill, `Theme.radius`.
4. Provide an empty state: accent icon + one `muted` body sentence saying how to fill it.
5. Check it with `screencapture` over the notch, hovered and not.

## Don't

- Add a second accent colour or per-feature colours.
- Add shadows, gradients, or glows.
- Use weights other than 400/600, or `.rounded` fonts.
- Use radii other than capsule / 8 / island.
- Uppercase labels or em-dashes in copy.
- Re-add the "flash on new screenshot" peek.
