# Review checklist

Use this for a formal HIG audit. Report findings, not a rewritten design. Every failure gets a
severity, the observable evidence, the fix, and the HIG link.

## Severity

| Level | Meaning | Examples |
|---|---|---|
| **Blocker** | People cannot complete the task or access the content. | Unlabeled control for VoiceOver; contrast below 3:1; target under the platform minimum; content under the Dynamic Island. |
| **Major** | The task works but is error-prone, confusing, or inaccessible for a group. | No dark mode; text clips at large sizes; destructive action without confirmation; modal without dismiss. |
| **Minor** | Friction or inconsistency; the task still succeeds. | Inconsistent capitalization; nonstandard icon; spacing off by a few points. |
| **Nit** | Taste or polish. | Slightly different corner radius. |

## How to test

- **VoiceOver**: enable it and traverse the screen; every control is announced, ordered
  logically, and its state is clear.
- **Dynamic Type**: set the largest accessibility size; nothing clips, overlaps, or becomes
  unreachable; icons scale with their text.
- **Contrast**: measure both appearances and with Increase Contrast; use a WCAG calculator.
- **Color independence**: view a grayscale screenshot; status and errors remain distinguishable.
- **Reduce Motion / Reduce Transparency**: enable each; no essential information disappears and
  no disorienting motion remains.
- **Layout**: rotate, resize, enter Split View / Slide Over, use the smallest and largest
  supported widths; controls stay reachable and content stays in reading order.
- **Keyboard**: on iPadOS/macOS, reach every action with Full Keyboard Access; focus is visible.
- **States**: exercise loading, empty, error, offline, permission-denied, and long-content cases.

## Checklist

### Accessibility

- [ ] Every interactive element has an accessibility label, value, and trait where relevant.
- [ ] Reading order matches visual order; decorative images are hidden from assistive tech.
- [ ] Text reaches at least 200% (140% watchOS) without loss of content or function.
- [ ] Contrast is at least 4.5:1 for text ≤17 pt and 3:1 at 18 pt+ or bold, in both appearances
      and with Increase Contrast.
- [ ] No information is conveyed by color alone.
- [ ] Reduce Motion, Reduce Transparency, Bold Text, and Increase Contrast are honored.
- [ ] Every target meets the platform default/minimum and has spacing.
- [ ] Media has captions/transcripts; audio-only feedback has a visual alternative.

### Layout and adaptivity

- [ ] Content respects safe areas and system bars.
- [ ] Layout adapts to compact/regular widths, rotation, split view, and window resizing.
- [ ] Reading order is top-to-bottom, leading-to-trailing; RTL mirrors correctly.
- [ ] No fixed heights around scalable text; no clipped or overlapping labels.
- [ ] Wide layouts constrain text measure for readability.
- [ ] tvOS: 60 pt vertical / 80 pt horizontal safe insets; documented grid.

### Visual design

- [ ] Semantic/system colors are used; custom colors have light, dark, and increased-contrast
      variants.
- [ ] One accent color carries interactive emphasis; meanings are not reused.
- [ ] Typography uses system text styles and platform default sizes; no thin weights at small
      sizes.
- [ ] Icons are consistent in style, weight, and optical size; SF Symbols where possible.
- [ ] Liquid Glass is confined to the functional layer and used sparingly.
- [ ] Both light and dark appearances look intentional.
- [ ] Motion is purposeful, brief, and cancellable.

### Interaction and navigation

- [ ] The primary action is visually obvious; secondary actions are quieter.
- [ ] Navigation uses platform conventions (tab bar, sidebar, back, menu bar); no dead ends.
- [ ] Back/dismiss is always available; unsaved changes are protected.
- [ ] Modals are short, single-purpose, dismissible, and not stacked.
- [ ] Destructive actions are marked, confirmable, and never the default.
- [ ] Standard gestures and keyboard shortcuts are supported; custom gestures do not conflict.
- [ ] Search starts early, ranks well, and offers suggestions/scope where useful.

### Content and states

- [ ] Loading shows structure immediately and remains usable.
- [ ] Empty, error, offline, and retry states are designed.
- [ ] Errors appear next to the problem, avoid blame, and state the fix.
- [ ] Copy is verb-first, consistently capitalized, plain, and localizable.
- [ ] Permissions are requested in context with a clear reason.
- [ ] Notifications are actionable, non-repetitive, and privacy-safe.
- [ ] Onboarding is brief, skippable, and not repeated.
- [ ] Settings have good defaults and do not duplicate system-wide options.

## Report template

```
## HIG review — <screen/flow> — <platform(s)>

**Blockers**
1. <finding> — <evidence> — <fix> — <HIG slug>

**Major**
…

**Minor / Nits**
…

**Passed**
- <what already meets the guidelines>

**Unverified**
- <what could not be tested, and why>
```

Cite the page as `https://developer.apple.com/design/human-interface-guidelines/<slug>`.
