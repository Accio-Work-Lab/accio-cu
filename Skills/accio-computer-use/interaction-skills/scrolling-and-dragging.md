# Scrolling and dragging

Relevant helpers:

```python
scroll(*, app, direction, stable_ref=None, element_index: Optional[str] = None,
       element_text=None, snapshot_id=None, pages=1)
drag(*, from_x, from_y, to_x, to_y, app=None, coordinate_space=None)
```

## Parameter semantics

- `scroll` requires `app` and `direction`; direction is `up`, `down`, `left`,
  or `right`. `pages` defaults to 1, accepts positive fractional values, and is
  limited to 20 per call.
- The optional `stable_ref`, `element_index`, and `element_text` select a
  current nested scroll region. `snapshot_id` is an optional fail-closed
  precondition; it does not select a region. Omit the three selectors to use the largest
  scrollable region.
- `drag` requires all four endpoint values: `from_x`, `from_y`, `to_x`, and
  `to_y`. Include `app` for app-screenshot coordinates; omit it for
  main-display coordinates.
- `coordinate_space` applies to all four drag values and is `pixel`,
  `normalized_1000`, or `normalized_1`. Drag endpoints do not accept AX target
  parameters.

Read the complete parameter definitions in
[../references/helper-api.md](../references/helper-api.md).

## Scroll the right container

Without a target, `scroll` chooses the largest scrollable area:

```python
result = scroll(app="Safari", direction="down", pages=0.5)
```

Target a nested list or pane when the main window is not the intended consumer:

```python
result = scroll(
    app="Finder",
    direction="down",
    element_text="file list",
    pages=1,
)
```

Accio tries AX page actions, targeted wheel delivery, and keyboard fallback.
Inspect the returned state to confirm content moved. In virtualized lists,
element identities may change after scrolling; use the new state before the
next action.

Prefer in-app search over repeated scrolling when the UI exposes search.

## Drag with literal coordinates

`drag` does not accept an AX target, auto-scroll, or snap endpoints. Both points
must come from the same latest screenshot and coordinate space:

```python
result = drag(
    app="Finder",
    from_x=source_x,
    from_y=source_y,
    to_x=destination_x,
    to_y=destination_y,
)
```

Omit `app` only for screen-level dragging from a `get_screen_state()`
screenshot. Verify both the visible result and the app/file state after a drag.
