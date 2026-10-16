# GlobeFlip Visual System

## Direction

GlobeFlip uses a quiet, compact, native macOS visual system. Settings use a
compact top icon toolbar.

## Principles

1. Native first. Prefer SwiftUI controls, SF Symbols, semantic system colors,
   keyboard navigation, and standard window behavior.
2. Quiet utility. Settings are dense, legible, and work-focused. Decoration
   never competes with status or controls.
3. Hierarchy through contrast and spacing. Avoid decorative cards, shadows,
   gradients, and oversized headings.
4. Immediate response. No decorative transition may delay Globe switching,
   settings changes, or recovery actions.
5. Semantic appearance. System, Light, and Dark share one token model rather
   than separate hand-painted screens.

## Appearance

The General section contains a three-option appearance control:

- System: default; follows macOS changes live.
- Light: forces the light appearance.
- Dark: forces the dark appearance.

Every app-owned window, sheet, menu, and notification-related icon
must update without relaunching. Use semantic colors so increased contrast and
future macOS appearance changes remain compatible.

## Foundation

### Typography

Use the macOS system font through SwiftUI text styles. Do not bundle a custom
font.

| Role | SwiftUI intent | Treatment |
| --- | --- | --- |
| Window title | `.headline` | Semibold |
| Page title | `.title2` | Semibold, used sparingly |
| Section title | `.headline` | Semibold |
| Row label | `.body` | Medium or semibold |
| Control value | `.body` | Regular |
| Supporting copy | `.callout` | Secondary color |
| Caption/status | `.caption` | Secondary color |

Letter spacing stays at the system default. Text must not be uppercased for
decoration.

### Icons

- Use SF Symbols with a consistent 15-17 pt body size.
- Sidebar icons use 16 pt; status icons may use 18-20 pt.
- Use monochrome hierarchical rendering unless a semantic status requires
  color.
- Do not draw custom substitutes for standard settings, timing, warning,
  refresh, pause, reorder, or information symbols.

### Color Tokens

Implementation must use semantic macOS colors. The reference values below
describe roles, not fixed hex colors.

| Token | macOS source | Use |
| --- | --- | --- |
| `background.window` | `windowBackgroundColor` | Main window |
| `background.sidebar` | `underPageBackgroundColor` or sidebar material | Sidebar |
| `background.control` | `controlBackgroundColor` | Pickers, fields, selected items |
| `background.hover` | `selectedContentBackgroundColor` at restrained opacity | Hover/focus |
| `text.primary` | `labelColor` | Main labels and values |
| `text.secondary` | `secondaryLabelColor` | Supporting text |
| `text.tertiary` | `tertiaryLabelColor` | Disabled and quiet metadata |
| `border.separator` | `separatorColor` | Rows and section boundaries |
| `accent.primary` | `controlAccentColor` | Active controls and links |
| `status.success` | system green | Ready and confirmed |
| `status.warning` | system orange | Recoverable setup issue |
| `status.error` | system red | Conflict or unavailable source |

Do not use a single hard-coded gray palette. Do not make blue the background
theme; reserve it for controls, links, and confirmed system feedback.

### Spacing

Use a 4 pt base grid:

- 4 pt: icon/text micro-gap
- 8 pt: compact control gap
- 12 pt: row-internal gap
- 16 pt: standard content gap
- 24 pt: section padding
- 32 pt: major section separation

Settings content uses 24 pt outer padding. Prefer separators and whitespace
over containers.

### Shape

- Controls: native macOS shape where available.
- Custom compact controls: 6-8 pt corner radius.
- Banners and sheets: 8 pt corner radius.
- Pills are reserved for short statuses, not ordinary buttons.
- No floating page cards and no cards nested inside cards.

## Window Structure

- Native titled settings window with real macOS traffic lights.
- Comfortable target size: about 980 x 640 pt.
- Minimum size: about 900 x 560 pt.
- Content remains readable when resized; rows may stack only when the control
  can no longer retain a useful width.
- No Dock icon. Settings opens from the menu bar menu.

## Navigation

The top toolbar contains:

1. General
2. Input Sources
3. Timing
4. Feedback
5. Statistics
6. Diagnostics

Each item uses one SF Symbol above one short label. Selected item uses accent
foreground and a restrained neutral surface.

## Components

### Settings Row

The default row is a two-column form:

- Label column: 140-170 pt, trailing aligned.
- Control column: flexible, normally 280-420 pt.
- Minimum row height: 36 pt.
- Supporting text sits below the control or label and uses secondary color.
- An information button appears only when the setting needs clarification.

### Section

Sections are full-width groups separated by 1 px semantic separators or 24-32
pt whitespace. A section may have a short title and one sentence of supporting
copy. It is not wrapped in a floating card.

### Input Source Row

- 42-46 pt stable height.
- Compact source mark or system icon, source name, optional quiet identifier.
- Reorder actions use chevron icons with tooltips.
- Disabled or disappeared sources retain their last name long enough to explain
  the problem, then direct the user to recovery.

### Timing Control

- Native slider from 50-300 ms with a compact numeric value.
- The current value is always visible.
- Default 150 ms is identified as the recommended baseline.
- The tester is a secondary action beside or below the slider.

### Appearance Control

Use three equal options with SF Symbols and labels: Light, Dark, System.
Selection combines icon contrast and a neutral selected surface. Color alone
must not communicate selection.

### Toggle

Use the native macOS switch. Label and explanation remain outside the switch.
Do not create oversized mobile-style toggles.

### Status Banner

Use a flat full-width row with icon, concise title, one sentence, and at most
two actions. Success is quiet. Warning and error states receive stronger
semantic color but no pulsing or animation.

### Menu Bar Menu

Use the native macOS pull-down menu so pointer hover, selection highlighting,
keyboard navigation, and Settings behavior remain system-owned. Keep it narrow
and command-oriented:

- Current status
- Pause or Resume Switching
- Settings
- Quit

Show a recovery command only while attention is required. Do not duplicate the
full settings interface inside the menu.

### Press Tester

Use a native sheet. It contains one large stable press target, five sample
slots, the recommendation, Reset, and Apply. A thin horizontal meter maps
50-300 ms from system green through yellow and orange to system red. A marker
moves while Globe/Fn is held, then rests at the measured duration. The numeric
duration remains visible, so color is supplementary. Testing never switches
the Input Source.

## Interaction States

- Hover: subtle neutral surface change.
- Focus: native keyboard focus ring.
- Pressed: native control feedback.
- Disabled: tertiary foreground without reducing legibility below accessible
  contrast.
- Loading: use a spinner only for operations that actually wait.
- Success: update status immediately after bounded switch confirmation.
- Failure: remain fail-open, show one concise notification, and expose recovery
  in Diagnostics.

Avoid custom motion. Any unavoidable UI transition must be under 150 ms and
respect Reduce Motion. Nothing in the event-to-switch path waits for UI,
animation, haptic feedback, or notification delivery.

## GlobeFlip Screen Mapping

### General

Active/paused state, launch at login, and appearance.

### Input Sources

Automatically discovered sources, cycle order, unavailable-source recovery.

### Timing

50-300 ms threshold, 150 ms default, five-press tester.

### Feedback

Off-by-default best-effort generic trackpad feedback.

### Statistics

Local successful-switch counts, daily/monthly/yearly totals, activity, and
estimated time saved. No analytics or telemetry.

### Diagnostics

Input Monitoring, Globe action, event tap health, last confirmation time,
competing remapper detection, Check Again, and notification recovery.

## Native Implementation Boundary

Build the settings hierarchy and controls in SwiftUI. Use AppKit only where
SwiftUI does not expose the required macOS behavior. Do not reproduce window
chrome, menus, checkboxes, switches, focus rings, or accessibility behavior
with custom drawing.

The compact blue input-source indicator beside the caret is system-owned. The
app neither redraws nor skins it.

## Acceptance Checklist

- System, Light, and Dark work in the settings window, menus, and sheets.
- Increased Contrast preserves hierarchy and control boundaries.
- VoiceOver names every control and reports current values and status.
- Full keyboard navigation works with visible focus.
- Window resizing causes no clipped labels, controls, or actions.
- Long system-provided Input Source names remain readable.
- No decorative animation or UI work affects switching latency.
- Status never relies on color alone.
- The result feels native to macOS.
