# Components

Use system components first: they carry accessibility, Dynamic Type, Liquid Glass, keyboard
support, and platform behavior for free. Customize only when the product needs it, and keep the
system's hit targets, states, and conventions.

Fetch a component's page at
`https://developer.apple.com/design/human-interface-guidelines/<slug>.md`.

## Content

| Component | Slug | Use | Key rule |
|---|---|---|---|
| Charts | `charts` | Data visualization | Use the Swift Charts look; label axes and series; never rely on color alone. |
| Image views | `image-views` | Showing images | Provide meaningful alt text; do not upscale beyond the source. |
| Text views | `text-views` | Long or editable text | Respect text styles and Dynamic Type; selectable when useful. |
| Web views | `web-views` | Embedded web content | Keep navigation inside the view predictable; provide a way back. |

## Layout and organization

| Component | Slug | Use | Key rule |
|---|---|---|---|
| Lists and tables | `lists-and-tables` | Rows of homogeneous data | One row = one item; use disclosure indicators for drill-in; keep row height tappable. |
| Collections | `collections` | Grids of visual items | Use for browsing, not for forms. |
| Split views | `split-views` | Master-detail on large screens | Collapse gracefully on compact widths. |
| Tab views | `tab-views` | macOS tabbed windows | Preserve per-tab state. |
| Sidebars | `sidebars` | Top-level navigation on iPad/Mac | Hideable, content extends beneath, icons follow accent color. |
| Outline views | `outline-views` | Hierarchies (mostly macOS) | Expand/collapse state persists. |
| Column views | `column-views` | Finder-style browsing (macOS) | Keep column widths usable. |
| Disclosure controls | `disclosure-controls` | Show/hide details | Use for progressive disclosure, not navigation. |
| Labels | `labels` | Static text | Use text styles; avoid truncation. |
| Boxes / lockups | `boxes`, `lockups` | Grouping / branded lockups | Group with spacing before adding chrome. |

## Menus and actions

| Component | Slug | Use | Key rule |
|---|---|---|---|
| Buttons | `buttons` | Actions | Verb-first title; hit region ≥44×44 pt (60×60 visionOS); primary role only for the likely, nondestructive action. |
| Menus | `menus` | Commands and options | Group related items; keep destructive items separated. |
| Context menus | `context-menus` | Actions on an item | Short; do not hide the only way to do something. |
| Toolbars | `toolbars` | Frequent actions for the current view | Few, important items; overflow for the rest. |
| The menu bar | `the-menu-bar` | macOS commands | Every command reachable; Settings in the app menu. |
| Activity views | `activity-views` | Sharing | Let the system provide destinations. |
| Pop-up / pull-down buttons | `pop-up-buttons`, `pull-down-buttons` | Pick one / run a command | Do not mix the two meanings in one control. |
| Edit menus | `edit-menus` | Cut/copy/paste | Standard order and shortcuts. |
| Home Screen quick actions | `home-screen-quick-actions` | Shortcuts into the app | Deep-link to the right place. |

## Navigation and search

| Component | Slug | Use | Key rule |
|---|---|---|---|
| Tab bars | `tab-bars` | Top-level destinations | Small, stable set (about five or fewer); persistent; avoid overflow and a “More” tab. |
| Search fields | `search-fields` | Finding content | Placeholder describes scope; results update as people type. |
| Path controls | `path-controls` | Hierarchy location (macOS) | Show the full path; each segment navigable. |
| Token fields | `token-fields` | Multi-value filters | Tokens are editable and removable. |

## Presentation

| Component | Slug | Use | Key rule |
|---|---|---|---|
| Alerts | `alerts` | Critical, actionable interruption | Title + optional message + up to 3 buttons; Cancel available; destructive style for unintended destruction. |
| Action sheets | `action-sheets` | Choices for an intentional action | Use instead of an alert when there are several related options. |
| Sheets | `sheets` | A scoped task | Obvious dismiss; confirm data loss; one task. |
| Popovers | `popovers` | Contextual options on iPad/Mac | Dismiss on outside tap; not for critical information. |
| Panels | `panels` | Auxiliary windows (macOS) | Stay on top when appropriate. |
| Windows | `windows` | Main content (macOS/visionOS) | Restore size and position; one clear primary window. |
| Scroll views | `scroll-views` | Overflowing content | Respect safe areas and scroll-edge effects. |
| Page controls | `page-controls` | Paging through a small set | Show position; keep the count small. |

## Selection and input

| Component | Slug | Use | Key rule |
|---|---|---|---|
| Text fields | `text-fields` | Free text | Visible label, right keyboard, inline errors. |
| Toggles | `toggles` | On/off with immediate effect | Apply immediately; never require a separate Save. |
| Sliders | `sliders` | Continuous value | Show the value; provide a precise alternative when needed. |
| Steppers | `steppers` | Small discrete increments | Label the value and range. |
| Segmented controls | `segmented-controls` | A few mutually exclusive views (about five on iPhone) | Keep labels short; do not use for navigation. |
| Pickers | `pickers` | Choosing from a known set | Prefer a wheel/list over free text. |
| Combo boxes | `combo-boxes` | Editable choice (macOS) | Allow free text only when valid. |
| Color / image wells | `color-wells`, `image-wells` | Picking a color/image | Show the current selection clearly. |
| Digit entry views | `digit-entry-views` | Codes and PINs | Large digits, clear error recovery. |
| Virtual keyboards | `virtual-keyboards` | Text entry | Pick the right keyboard type; never cover the active field. |

## Status

| Component | Slug | Use | Key rule |
|---|---|---|---|
| Progress indicators | `progress-indicators` | Ongoing work | Determinate when duration is known; cancel long work. |
| Gauges | `gauges` | A value in a range | Label units and range. |
| Rating indicators | `rating-indicators` | Displaying ratings | Do not use for input; use a rating control. |
| Activity rings | `activity-rings` | Move/Exercise/Stand | Respect the system rings' semantics. |

## System experiences

| Component | Slug | Use | Key rule |
|---|---|---|---|
| Widgets | `widgets` | Glanceable data outside the app | Show a small set of live information; tap targets open the right view. |
| Live Activities | `live-activities` | Ongoing task on the Lock Screen / Dynamic Island | Compact, glanceable, no sensitive data. |
| Notifications | `notifications` | Timely updates | One per event; actionable; privacy-safe. |
| Controls | `controls` | Control Center / Lock Screen actions | One clear action. |
| App Shortcuts | `app-shortcuts` | Siri / Spotlight entry points | Natural phrases; deep-link to the task. |
| Complications | `complications` | watchOS watch face data | Tiny, glanceable, relevant. |
| Status bars | `status-bars` | System status | Do not obscure; adapt to appearance. |
| Top Shelf | `top-shelf` | tvOS featured content | A few strong items. |
| Watch faces | `watch-faces` | watchOS faces | Follow the face's composition rules. |
| Snippets | `snippets` | Inline views in Siri/Spotlight | Read-only, focused. |

## Component rules that prevent most defects

1. Use the platform's navigation container (tab bar, sidebar, navigation stack) instead of a
   custom one.
2. Keep one primary action per view; secondary actions are visually quieter.
3. Every control has a label, a pressed/disabled state, and an accessibility label.
4. Destructive controls are red, separated, and confirmable.
5. Empty and error states are part of the component spec.
6. Let system components adopt Liquid Glass; do not paint glass onto content.
7. Test every component at the largest Dynamic Type size and in both appearances.
