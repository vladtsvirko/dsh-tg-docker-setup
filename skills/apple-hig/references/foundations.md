# Foundations

Deep notes behind the non-negotiables in `SKILL.md`. Each section ends with the HIG page to
fetch for the current wording. Base URL: `https://developer.apple.com/design/human-interface-guidelines/`.

## Accessibility

Accessibility is a design input, not a QA phase. Apple groups guidance under vision, hearing,
mobility, and cognition.

**Vision**

- Support text enlargement to at least **200%** (140% in watchOS apps), preferably through
  Dynamic Type so every text style scales together.
- Meet contrast: **4.5:1** for text up to 17 pt; **3:1** at 18 pt+ or for bold text. In Dark
  Mode, Apple recommends at least 4.5:1 and 7:1 for small custom text where possible.
- Never rely on color alone. Pair color with a label, a symbol, a pattern, or position.
- Describe the interface for VoiceOver; provide labels for images that carry meaning and hide
  purely decorative ones.
- Support Increase Contrast and Reduce Transparency with real variants, not opacity tweaks.

**Hearing**

- Caption video and provide transcripts for audio; do not make sound the only feedback channel.
- Offer visual or haptic alternatives to audio alerts.

**Mobility**

- Meet the platform control-size table and keep spacing between controls.
- Support Full Keyboard Access, Switch Control, Voice Control, and AssistiveTouch; make sure
  every action is reachable without a precise drag.
- Avoid timed interactions that cannot be extended.

**Cognition**

- Keep language plain and localizable; avoid jargon and idioms.
- Make errors recoverable and explain the fix next to the problem.
- Respect Reduce Motion and avoid fast, blinking, or repetitive animation.

HIG: `accessibility.md`

## Layout

- Order content by importance: people read top-to-bottom and leading-to-trailing.
- Respect safe areas so the Dynamic Island, toolbars, and hardware edges never cover content.
- Design for adaptivity: size classes, rotation, split view, Stage Manager, resizable windows,
  and external displays. Content and controls should stay in predictable places.
- Use system layout guides and margins instead of ad-hoc insets.
- Keep line length readable; constrain text width on wide screens.
- tvOS: inset content 60 pt from top and bottom and 80 pt from the sides; use the documented
  two- to six-column grids with 40 pt horizontal spacing.
- Do not use fixed heights around text that must grow.

HIG: `layout.md`

## Color

- Prefer dynamic system colors. They carry light, dark, and increased-contrast variants and
  adapt to vibrancy; documented hex values are reference only and change between releases.
- Give custom colors a light variant, a dark variant, and an increased-contrast variant.
- Use one accent color for interactive emphasis; avoid assigning several meanings to one color.
- Check contrast in both appearances and with Increase Contrast on.
- Do not put a similar color behind controls and in the content layer.
- Provide P3 and sRGB variants when a brand color must stay exact across wide-gamut displays.

HIG: `color.md`, `dark-mode.md`

## Dark Mode

- Support both appearances unless the product is inherently dark (for example immersive media).
- Dark Mode is not an inversion: use base and elevated backgrounds to convey depth.
- Use system label colors (primary, secondary, tertiary, quaternary) rather than fixed white.
- Test Dark Mode with Increase Contrast and Reduce Transparency, separately and together.
- Soften pure-white image backgrounds that would glow against dark UI.

HIG: `dark-mode.md`

## Typography

| Platform | Default | Minimum |
|---|---|---|
| iOS, iPadOS | 17 pt | 11 pt |
| macOS | 13 pt | 10 pt |
| tvOS | 29 pt | 23 pt |
| visionOS | 17 pt | 12 pt |
| watchOS | 16 pt | 12 pt |

- Use SF Pro for interface text and New York for serif; both are variable fonts with optical
  sizing. Do not embed system font files in an app.
- Use built-in text styles (body, headline, title, caption…) so Dynamic Type, Bold Text, and
  weight matching work automatically.
- Avoid Ultralight, Thin, and Light weights, especially small.
- Keep the hierarchy stable as text grows: primary content should stay primary.
- Custom fonts must implement the same scaling and accessibility behavior as system fonts.
- macOS has no Dynamic Type; use the dynamic system font variants for controls.

HIG: `typography.md`

## Materials

Apple platforms have two material families.

**Liquid Glass** — the functional layer (tab bars, sidebars, toolbars, floating controls). It
floats above content, lets content peek through, and keeps controls legible.

- Do not use Liquid Glass in the content layer; use standard materials for content backgrounds.
- System components adopt it automatically. Apply it to custom controls only for the most
  important functional elements.
- *Regular* variant: blurs and adjusts luminosity; use when content could hurt legibility or the
  component carries text (alerts, sidebars, popovers).
- *Clear* variant: highly translucent; only over visually rich media. Add a dark dimming layer
  of about 35% when the background is bright.
- Color on glass: reserve color for emphasis, put it on the background of a prominent control
  rather than on its label, and do not color many controls at once.

**Standard materials** — blur, vibrancy, and blending modes inside the content layer. Choose by
semantic role, not by the color a material happens to add. Thicker materials improve contrast;
thinner ones preserve context.

HIG: `materials.md`

## Motion

- Add motion only to explain a change, direct attention, or give feedback.
- Keep feedback animations brief and precise; avoid motion on frequent interactions.
- Let people cancel or skip; never block input until an animation ends.
- Under Reduce Motion, replace zoom, scale, and parallax with fades.
- Use SF Symbols animations where they clarify state instead of custom effects.

HIG: `motion.md`

## Icons and images

- Prefer SF Symbols: they align with text weights, scale with Dynamic Type, adapt to appearance,
  and support rendering modes and animations.
- Match symbol weight and scale to adjacent text; do not mix filled and outlined variants
  without a reason.
- Use familiar metaphors; a novel icon needs a text label.
- Provide @2x/@3x and appearance-specific artwork when a bitmap is unavoidable.
- App icons: simple, memorable, no photos or screenshots, legible at small sizes, and consistent
  with the platform's icon shape and grid.

HIG: `icons.md`, `sf-symbols.md`, `app-icons.md`, `images.md`

## Writing

- Match tone to context; serious situations get plain, direct language.
- Write for everyone: plain, inclusive, localizable, no jargon or gendered terms.
- Be action-oriented: verb-first labels for buttons and links (“Send”, “Learn more about UX
  Writing”).
- Pick title case or sentence case per element type and stay consistent.
- Avoid unnecessary possessives (“Favorites”, not “Your Favorites”) and avoid “we”.
- Errors: state what happened and what to do next, close to the field, without blame or “oops”.
- Choose the delivery method by urgency: passive status, inline message, notification, alert.

HIG: `writing.md`, `feedback.md`

## Privacy

- Collect only what the feature needs and say why at the moment of the request.
- Request permission in context, with a clear purpose string; never at launch as a formality.
- Keep sensitive data out of notifications, previews, and logs.
- Give people a way to review and revoke access; respect system-wide privacy settings.

HIG: `privacy.md`

## Inclusion and right-to-left

- Design for the full range of bodies, abilities, cultures, and contexts; avoid stereotypes.
- Use leading/trailing instead of left/right so layouts mirror for right-to-left languages.
- Prefer system components that mirror automatically; test with a pseudolanguage and a RTL
  locale.

HIG: `inclusion.md`, `right-to-left.md`
