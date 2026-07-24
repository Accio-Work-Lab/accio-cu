# Framework routing

The Python helper API stays the same across macOS application frameworks, but
the native service may use different delivery routes.

| App family | Typical route |
|---|---|
| Native macOS | AX actions, then targeted background events |
| Electron/Chromium | AX, targeted events, then activation fallback |
| Qt/Flutter/CEF | Activation-based input when background delivery fails |

If a shortcut produces no change in a cross-platform app:

1. Prefer an AX-targeted `click`.
2. Use `menu_select` for app menus.
3. Use `set_value` for AX-settable fields.
4. Use `perform_secondary_action(app=..., action="activate_app")` only when
   the task or delivery route actually requires foreground activation.

Always inspect the returned state. Framework fallback delivery is not proof
that the requested semantic action succeeded.
