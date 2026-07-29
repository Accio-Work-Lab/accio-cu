# Clicking and coordinates

Relevant helpers:

```python
click(*, app=None, stable_ref=None, element_index: Optional[str] = None, element_text=None,
      snapshot_id=None, x=None, y=None, coordinate_space=None,
      click_count=1, mouse_button="left")
double_click(*, app=None, stable_ref=None, element_index: Optional[str] = None,
             element_text=None, snapshot_id=None, x=None, y=None,
             coordinate_space=None, mouse_button="left")
hover(*, app, stable_ref=None, element_index: Optional[str] = None, element_text=None,
      snapshot_id=None, x=None, y=None, coordinate_space=None)
```

## Parameter semantics

- Choose one target family: an AX target (`stable_ref`, or `element_text` with
  optional `element_index`), or a coordinate pair (`x` and `y`).
- `app` is the app name/bundle ID for AX targets and app-screenshot
  coordinates. Omit it only for main-display coordinates from
  `get_screen_state()`.
- `stable_ref` is the preferred current AX identity. Pair it with
  `element_text` when possible so a replaced AX node can safely fall back to
  text matching. `element_index` is an optional string such as `"12"`, not an
  integer; it is ephemeral, so pair it with `element_text` to let stale indices
  fall back to text matching.
  `snapshot_id` is an optional fail-closed precondition from the latest result;
  a superseded or unknown ID raises before `click` refreshes and
  resolves the target.
- `x` and `y` must be supplied together and must come from the latest matching
  screenshot. `coordinate_space` is `pixel`, `normalized_1000`, or
  `normalized_1`; omission uses the daemon/session default.
- `click_count` is 1, 2, or 3. `mouse_button` is `left`, `right`, or `middle`.
  `double_click` fixes the count at 2, so it has no `click_count` parameter.
- `hover` keeps the pointer over the target so hover-driven menus and child
  content remain available for the next action.

Read the complete parameter definitions in
[../references/helper-api.md](../references/helper-api.md).

## Choose one targeting mode

Prefer AX targets:

```python
result = click(
    app="TextEdit",
    stable_ref="a12",
    element_text="Save",
)
```

Use visible text when stable refs are unavailable:

```python
result = click(app="TextEdit", element_text="Save")
```

Use app coordinates only from the latest app screenshot, and screen coordinates
only from the latest `get_screen_state()` screenshot:

```python
result = click(app="Safari", x=app_x, y=app_y)
result = click(x=screen_x, y=screen_y)
```

## Coordinate spaces

- `pixel`: raw screenshot pixels.
- `normalized_1000`: 0–1000 on both axes.
- `normalized_1`: 0–1 on both axes.

Omit `coordinate_space` to use the daemon/session default. Declare it explicitly
when the model emits normalized coordinates. A consistent large offset usually
means the screenshot and call use different coordinate spaces.

## Read the result

Element-targeted clicks prefer native AX actions. Screen-level coordinates may
AX-snap to an actionable element under the point before falling back to an input
event. App-level coordinates use the app input fallback directly and do not
currently AX-snap. Inspect the returned `[Result]` and screenshot. If
`changed=none`, change target or route instead of repeating the same click.
If the control may reveal content without activation, use `hover(...)`,
inspect its returned state, and then target the revealed child.

When a coordinate comes from visual inspection, finish the observation block,
open its screenshot artifact, then compose a new block with the measured
number. `accio-computer-use` executes stdin in one pass and cannot pause halfway for
the model to inspect a PNG.

Use `double_click(...)` rather than manually issuing two calls. It sends a
real two-click pointer sequence; it does not substitute an AX `Open` action. Use
`mouse_button="right"` only when opening a context menu, then follow
[menus-and-secondary-actions.md](menus-and-secondary-actions.md).
