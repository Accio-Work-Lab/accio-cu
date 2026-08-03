# Observation and targeting

Relevant helpers:

```python
list_apps()
get_screen_state()
get_app_state(*, app)
```

## Parameter semantics

- `list_apps()` and `get_screen_state()` take no parameters.
- `get_app_state` requires keyword-only `app`: use an application name or
  bundle identifier, for example `app="Safari"` or
  `app="com.apple.Safari"`.
- All three functions return `ToolResult`; read `.text` for state.
  `get_app_state()` and `get_screen_state()` normally provide extracted image
  artifacts in `.screenshot_paths`; `list_apps()` normally does not.

Use `list_apps()` only when the app name or bundle identifier is unknown. Use
`get_app_state(app=...)` for controls owned by one app. Use
`get_screen_state()` for the menu bar, Dock, desktop, window arrangement, and
UI that has no useful app AX tree.

## Start an app-level phase

```python
state = get_app_state(app="TextEdit")
print(state.text)
emit({"screenshots": state.screenshot_paths})
```

Read the state summary, full AX tree, and snapshot ID first. Inspect the emitted
screenshot only when visual layout affects targeting or the semantic state is
insufficient; emitting a path does not require opening the image in CLI mode.
Prefer targets in this order:

1. `stable_ref` from the latest daemon-backed state.
2. `element_text`, optionally paired with the current `element_index`.
3. Coordinates from the latest matching screenshot.

`element_index` is ephemeral and can change after any UI update. A supplied
`snapshot_id` is a fail-closed precondition: a superseded or unknown
ID raises before the action. Mutating helpers then refresh and reconcile a
`stable_ref` only when it still identifies the same logical element. Never
reuse an index, snapshot ID, or coordinate after the UI has changed.

## Start a screen-level phase

```python
screen = get_screen_state()
print(screen.text)
emit({"screenshots": screen.screenshot_paths})
```

Inspect this screenshot because screen-coordinate targeting depends on visible
layout. Screen coordinates belong only to that main-display screenshot. Omit `app`
when passing them to `click`, `double_click`, or `drag`. `get_screen_state()`
does not capture secondary displays; move the target window to the main display
or use app-level AX/app-screenshot targeting for a window on another display.

## Avoid redundant observations

Mutating helpers already return refreshed state and screenshots. Read compact
feedback first; do not open every returned screenshot or call
`get_app_state()` again by default. Re-observe only when the current evidence
cannot resolve the next goal predicate, for example because the app identity
is not established, returned state is stale or incomplete, or an asynchronous
update is still pending. At task completion, obtain a new screenshot only when
the freshest matching artifact is absent, stale, or insufficient.
