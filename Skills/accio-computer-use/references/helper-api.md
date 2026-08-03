# Preloaded helper API

This is the compact reference for all functions preloaded when Python is piped
into `accio-computer-use`.
The executable Python functions in `coding/accio_cu_code/helpers.py` are the
authority. If this reference and runtime disagree, use `help(function)` and
`inspect.signature(function)`.

## Contents

- [Result and control helpers](#result-and-control-helpers)
- [Observation](#observation)
- [Clicking and dragging](#clicking-and-dragging)
- [Text and keyboard](#text-and-keyboard)
- [Scrolling](#scrolling)
- [Menus and secondary actions](#menus-and-secondary-actions)
- [Waiting](#waiting)

## Result and control helpers

Every native helper returns `ToolResult` on success:

- `.text`: textual state, AX diff, or status.
- `.screenshot_paths`: extracted screenshot artifact paths.
- `.state`: structured state metadata when the helper returned an app snapshot.
- `.snapshot_id`: structured shortcut for `.state.get("snapshot_id")`.
- `.to_dict()`: processed MCP-style result without inline image data.
- `.is_error`: false for a normally returned result.

Native errors raise `ToolError`; inspect `error.result.text`,
`error.result.is_error`, and `error.result.screenshot_paths` in a bounded
recovery path.

`emit(value)` sets the structured `value` in the final `accio.coding.v1`
envelope. `print(...)` is captured as diagnostic `stdout`.

```python
try:
    state = get_app_state(app="Safari")
except ToolError as error:
    emit({"error": error.result.text})
else:
    emit({"observed": bool(state.text)})
```

## Observation

### `list_apps`

Signature: `list_apps()`

List running and recently used GUI applications. It takes no parameters.

```python
apps = list_apps()
print(apps.text)
```

### `get_screen_state`

Signature: `get_screen_state()`

Capture the main display, visible window bounds, frontmost application, and
hidden/minimized application summary. Coordinates from its screenshot are for
screen-level `click`, `double_click`, and `drag` calls that omit `app`.

```python
screen = get_screen_state()
print(screen.text)
emit({"screenshots": screen.screenshot_paths})
```

### `get_app_state`

Signature: `get_app_state(*, app)`

Parameters:

- `app` (required string): application name or bundle identifier.

Capture the app's current AX tree, stable refs when available, snapshot ID, and
screenshot. Use it to begin an app-level phase; the native resolver may
background-launch the app when it is not running.

```python
state = get_app_state(app="TextEdit")
print(state.text)
```

## Clicking and dragging

### `click`

Signature: `click(*, app=None, stable_ref=None, element_index: Optional[str] = None, element_text=None, snapshot_id=None, x=None, y=None, coordinate_space=None, click_count=1, mouse_button='left')`

Parameters:

- `app` (optional string): app name/bundle ID. Omit only for main-display
  screen coordinates.
- `stable_ref` (optional string): daemon-session AX identity. It survives new
  snapshots while the same logical element can be reconciled; removed or
  replaced elements become stale and are never silently retargeted.
- `element_index` (optional string): ephemeral AX index from the latest state.
- `element_text` (optional string): case-insensitive visible-label substring.
- `snapshot_id` (optional string): optimistic-concurrency precondition from the
  latest returned state. A superseded or unknown ID raises an error
  before the action. The action still refreshes before resolving its target.
- `x`, `y` (optional numbers): target coordinates; both are required together.
- `coordinate_space` (optional string): `pixel`, `normalized_1000`, or
  `normalized_1`. Omit to use the daemon/session default.
- `click_count` (integer, default `1`): valid values are 1–3.
- `mouse_button` (string, default `left`): `left`, `right`, or `middle`.

Valid target forms:

```python
click(app="TextEdit", stable_ref="a12", element_text="Save")
click(app="TextEdit", element_text="Save")
click(app="Safari", x=420, y=180)
click(x=900, y=740)  # screen coordinates from get_screen_state()
```

When using an element, pair `stable_ref` with `element_text` when possible; if
the AX node is replaced, the current matching text element is used. Otherwise,
use `element_text` with the current `element_index` when helpful. Coordinates
must come from the latest matching app/screen screenshot.

### `double_click`

Signature: `double_click(*, app=None, stable_ref=None, element_index: Optional[str] = None, element_text=None, snapshot_id=None, x=None, y=None, coordinate_space=None, mouse_button='left')`

This convenience function has the same targeting parameters as `click` and
calls it with `click_count=2`.

```python
double_click(app="Finder", element_text="Documents")
```

### `hover`

Signature: `hover(*, app, stable_ref=None, element_index: Optional[str] = None, element_text=None, snapshot_id=None, x=None, y=None, coordinate_space=None)`

Moves the pointer over an app element or coordinate and leaves it there. Use
this for controls that reveal menus, tooltips, or child content on hover. The
result contains refreshed app state and a screenshot.

### `drag`

Signature: `drag(*, from_x, from_y, to_x, to_y, app=None, coordinate_space=None)`

Parameters:

- `from_x`, `from_y` (required numbers): starting coordinates.
- `to_x`, `to_y` (required numbers): ending coordinates.
- `app` (optional string): include for app-screenshot coordinates; omit for
  main-display coordinates from `get_screen_state()`.
- `coordinate_space` (optional string): `pixel`, `normalized_1000`, or
  `normalized_1`.

Drag uses literal coordinates and does not target an AX element or auto-scroll.

```python
drag(app="Finder", from_x=320, from_y=240, to_x=720, to_y=240)
```

## Text and keyboard

### `type_text`

Signature: `type_text(*, app, text, stable_ref=None, element_index: Optional[str] = None, element_text=None, snapshot_id=None)`

Parameters:

- `app` (required string): target app.
- `text` (required string): text to enter.
- `stable_ref`, `element_index`, `element_text`: optional current element target.
  `snapshot_id` is an optional fail-closed precondition. Omit all target fields
  to type into the current focus.

Use when the app needs typing/input events or the element is not AX-settable.

```python
type_text(app="Safari", text="query", element_text="Search")
```

### `set_value`

Signature: `set_value(*, app, value, stable_ref=None, element_index: Optional[str] = None, element_text=None, snapshot_id=None)`

Parameters:

- `app` (required string): target app.
- `value` (required string): new AX value.
- `stable_ref`, `element_index`, `element_text`: selector fields default to
  `None`, but `set_value` needs a resolvable current element target.
  Prefer `stable_ref`; otherwise use `element_text` with the current
  `element_index` when helpful.
- `snapshot_id`: optional fail-closed precondition from the latest state.

Use for direct replacement in string-valued AX-settable fields. Numeric sliders
and controls whose AX value is not a string are not currently supported. Some
apps require Return, clicking away, or a Save/Done action to commit the value.
The native boundary rejects `value=""`; clear a field by focusing it, selecting
all, and pressing Backspace.

```python
set_value(app="Safari", value="https://example.com", element_text="Address")
```

### `press_key`

Signature: `press_key(*, app, key)`

Parameters:

- `app` (required string): target app.
- `key` (required string): key or modifier combination.

Join modifiers with `+`: `super+s`, `super+shift+s`, `ctrl+a`, `option+Down`.
Special keys include `Return`, `Tab`, `Escape`, `space`, `backspace`, `delete`,
arrow keys, `Home`, `End`, `pageup`, `pagedown`, and `F1`–`F12`.

```python
press_key(app="TextEdit", key="super+s")
```

## Scrolling

### `scroll`

Signature: `scroll(*, app, direction, stable_ref=None, element_index: Optional[str] = None, element_text=None, snapshot_id=None, pages=1)`

Parameters:

- `app` (required string): target app.
- `direction` (required string): `up`, `down`, `left`, or `right`.
- `stable_ref`, `element_index`, `element_text`: optional current scroll-region
  target.
- `snapshot_id` (optional string): fail-closed precondition; it does not select
  a region.
- `pages` (positive number, default `1`): amount to scroll; fractional values
  are allowed, with a native maximum of 20 per call.

Without an element target, Accio chooses the largest scrollable region.

```python
scroll(app="Safari", direction="down", pages=0.5)
```

## Menus and secondary actions

### `menu_select`

Signature: `menu_select(*, app, path)`

Parameters:

- `app` (required string): target app.
- `path` (required list of strings): menu hierarchy from top-level menu to
  final item.

Matching ignores case and treats `...` and `…` as equivalent. Use this for app
menu bars, not transient right-click menus.

```python
menu_select(app="Preview", path=["File", "Export as PDF..."])
```

### `perform_secondary_action`

Signature: `perform_secondary_action(*, app, action, stable_ref=None, element_index: Optional[str] = None, element_text=None, snapshot_id=None)`

Parameters:

- `app` (required string): target app.
- `action` (required string): copy the latest value advertised in the element's
  `actions=[...]`, such as `Open` or `Raise`. Raw `AXOpen`/`AXRaise` forms are
  accepted; `activate_app` is the explicit foreground action.
- `stable_ref`, `element_index`, `element_text`: optional current element target.
- `snapshot_id`: optional fail-closed precondition from the state that supplied
  the target.

```python
perform_secondary_action(
    app="Finder",
    stable_ref="a12",
    action="Open",
)
```

For a transient right-click menu, use the screen-level sequence in
[../interaction-skills/menus-and-secondary-actions.md](../interaction-skills/menus-and-secondary-actions.md)
instead of opening it through an app-level AX walk.

## Waiting

### `wait_for_element`

Signature: `wait_for_element(*, app, element_text=None, wait_mode='element_text', timeout_seconds=10, poll_interval=0.5)`

Parameters:

- `app` (required string): app to poll.
- `element_text` (optional string): substring used by all modes except
  `element_count_changed`.
- `wait_mode` (string, default `element_text`): `element_text`,
  `window_title_contains`, `element_count_changed`, or
  `focused_value_contains`.
- `timeout_seconds` (positive number, default `10`): maximum 30 seconds.
- `poll_interval` (positive number, default `0.5`): 0.1–2.0 seconds.

A successful wait contains textual AX state but no screenshot artifact. Call
`get_app_state()` afterward when visual verification is required.

```python
final = wait_for_element(
    app="Safari",
    element_text="Example Domain",
    timeout_seconds=10,
)
emit({"verified": "Example Domain" in final.text})
```
