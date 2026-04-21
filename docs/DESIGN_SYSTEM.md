# Design System (90-Day Challenge · iOS)

Ported from the `ios-handoff` package delivered 2026-04-19. Source tokens are mirrored in `WorkoutChallenge/Theme/Tokens.swift` and `WorkoutChallenge/Theme/Typography.swift`. Colors live in `Assets.xcassets/Colors/`. Fonts live in `WorkoutChallenge/Fonts/` and are registered via `UIAppFonts` in `Info.plist`.

## Install notes

The asset catalog uses the `Colors/` namespace (`provides-namespace: true`), so all tokens are referenced as `Color("Colors/AccentVolt")` etc. — don't drop the folder.

Fonts are loaded by PostScript name, not filename. We verified the PostScript names with `fontTools` before wiring them up:

| File                         | PostScript name           |
|------------------------------|---------------------------|
| `ArchivoBlack-Regular.ttf`   | `ArchivoBlack-Regular`    |
| `Inter-Regular.ttf`          | `Inter-Regular`           |
| `Inter-Medium.ttf`           | `Inter-Medium`            |
| `Inter-SemiBold.ttf`         | `Inter-SemiBold`          |
| `Inter-Bold.ttf`             | `Inter-Bold`              |
| `JetBrainsMono-Medium.ttf`   | `JetBrainsMono-Medium`    |
| `JetBrainsMono-Bold.ttf`     | `JetBrainsMono-Bold`      |

The handoff README listed `Archivo-Black` as the PostScript name — it's actually `ArchivoBlack-Regular`. `Typography.swift` uses the corrected name.

If a registered font name doesn't resolve at runtime, `AppFont` falls back to the corresponding system face (SF Pro heavy for display, SF Pro at the requested weight for UI, SF Mono for mono) so the app stays runnable even if a TTF is ever removed from the target.

## Usage

```swift
// Color
Text("Day 54").foregroundStyle(Color.accentVolt)
ZStack { Color.appBg.ignoresSafeArea(); content }

// Typography
Text("Ninety days.").tsH1()
Text("22").tsStat().foregroundStyle(Color.accentVolt)
Text("DAY 54 OF 90").tsEyebrow()

// Spacing / Radius
VStack(spacing: Space.x4) { ... }
.background(Color.appSurface, in: .rect(cornerRadius: Radius.card))

// Motion
withAnimation(Motion.base) { isExpanded.toggle() }
```

## Color palette (light / dark)

| Token            | Light      | Dark       | Usage                              |
|------------------|------------|------------|-------------------------------------|
| `accentVolt`     | `#CCFF00`  | `#CCFF00`  | Primary accent, highlights, tint    |
| `accentNeon`     | `#39FF14`  | `#39FF14`  | Secondary accent (dark mode only)   |
| `accentInk`      | `#526600`  | `#CCFF00`  | Volt *as foreground* on light (text, icons) |
| `accentVoltInk`  | `#729000`  | `#CCFF00`  | Volt *as fill* where edge contrast matters (bars, outlines) |
| `appBg`          | `#E8EAE4`  | `#000000`  | Screen background                   |
| `appSurface`     | `#F3F5EF`  | `#0C0D0C`  | Card, sheet surface                 |
| `appSurface2`    | `#DADDD4`  | `#15171A`  | Raised card                         |
| `appSurface3`    | `#C9CDC2`  | `#1E2125`  | Input chip, slider unfilled track   |
| `appBorder`      | `#BFC3B8`  | `#23262B`  | Card + input stroke                 |
| `textPrimary`    | `#0A0B0A`  | `#F3F5F2`  | Headlines, body                     |
| `textSecondary`  | `#3F4540`  | `#A7ADA4`  | Meta, hints, inactive tab icons     |
| `textTertiary`   | `#5D6359`  | `#6E7570`  | Disabled, decoration                |
| `danger`         | `#EF4444`  | `#EF4444`  | Destructive                         |
| `warn`           | `#F59E0B`  | `#F59E0B`  | Warning                             |

Light mode uses Volt as the only accent. Dark mode optionally themes with Neon Green.

## Volt is a fill, never a foreground on light

Volt (`#CCFF00`) is a highlighter yellow-green. Against the chalk background it measures ~1.07:1 contrast — well below WCAG's 3:1 for non-text UI, let alone the 4.5:1 needed for small text. So the palette has three Volt-family tokens, and each has a dedicated role:

- **`accentVolt`** — fills, chips, pill buttons, progress bars, solid chart areas, `.tint()`, and any surface where dark ink text sits *on top*. Volt as a background + ink as a foreground is ~14:1 — that's fine.
- **`accentInk`** — small Volt-family *text and icons on a light surface*: eyebrow labels (`.tsEyebrow()`), stat numerals with `accent: true`, status icons, the Bars tab label. ~5.87:1 on Surface.
- **`accentVoltInk`** — Volt-family *fills that have no ink overlay* (bar chart marks, mid-weight outlines) and need ~3–4:1 edge contrast against the chalk background. Also a reasonable 1.5px stroke color on solid Volt fills when a pure-ink stroke feels too heavy.

All three collapse back to full `accentVolt` in dark mode, so the neon signature is preserved where it reads well (dark fields).

Rule of thumb: if dark ink sits **on** the Volt, use `accentVolt`. If the Volt **is** the ink (text/icon), use `accentInk`. If the Volt is a fill/outline with no text over it and needs edge definition on light mode, use `accentVoltInk`.

## Accessibility patch (2026-04-19)

Applied after a design review flagged contrast issues in the first visual build. Changes:

- Added `accentVoltInk` (see above) for chart fills and light-mode outlines. The review proposed `#8FB300` but that measures 2.22:1 on Surface — below the 3:1 non-text UI threshold the review cited. The committed value `#729000` measures 3.35:1 on Surface, which passes with a small margin while staying recognisably Volt-family (slightly darker olive-green).
- Bumped `textTertiary` light from `#7A817A` → `#5D6359` to hit 4.5:1 on Surface.
- Tab bar selected state uses `accentInk` (not `accentVolt`) so "Bars" reads on the light tab bar.
- 90-day grid's `proposed` cells use `accentInk` for their dashed outline and day number.
- Analytics weekly bars use `accentVoltInk` so bar edges have real definition against Surface.
- `SigmoidCurve` is now colorScheme-aware — ink stroke + Volt fill on light; Volt stroke + Volt fill on dark. (The Volt fill under the curve is the data weight; the ink stroke carries the shape.)
- `UISlider.maximumTrackTintColor` is wired to `appSurface3` so the Volt filled portion of sigmoid-parameter sliders has separation from the rest of the track.

## Where the tokens show up

- `App/RootView.swift` — UIKit nav/tab bar appearance + global `.tint(.accentVolt)`.
- `Views/Calendar/CalendarView.swift` — Hero "Day N of 90" block using `tsEyebrow` + `tsStat`; day rows are surface cards with Volt today-ring and complete-pill.
- `Views/ProgressBars/ProgressBarsView.swift` — Chart card on surface, tokenized axis labels.
- `Views/Progress/ProgressChartView.swift` — Target curve = `textPrimary`, logged dots = Volt.
- `Views/Analytics/AnalyticsView.swift` — Stat-card grid with display-size Archivo numerals, Volt highlight on "Current streak".
- `Views/WorkoutLog/*.swift`, `Views/WorkoutTypes/*.swift`, `Views/Settings/*.swift` — `scrollContentBackground(.hidden)` + `Color.appBg` under Form/List, Volt tint.
