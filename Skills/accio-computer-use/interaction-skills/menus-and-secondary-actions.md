# Menus and secondary actions

Relevant helpers:

```python
menu_select(*, app, path)
perform_secondary_action(*, app, action, stable_ref=None,
                         element_index: Optional[str] = None, element_text=None,
                         snapshot_id=None)
```

## Parameter semantics

- `menu_select` requires `app` and `path`. `path` is a non-empty list of menu
  labels from the top-level menu to the item, for example
  `["File", "Export as PDF..."]`; the parameter is not named `menu_path`.
- `perform_secondary_action` requires `app` and `action`. For an element,
  copy `action` exactly from that element's latest `actions=[...]`, such as
  `Open` or `Raise`; raw names such as `AXOpen` are also accepted, but do not
  invent an action.
- Identify the current element with `stable_ref`, or with `element_text` and an
  optional current `element_index`; pair `snapshot_id` with the state that
  supplied the target. `action="activate_app"` is app-level and needs no
  element target.

Read the complete parameter definitions in
[../references/helper-api.md](../references/helper-api.md).

## Application menu bars

Use `menu_select` for File, Edit, View, Window, Help, application menus, export,
preferences, and similar menu-bar actions:

```python
result = menu_select(app="Preview", path=["File", "Export as PDF..."])
```

Matching ignores case and treats `...` and `…` as equivalent. If a path segment
is missing, print the error's available items and end the coding block. Do not
precompute several speculative menu paths in one block. Retry in the next block
with an exact returned label after resolving its semantics; independently read
back state when labels such as `Fast` do not encode the requested value.

## Secondary AX actions

Use `perform_secondary_action` only for an action advertised in the element's
AX state, such as `Open` or `Raise`:

```python
result = perform_secondary_action(
    app="Finder",
    stable_ref="a12",
    action="Open",
)
```

`action="activate_app"` explicitly brings the target app frontmost. Use it
only when final foreground state matters or a framework cannot receive the
required input in the background.

## Transient context menus

An AX tree walk may dismiss an open right-click menu. Use screen-level
coordinates for the entire transient-menu sequence. This is a three-invocation
workflow because each screenshot must be inspected by the host/model after its
coding block exits:

1. In an observation block, call `get_screen_state()` and emit its screenshot
   paths. After the block exits, locate the target in the main-display
   screenshot.
2. In a new block containing the measured numeric coordinates, right-click with
   `click(x=TARGET_X, y=TARGET_Y, mouse_button="right")` and no `app`. Emit
   the returned screenshot paths, let the block exit, then inspect that PNG.
3. In a third block, immediately call
   `click(x=MENU_ITEM_X, y=MENU_ITEM_Y)` with the measured menu-item coordinates
   and no `app`. Do not make an intervening daemon observation.

```python
# Invocation 1: observe, then let the block exit and inspect the artifact.
screen = get_screen_state()
emit(screen.screenshot_paths)
```

```python
# Invocation 2: replace TARGET_X/TARGET_Y with measured numbers before running.
opened = click(x=TARGET_X, y=TARGET_Y, mouse_button="right")
emit(opened.screenshot_paths)
```

```python
# Invocation 3: run immediately after reading Invocation 2's PNG.
selected = click(x=MENU_ITEM_X, y=MENU_ITEM_Y)
emit(selected.to_dict())
```

Do not include `app` in either context-menu click. App screenshot coordinates
and main-display coordinates have different origins, and an app-level AX walk
can dismiss the menu.

Reading a local PNG between invocations is safe; do not call `get_screen_state`,
`get_app_state`, `wait_for_element`, or any element-targeted helper between the
right-click and menu-item click. Do not guess fixed row heights; separators,
theme, display scale, and click location change the menu geometry.
