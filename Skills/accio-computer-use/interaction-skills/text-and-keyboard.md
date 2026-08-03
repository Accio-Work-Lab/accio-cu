# Text and keyboard

Relevant helpers:

```python
type_text(*, app, text, stable_ref=None, element_index: Optional[str] = None,
          element_text=None, snapshot_id=None)
set_value(*, app, value, stable_ref=None, element_index: Optional[str] = None,
          element_text=None, snapshot_id=None)
press_key(*, app, key, count=1)
```

## Parameter semantics

- `app` is required for all three helpers and accepts an app name or bundle ID.
- `type_text` requires `text` and always inserts through keyboard events;
  `set_value` requires `value` and directly replaces a string-valued AX value.
- `stable_ref`, `element_index`, and `element_text` identify a current element.
  `snapshot_id` is an optional fail-closed precondition from the state that
  supplied it. Prefer `stable_ref`; otherwise pair the current
  `element_index` with `element_text`. `type_text` may omit all target fields to
  use current focus. `set_value` still needs a resolvable element target even
  though its selector parameters default to `None` in Python.
- `press_key` accepts `app`, `key`, and an optional positive `count` up to 100.
  Encode modifiers inside `key`, such as `super+shift+s`.
- `set_value(value="")` is rejected by the native boundary. To clear a field,
  target/click it, send `super+a`, then send `backspace`.

Read the complete parameter definitions in
[../references/helper-api.md](../references/helper-api.md).

## Choose between `set_value` and `type_text`

Use `set_value` to replace the value of an AX-settable field directly:

```python
result = set_value(
    app="Safari",
    element_text="Address",
    value="https://example.com",
)
```

Use `type_text` when the app needs typing/input events, the field is not
AX-settable, or text should be inserted at the current selection:

```python
result = type_text(app="TextEdit", text="Hello", element_text="Text Area")
```

`type_text` never writes AXValue directly. `result.route` identifies the
keyboard delivery route and `result.changed` reports whether the action was
confirmed, unverifiable, or produced no detectable change.

When no element target is supplied, `type_text` uses the current focused
element. Prefer an explicit current target when focus is uncertain.

## Commit edits

Some applications keep an edited field pending. Commit using the interaction
the app expects:

```python
set_value(app="Safari", element_text="Address", value="https://example.com")
press_key(app="Safari", key="Return")
```

Other apps require clicking Done/Save or moving focus. Prefer `Return` or
another stable commit path when the app accepts it. If you must click a
Save/Done/Submit control, resolve it from the latest returned state or a fresh
screenshot after the edit — especially when the button is floating, sticky,
or only appears after validation. Do not reuse a pre-edit index or coordinate.
Reuse a `stable_ref` only when the latest result confirms that it still
identifies the same logical control; otherwise resolve a fresh target. Verify
the field value or resulting application state rather than assuming the write
persisted.

## Key syntax

Join modifiers with `+`, for example `super+s`, `super+shift+s`, `ctrl+a`, or
`option+Down`. Use named special keys such as `Return`, `Tab`, `Escape`,
`backspace`, `delete`, `Up`, `Down`, `Home`, `End`, `pageup`, and `pagedown`.
Both `backspace` and `delete` mean backward delete; use `del` or
`forwarddelete` for forward delete.

For repeated navigation, send one bounded batch and verify the final selection:

```python
press_key(app="Finder", key="Down", count=20)
```

If a shortcut returns no change in Electron/Qt/Flutter apps, use a directly
targeted click, `menu_select`, or `set_value` before considering activation.
