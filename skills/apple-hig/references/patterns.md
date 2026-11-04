# Patterns

Flow-level guidance. Fetch the slug for exact wording. Base URL:
`https://developer.apple.com/design/human-interface-guidelines/`.

## Launching

- Launch into useful content as fast as possible; restore the previous state.
- A launch screen is a static placeholder, not a branding moment or an ad.
- Never show an alert at launch; surface startup problems inline and non-modally.
- If data is stale, show cached content with a clear, non-blocking status.

HIG: `launching.md`

## Onboarding

- Teach only what is required to start; postpone everything else.
- Keep it brief and skippable, and never repeat a skipped tutorial on later launches.
- Make help findable later (Help, Settings, or a More menu).
- Request permissions inside the relevant context, with a reason, not as a wall at first launch.
- Do not gate the product behind account creation or a tour unless it truly cannot work without it.

HIG: `onboarding.md`

## Loading

- Show structure immediately: placeholder text, skeletons, or cached content.
- Let people do other things while content loads; do not freeze the interface.
- Use determinate progress when duration is known, indeterminate when it is not.
- For long waits, provide something useful or interesting rather than a bare spinner.
- watchOS: avoid indeterminate spinners; reassure people that a notification will arrive.
- Always design the empty, error, offline, and retry states.

HIG: `loading.md`, `progress-indicators.md`

## Feedback

- Match the delivery to significance: passive status for normal state, inline messages for
  correctable problems, alerts only for critical and actionable interruptions.
- Put status near the thing it describes.
- Confirm completion only for significant actions; people assume ordinary actions succeed.
- Errors: what happened, why, and the next step. No blame, no humor in failure.
- Prefer reversible actions with undo over confirmation dialogs.

HIG: `feedback.md`, `alerts.md`

## Modality

- Use modality only when a focused task or a consequential choice genuinely benefits.
- Keep modal tasks short, single-purpose, and free of deep sub-navigation.
- Always provide an obvious dismiss that follows platform convention (button, swipe down, Esc).
- Confirm before closing when unsaved changes would be lost; offer Save / Discard / Cancel.
- Never stack modal views; an alert may appear over content, but not over another alert.
- Title the modal with the task so people keep their place.

HIG: `modality.md`, `sheets.md`, `alerts.md`, `action-sheets.md`

## Searching

- Put search where the platform expects it (tab bar, toolbar, sidebar, menu).
- Start searching as the person types when results are cheap; otherwise show suggestions.
- Show recent searches and predictive terms before/while typing.
- Rank the most relevant results first; categorize when the result set is broad.
- Offer scope bars or tokens for well-defined categories; default to the broader scope.

HIG: `searching.md`, `search-fields.md`

## Settings

- Ship defaults that work for most people; settings are for exceptions.
- Put infrequently changed options in settings, frequently used actions in the interface.
- Respect system-wide settings instead of duplicating them.
- On macOS, put Settings in the app menu, not the toolbar.
- On watchOS, avoid custom app settings; expose a few essential options in the main view.

HIG: `settings.md`

## Notifications

- Ask for permission in context and explain the value.
- Send one notification per event; do not nag.
- Make actions useful and short; do not add an action that merely opens the app.
- Prefer nondestructive actions; mark destructive ones clearly.
- Keep private data out of titles and previews; provide generic text for hidden previews.
- Respect Focus and delivery settings; never use notifications for marketing without consent.

HIG: `notifications.md`, `managing-notifications.md`

## Undo and redo

- Support undo for editing and for destructive actions that are common and reversible.
- Provide redo; show the action name where the platform supports it (“Undo Delete”).
- Use shake-to-undo on iOS only as a supplement, never the only path.
- For uncommon, irreversible destruction, confirm with an alert instead of undo.

HIG: `undo-and-redo.md`

## Entering data

- Ask for the minimum; use defaults, pickers, and autofill before free text.
- Label every field visibly; placeholder text is a hint, not a label.
- Use the right keyboard type and content type for the data.
- Validate inline, next to the field, and preserve entered data on error.
- Do not split one value across multiple fields without need.

HIG: `entering-data.md`, `text-fields.md`, `virtual-keyboards.md`

## Drag and drop, files, sharing

- Support drag and drop for content people expect to move; provide a non-drag path too.
- Use the system file picker and document browser instead of a custom file UI.
- Use the share sheet for sharing; do not invent a parallel sharing menu.
- Support collaboration with the system's share and presence patterns where relevant.

HIG: `drag-and-drop.md`, `file-management.md`, `collaboration-and-sharing.md`

## Ratings and reviews

- Ask at a moment of success, not at launch or after a failure.
- Never interrupt a task; use the system review prompt at most a few times per year.
- Never gate features on a rating.

HIG: `ratings-and-reviews.md`
