## Coordinates: points vs. pixels, and the second conversion

Gestures take **points**. Screenshots come back in **pixels** — points × device
scale, typically 3× on a modern iPhone. `take_screenshot` reports both sizes;
read them from the result instead of assuming a scale factor.

`tap` accepts `unit=pixels` (use a position straight off a screenshot) and
`unit=normalized` (a 0..1 fraction of the screen), which handles the conversion
for you.

The trap `unit=pixels` does *not* save you from: when you eyeball a coordinate
off an image **as it was rendered to you**, the viewer may have downscaled it
first. That needs two conversions, in order:

1. displayed pixel → original image pixel (multiply by the ratio the viewer reported)
2. original image pixel → points (divide by the device scale) — or skip this one by passing `unit=pixels`

Skipping step 1 taps the wrong place **and still reports success**: a tap that
hits no control is not an error. So a "successful" tap that changed nothing is
this bug until proven otherwise — verify with `describe_screen`, don't assume.

`find_elements` reports each match's centre in points, ready to hand to `tap` —
for unlabeled elements as well as named ones. Prefer it over reading pixels off
an image in every case: it skips both conversions and the guesswork with them.

## Unlabeled, icon-only controls

A close (X) button with neither label nor identifier — common in third-party SDK
paywalls and bare SF Symbol buttons — matches no selector, so `tap_element`,
`assert_visible`, and `find_element_by_description` cannot reach it. (That last
one, despite the name, is text matching over labels and identifiers, not vision.)

`find_elements` **with no selector** is the way in. It lists everything on
screen, unlabeled elements included, rendered as `[unlabeled] <type> at (x,y) pts
WxH`:

```sh
amoo device --platform ios --device <udid> find_elements
```

Named elements come first, then the unlabeled ones smallest-first — a small leaf
near the top of a sheet is almost always the icon button, a large one is the
backdrop. Tap the reported centre directly; it is already in points, so no
conversion and no screenshot:

```sh
amoo device --platform ios --device <udid> tap x=349 y=118
```

Pass `labeled_only=true` to get the old named-only listing when the full one is
noisy.

Two things worth trying before falling back to a coordinate:

- Guess the identifier: `find_elements id=close`, `contains_text=close`. App
  teams often set one even when the label is empty, and a named element stays
  correct when the layout shifts.
- If the control belongs to the app under test rather than a vendor SDK, the real
  fix is an `accessibilityIdentifier` on it — worth reporting back to the team.

Verify with `describe_screen` after the tap. A coordinate tap that hit nothing
still reports success.
