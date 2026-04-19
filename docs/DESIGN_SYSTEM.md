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
| `appBg`          | `#E8EAE4`  | `#000000`  | Screen background                   |
| `appSurface`     | `#F3F5EF`  | `#0C0D0C`  | Card, sheet surface                 |
| `appSurface2`    | `#DADDD4`  | `#15171A`  | Raised card                         |
| `appSurface3`    | `#C9CDC2`  | `#1E2125`  | Input chip                          |
| `appBorder`      | `#BFC3B8`  | `#23262B`  | Card + input stroke                 |
| `textPrimary`    | `#0A0B0A`  | `#F3F5F2`  | Headlines, body                     |
| `textSecondary`  | `#3F4540`  | `#A7ADA4`  | Meta, hints                         |
| `textTertiary`   | `#7A817A`  | `#6E7570`  | Disabled, decoration                |
| `danger`         | `#EF4444`  | `#EF4444`  | Destructive                         |
| `warn`           | `#F59E0B`  | `#F59E0B`  | Warning                             |

Light mode uses Volt as the only accent. Dark mode optionally themes with Neon Green.

## Where the tokens show up

- `App/RootView.swift` — UIKit nav/tab bar appearance + global `.tint(.accentVolt)`.
- `Views/Calendar/CalendarView.swift` — Hero "Day N of 90" block using `tsEyebrow` + `tsStat`; day rows are surface cards with Volt today-ring and complete-pill.
- `Views/ProgressBars/ProgressBarsView.swift` — Chart card on surface, tokenized axis labels.
- `Views/Progress/ProgressChartView.swift` — Target curve = `textPrimary`, logged dots = Volt.
- `Views/Analytics/AnalyticsView.swift` — Stat-card grid with display-size Archivo numerals, Volt highlight on "Current streak".
- `Views/WorkoutLog/*.swift`, `Views/WorkoutTypes/*.swift`, `Views/Settings/*.swift` — `scrollContentBackground(.hidden)` + `Color.appBg` under Form/List, Volt tint.
