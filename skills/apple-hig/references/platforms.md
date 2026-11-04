# Platforms

Design for the device's display, distance, ergonomics, and input before choosing a visual style.
Fetch the platform page at
`https://developer.apple.com/design/human-interface-guidelines/designing-for-<platform>.md`
(`ios`, `ipados`, `macos`, `tvos`, `visionos`, `watchos`, `iphone-duo`, `games`).

## iOS

- Medium, high-resolution display; held in one or both hands; Multi-Touch is primary.
- Interactions are often short and interruptible: checking, messaging, capturing, paying.
- Respect the status bar and Dynamic Island; never place controls under them.
- Keep primary actions within thumb reach; use the bottom of the screen for frequent actions.
- Support system gestures (swipe back, home indicator) and do not create conflicting ones.
- Prefer tab bars for top-level destinations, navigation stacks for drill-in, sheets for scoped
  tasks.
- Design for one-handed use and for reachability, not just the largest device.

HIG: `designing-for-ios.md`

## iPadOS

- Large display, typically within about 3 feet; touch, Pencil, keyboard, pointer, and voice can
  be combined.
- People multitask: Split View, Slide Over, Stage Manager, external displays. Layouts must work
  at many widths.
- Use sidebars and split views for hierarchy on regular widths; collapse to a tab bar or stack
  on compact widths.
- Support drag and drop, keyboard shortcuts, and pointer hover where they add value.
- Pencil: low-latency inking, hover, squeeze, and double-tap where available; do not require it.
- Keep touch targets and spacing even when a pointer is present.

HIG: `designing-for-ipados.md`

## macOS

- Large display, usually stationary at a desk; keyboard and pointer are primary; deep work and
  multiple windows.
- Use the menu bar for every command; Settings belongs in the app menu, not the toolbar.
- Support multiple windows, window restoration, full screen, and Stage Manager.
- Precision matters: dense layouts are acceptable, but keep 28×28 pt default controls and
  20×20 pt minimum.
- Hover, right-click, and keyboard shortcuts are expected; tooltips explain unfamiliar controls.
- No Dynamic Type on macOS; use dynamic system font variants for controls.
- Mac Catalyst apps should adopt Mac conventions rather than shipping an iPad layout.

HIG: `designing-for-macos.md`

## tvOS

- Very large display viewed from 8+ feet; focus-based remote, game controllers, voice.
- Design a 10-foot experience: few choices per screen, large type (29 pt default), strong focus
  states, and no dense text.
- Focus drives interaction: every focusable element needs a clear, consistent focus appearance;
  never rely on color alone for focus.
- Safe area: inset content 60 pt top/bottom and 80 pt sides; use the documented grids.
- Tab bar height is fixed at 68 pt and its top edge sits 46 pt from the top; do not fight it.
- The Top Shelf is prime real estate; keep it to a few strong items.
- Games: support controllers, pause/resume, and long sessions.

HIG: `designing-for-tvos.md`, `designing-for-games.md`

## visionOS

- Infinite spatial canvas: windows, volumes, and 3D objects in the Shared Space; Full Space for
  immersion.
- Eyes + hands: people look at a target and tap indirectly; direct touch is optional. Never
  require precise pointing or sustained arm movement.
- Keep content within a comfortable field of view; avoid forcing head or neck movement.
- Windows are the default for UI-centric tasks; use immersion only for the moments that need it.
- Ornaments attach controls to a window edge; keep them few and relevant.
- Target sizes: 60×60 pt default, 28×28 pt minimum; system hover effects are the focus model.
- Comfort: avoid rapid motion, bright objects on dark backgrounds, and vection; respect Reduce
  Motion.
- Dark appearance only; design materials and contrast for it.

HIG: `designing-for-visionos.md`, `spatial-layout.md`, `immersive-experiences.md`

## watchOS

- Small display on the wrist, viewed at about a foot; Digital Crown, tap, swipe, Action button.
- Interactions last under a minute and are often glances; complications, notifications, and
  Siri may be used more than the app itself.
- Default text 16 pt, minimum 12 pt; default control 44×44 pt, minimum 28×28 pt; support text
  enlargement to at least 140%.
- Prefer full-width primary buttons; keep one clear action per screen.
- Avoid indeterminate spinners; if work takes time, say a notification will follow.
- No custom settings in the system Settings app; expose a few essentials in the app.
- Always On display: dim nonessential content, keep time-sensitive information legible.

HIG: `designing-for-watchos.md`

## iPhone Duo

A foldable iPhone: an outer display and a larger inner display, a center hinge, and many poses.
It is still iPhone — iOS patterns apply.

- Build for resizing, not for two fixed layouts: size classes (compact outer, regular inner),
  layout margins, safe-area insets, and no fixed widths.
- Keep functionality and element state identical across displays; add hierarchy on the inner
  display only when it helps (for example list + detail side by side).
- The system moves toolbars, tab bars, and navigation controls to the side on the outer display
  and keeps them there in landscape on the inner display. Use standard components to inherit it.
- When folding, move only what is necessary; avoid dramatic rearrangement. Prefer an even number
  of grid columns; use the ReservedRegion API to keep important elements clear of the hinge.
- Split and overlay arrangement views lay out content but do not navigate; put navigation
  containers around them.
- Test every pose in Xcode's Device Hub.

HIG: `designing-for-iphone-duo.md`

## Games

- Controllers, touch, keyboard, and focus all matter; support the inputs the platform expects.
- Keep text legible at the platform's default size and viewing distance; test in motion.
- Provide pause, save/resume, and clear state restoration.
- Respect safe areas, Reduce Motion, and color-blind-safe palettes.
- Do not letterbox when a layout change would fill the screen better.

HIG: `designing-for-games.md`
