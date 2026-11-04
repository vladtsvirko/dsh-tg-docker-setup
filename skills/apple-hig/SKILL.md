---
name: apple-hig
description: Apply Apple's Human Interface Guidelines when designing, reviewing, or implementing UI for iOS, iPadOS, macOS, tvOS, visionOS, watchOS, or an Apple-flavored web app — principles, layout, color, typography, components, accessibility, and a measurable review checklist.
whenToUse: Use when the user asks for an Apple-style or native-feeling interface, an iOS/iPadOS/macOS/watchOS/tvOS/visionOS design, a HIG review, SwiftUI/UIKit/AppKit interface decisions, or a UI that must meet Apple's accessibility and layout expectations. Also use for web UI that should feel at home on Apple devices.
---

# Apple Human Interface Guidelines

Apple's HIG is public: <https://developer.apple.com/design/human-interface-guidelines>. It is the
authoritative source for how an app should look, behave, and feel on Apple platforms. This skill
turns it into a working procedure — it is a summary, not a replacement. When a specific rule
matters, fetch the current page (see below) instead of trusting memory.

## Three modes

| Mode | Do |
|---|---|
| **Design** | Pick the platform and inputs first, then apply the non-negotiables, then choose patterns and system components. Produce a screen spec the user can build. |
| **Review** | Audit against the checklist at the end. Report each finding as *what*, *why it matters*, *fix*, and the HIG link. Separate blocking accessibility issues from taste. |
| **Implement** | Prefer system components and semantic tokens over pixel copies. In SwiftUI/UIKit/AppKit use the platform APIs named on the HIG page; on the web use the mapping section below. |

## Fetch the current guidance first

Every HIG page has a Markdown twin: append `.md` to its URL. It returns clean text with no
JavaScript shell, so `web_fetch` gets the real content.

```
https://developer.apple.com/design/human-interface-guidelines/<slug>.md
```

- Index: `.../design-principles.md`? No — start at `.../human-interface-guidelines.md` for the
  full topic map, then fetch one slug per topic.
- Slugs are flat in the current site: `.../layout.md`, `.../color.md`, `.../buttons.md`.
  Older nested paths (`/foundations/color`) redirect to the flat one.
- If the fetch fails, say the specific rule is unverified and rely on this summary.

Do this because the guidelines move: the 2026 edition added **Liquid Glass** materials and
**iPhone Duo** guidance, and **reintroduced design principles** (June 2026). Older summaries
(“Clarity, Deference, Depth”, iOS 6-era chrome) are stale.

## The eight design principles (2026)

| Principle | In practice | Failure smell |
|---|---|---|
| **Purpose** | Every screen serves a stated user goal; cut what does not. | Feature-dump home screen. |
| **Agency** | People can act directly, explore, and recover from mistakes. | Forced linear wizard for a simple task. |
| **Responsibility** | Ask for data only when needed, explain why, protect it. | Permission prompt with no rationale. |
| **Familiarity** | Use known concepts and keep them consistent. | Novel gesture for a standard action. |
| **Flexibility** | Support devices, sizes, inputs, and accessibility settings. | Layout breaks at large text or in landscape. |
| **Simplicity** | Clear hierarchy, concise labels, necessary things close. | Dense chrome around one action. |
| **Craft** | Deliberate typography, spacing, motion, and copy. | Misaligned baselines, clipped labels. |
| **Delight** | Emotion through fit and polish, not decoration. | Gratuitous animation in a frequent flow. |

## Platform fit

Design for the device's ergonomics and input before styling anything.

| Platform | Primary input | Center of gravity | Avoid |
|---|---|---|---|
| iOS | Multi-Touch, one hand | Glanceable, focused, quick tasks | Desktop-density screens; tiny targets |
| iPadOS | Touch, Pencil, keyboard, pointer | Multitasking, larger canvas, sidebars | Stretched iPhone layouts |
| macOS | Keyboard + pointer | Many windows, deep work, menus, precision | Touch-first giant controls |
| tvOS | Focus-based remote | 10-foot viewing, focus, few choices per screen | Dense text; pointer assumptions |
| visionOS | Eyes + indirect hand gestures | Spatial windows, immersion levels, comfort | Content that forces head/neck movement |
| watchOS | Digital Crown, tap, wrist raise | <1-minute glances, complications, notifications | Multi-step flows; long text |
| iPhone Duo | Touch, fold/unfold | Continuity across both displays | Layout that resets when folding |

Per-platform details: [references/platforms.md](references/platforms.md).

## Non-negotiables

### Accessibility

- Label every control for VoiceOver; order matters more than exact wording.
- Support **Dynamic Type**: let text grow to at least **200%** (140% on watchOS) and reflow
  instead of truncating. Test the largest accessibility size.
- **Contrast**: 4.5:1 for text up to 17 pt, 3:1 at 18 pt+ or bold. Check light, dark, and
  Increase Contrast.
- Never use color as the only carrier of meaning — add text, shape, or position.
- Honor Reduce Motion, Reduce Transparency, Increase Contrast, Bold Text, and Larger Text.
- Give enough spacing between controls; spacing is part of the target.

### Targets

| Platform | Default control | Minimum control |
|---|---|---|
| iOS, iPadOS | 44×44 pt | 28×28 pt |
| macOS | 28×28 pt | 20×20 pt |
| tvOS | 66×66 pt | 56×56 pt |
| visionOS | 60×60 pt | 28×28 pt |
| watchOS | 44×44 pt | 28×28 pt |

A button needs a hit region of at least 44×44 pt (60×60 pt in visionOS), even when its visible
artwork is smaller. Add roughly 12 pt padding around bezelled controls and 24 pt around
borderless ones.

### Typography

| Platform | Default text | Minimum text |
|---|---|---|
| iOS, iPadOS | 17 pt | 11 pt |
| macOS | 13 pt | 10 pt |
| tvOS | 29 pt | 23 pt |
| visionOS | 17 pt | 12 pt |
| watchOS | 16 pt | 12 pt |

- Use the system fonts (SF Pro for UI, New York for serif) and built-in text styles; they carry
  Dynamic Type and weight matching for free.
- Avoid Ultralight/Thin/Light weights, especially at small sizes.
- Keep hierarchy consistent when text scales; do not scale every element equally.
- Keep truncation to a minimum; prefer wrapping or a stacked layout at large sizes.

### Color and materials

- Prefer semantic/dynamic system colors (label, secondary label, separator, background) over
  hard-coded hex values; documented values drift between releases.
- Supply light, dark, and increased-contrast variants for every custom color.
- Use one accent color for interactive emphasis; do not use the same color for unrelated meanings.
- **Liquid Glass** is for the functional layer (bars, sidebars, floating controls), never for
  content. Use the *regular* variant over variable content; the *clear* variant only over rich
  media, with a ~35% dimming layer when the background is bright. Let system components adopt it
  automatically; apply it to custom controls sparingly.

### Motion

- Motion explains change; it does not decorate. Keep feedback animations brief and cancelable.
- Do not block input until an animation finishes, especially in frequent flows.
- Under Reduce Motion, replace zoom/scale/parallax with fades or cross-dissolves.

### Icons and imagery

- Prefer SF Symbols; they scale with text, adapt to weight and appearance, and support animation.
- Match symbol weight to adjacent text. Do not mix filled and outlined styles arbitrarily.
- Provide @2x/@3x assets and light/dark variants where the artwork needs them.
- Keep app icons free of photos, screenshots, and tiny text; test at small sizes.

### Writing

- Be direct and action-oriented: verb-first button labels (“Add to Cart”, not “Let’s do it!”).
- Pick title case or sentence case per element type and apply it consistently.
- Error messages sit next to the problem, avoid blame, and say how to fix it
  (“Choose a password with at least 8 characters”).
- No “oops”, no “we”, no jargon. Prefer plain, localizable language.

## Patterns that decide the experience

- **Launch** into content, not a splash screen; restore previous state.
- **Onboarding** only for prerequisites; keep it brief, skippable, and never repeat it. Ask for
  permissions in context, with a reason.
- **Loading**: show structure immediately (placeholder content), use determinate progress when
  duration is known, and keep the app usable while loading. Avoid spinners for very short waits.
- **Feedback** matches significance: passive status for normal state, alerts only for critical
  and actionable interruptions.
- **Modality** is for a focused, short task; always give an obvious dismiss, confirm before
  discarding changes, and never stack modals.
- **Search**: start as the person types, show recent/suggested terms, rank relevant results,
  and offer scope filters when the corpus is broad.
- **Settings**: ship good defaults; put infrequently changed options in settings, respect
  system-wide settings instead of duplicating them.
- **Notifications**: ask in context, be actionable, never repeat the same notification, and keep
  private data out of previews.
- **Undo/redo** for edits; confirm only uncommon, irreversible destructive actions.
- **Destructive actions** use the destructive style and a Cancel escape, and never get the
  primary/default role.

## Components: choose the system one

| Need | Use | Key rule |
|---|---|---|
| Top-level destinations | Tab bar | 2–5 items, always visible, avoid overflow |
| Deep hierarchy on large screens | Sidebar | Hideable, content extends beneath it |
| Task in place | Sheet | One scoped task, obvious dismiss, confirm data loss |
| Short choice list | Action sheet / menu | For an intentional action, not for information |
| Critical interruption | Alert | Up to 3 buttons, critical + actionable only |
| Contextual options | Popover / context menu | Keep short; do not hide primary actions |
| Data collection | Text fields, pickers, toggles | Visible labels, errors adjacent, immediate effect for toggles |
| Progress | Progress indicator | Determinate when known, indeterminate otherwise |

Full catalog with slugs: [references/components.md](references/components.md).

## Review checklist

Run this for every design or review. Each item is pass/fail; cite the HIG page for failures.

1. Every target meets the platform minimum and has spacing.
2. Text meets the platform default size and grows to 200% without clipping.
3. Contrast passes in light, dark, and Increase Contrast.
4. No meaning is carried by color alone.
5. Every control has a VoiceOver label and a logical order.
6. Layout respects safe areas and adapts to size classes, rotation, and split view.
7. The primary action is visually obvious; destructive actions are marked and confirmable.
8. Navigation uses the platform's expected structure (tab bar, sidebar, back, menu bar).
9. Loading, empty, error, and offline states are designed — not just the happy path.
10. Modals are short, dismissible, and never stacked.
11. Motion is purposeful and respects Reduce Motion.
12. Copy is verb-first, consistent in capitalization, and error messages are actionable.
13. Permissions are requested in context with a reason.
14. Dark mode and light mode both look intentional.
15. Nothing imitates another platform's chrome or Apple's brand assets.

Detailed checklist: [references/review-checklist.md](references/review-checklist.md).

## When the target is the web

The HIG governs Apple-platform apps, not websites. For web UI that should *feel* Apple-like,
translate the principles and keep WCAG 2.2 AA as the enforceable baseline:

- Type: `font-family: system-ui, -apple-system, "Segoe UI", sans-serif` — do not ship SF Pro
  files (license), and do not fake iOS chrome on desktop.
- Targets: ≥44×44 CSS px for touch, ≥28×28 for pointer-primary; space them.
- Type scale: 17 px body on touch layouts, 13–15 px on dense desktop layouts.
- Color: semantic tokens with `prefers-color-scheme` and `prefers-contrast` variants; 4.5:1.
- Motion: `prefers-reduced-motion`; short (150–300 ms) transitions; no parallax by default.
- Focus: visible `:focus-visible` rings; full keyboard operability.
- Layout: `env(safe-area-inset-*)`, fluid grids, no fixed heights around text.
- Materials: `backdrop-filter` sparingly on floating bars; never behind body text.
- Test at 200% zoom and with a screen reader.

## Anti-patterns

- Custom gestures that collide with system gestures.
- An onboarding carousel before any value.
- An alert for every state change.
- Placeholder-only field labels; errors far from the field.
- Hard-coded light colors and no dark mode.
- Fixed-size text that ignores Dynamic Type.
- Tiny tap targets packed together.
- Copying Apple screenshots, icons, or SF Symbols into non-Apple products.
- “Delight” as animation volume.

## References

Load only what the task needs.

| File | Load when |
|---|---|
| [references/foundations.md](references/foundations.md) | Deep detail on accessibility, layout, color, type, materials, motion, icons, writing, privacy. |
| [references/patterns.md](references/patterns.md) | Designing or reviewing a flow: launch, onboarding, loading, feedback, modality, search, settings, notifications, undo. |
| [references/components.md](references/components.md) | Choosing or specifying a component, with its HIG slug and key rules. |
| [references/platforms.md](references/platforms.md) | Target is iOS, iPadOS, macOS, tvOS, visionOS, watchOS, iPhone Duo, or games. |
| [references/review-checklist.md](references/review-checklist.md) | Running a formal audit; includes severity levels and a report template. |

## Attribution

This skill summarizes and links Apple's Human Interface Guidelines. Apple owns that content;
do not paste long excerpts into code or docs. Link the page instead:
`https://developer.apple.com/design/human-interface-guidelines/<slug>`.
