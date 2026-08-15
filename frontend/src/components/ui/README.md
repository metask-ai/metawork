# Foundation UI

Headless Base UI primitives wrapped with token-based default styling. The
library defines resting shapes on its own terms; product surfaces adapt to the
library, not the other way around.

## Customization contract

- Customize exclusively through Tailwind utilities passed via `className`.
  `cn()` runs tailwind-merge, so a consumer utility deterministically replaces
  the conflicting default utility.
- Product stylesheets must not override a component's positioning properties
  (`position`, `inset`, `translate`, `transform`, `scale`, `rotate`) with
  custom classes. Custom-class overrides bypass tailwind-merge and depend on
  which CSS properties the default utilities compile to — an internal detail
  that changes (Tailwind v4 moved translate/scale/rotate utilities off
  `transform`).
- If a surface needs a shape the library does not provide, add the shape here
  as a preset (`Dialog` is the centered modal, `Drawer` the edge panel) rather
  than bending an existing preset from product CSS.

## Overlay presets

- `Dialog` — centered modal, scale/opacity transition.
- `AlertDialog` — centered confirmation, no light dismiss.
- `Drawer` — edge-anchored panel (`side="right" | "left"`), translate
  transition, `Header`/`Body`/`Footer` slots own the scroll layout.

## Field and status presets

- `SearchField` — framed search input; container owns the frame and focus
  formula, consumers size it through `className` utilities.
- `Alert` — inline status surface with `variant="neutral" | "warning" |
  "danger"`; the variant owns tone surface/border/content, consumers own
  layout.
