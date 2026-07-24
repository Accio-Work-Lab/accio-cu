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
- A successful wait returns matching textual AX state but no screenshot. If the
  wait reaches a stage/task boundary, follow it with `get_app_state()` to obtain
  the visual artifact required for verification.

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

## Verify completion independently

Use AX or `AXDIFF` to validate whether a single step took effect. At a stage or
task boundary, treat AX as auxiliary evidence and apply this checklist before
reporting success:

1. Expose the latest matching screenshot from the final action or a fresh
   observation.
2. End the coding block and inspect that screenshot with the host's image-reading
   capability. Every completed stage and task requires this visual check.
3. Use AX values, labels, window titles, and diffs as supporting semantic
   evidence, not as a replacement for the screenshot.
4. For a persistent outcome, independently read back the durable application,
   file, or data state. Valid routes include AppleScript or JXA, an application
   or service API, filesystem inspection, and direct data-state inspection.
5. Continue investigating whenever visual, AX, and durable-state evidence
   disagree.

Do not report a stage or task complete from `changed=confirmed`, a matching AX
value, or a successful helper return alone.
