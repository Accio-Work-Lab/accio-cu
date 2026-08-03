# Waiting and verification

Relevant helper:

```python
wait_for_element(*, app, element_text=None, wait_mode="element_text",
                 timeout_seconds=10, poll_interval=0.5)
```

## Parameter semantics

- `app` is required. `element_text` is a case-insensitive substring and is
  required for every `wait_mode` except `element_count_changed`.
- `wait_mode` is `element_text`, `window_title_contains`,
  `element_count_changed`, or `focused_value_contains`; it defaults to
  `element_text`.
- `timeout_seconds` defaults to 10 and accepts 1–30 seconds. `poll_interval`
  defaults to 0.5 and accepts 0.1–2.0 seconds.
- A timeout returns a native error result, so the coding harness raises
  `ToolError`; inspect `error.result.text` only inside a bounded recovery path.
- A successful wait returns matching textual AX state but no screenshot. At
  task completion, use the freshest matching screenshot already returned by a
  mutation; call `get_app_state()` only when no current screenshot shows the
  result.

Read the complete parameter definitions in
[../references/helper-api.md](../references/helper-api.md).

## Wait for a state signal

Use the narrowest AX signal that represents readiness or expected state change:

- `element_text`: a label/value appears in the AX tree.
- `window_title_contains`: a document/window title updates.
- `element_count_changed`: navigation or a list changes structure; this mode
  does not require `element_text`. Its baseline is captured when the wait call
  begins, so use it only while a later structural change is still expected.
- `focused_value_contains`: the focused input value settles.

```python
final = wait_for_element(
    app="Safari",
    element_text="Example Domain",
    wait_mode="element_text",
    timeout_seconds=10,
)
```

Use this instead of `time.sleep()` for asynchronous UI. A successful wait is an
AX state signal, not complete-task proof. Keep retry loops bounded and change
the target or route after a no-change result.

## Interpret action results

- `changed=confirmed`: value or structural change was confirmed.
- `changed=structureOnly`: structure changed but the semantic outcome remains
  uncertain.
- `changed=unverifiable`: input was delivered but AX cannot prove the effect.
- `changed=none`: no detectable effect; do not blindly repeat the action.

## Verify completion with sufficient evidence

Use AX or `AXDIFF` to validate whether a single step took effect. Before
reporting task success, apply this checklist:

1. State the remaining goal predicate that needs proof.
2. Use the latest matching screenshot from the final action, or obtain one
   fresh observation only if the current artifact is stale or insufficient.
3. End the coding block and inspect that screenshot with the host's
   image-reading capability.
4. Use AX values, labels, window titles, and diffs as supporting semantic
   evidence, not as a replacement for the screenshot.
5. For a persistent outcome, add a durable readback only when the runtime,
   loaded domain skill, or task context already declares a semantically
   independent route. Never invent a new integration only for verification.
6. Continue investigating whenever the available evidence disagrees.

Do not report a task complete from `changed=confirmed`, a matching AX value, or
a successful helper return alone.
