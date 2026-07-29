---
name: accio-computer-use
description: Operate native macOS applications with Accio's hybrid computer-use runtime—combine GUI observation and actions with Python, shell CLIs, APIs, and files, then verify the result. Use when a task requires interacting with a real macOS GUI on the host or mixing desktop actions with other execution routes.
---

# Accio Computer Use

`accio-computer-use` is the only public executable. Pipe Python directly into
it for the default hybrid interface; use `accio-computer-use code [options]`
when the block needs explicit limits or a custom daemon socket. Both forms run
one normal Python program with the desktop helpers already available as
functions.
Use Python itself for branching, parsing, local files, APIs, and reusable task
logic; use the preloaded helpers for desktop observation and interaction.

The coding interface requires the Accio local daemon plus effective
Accessibility and Screen Recording permissions. The local daemon is CLI
runtime infrastructure, not a Codex MCP registration. On a new installation or
after a connectivity failure, run `accio-computer-use doctor`, then require
`Daemon: running` from `accio-computer-use daemon-status` or a successful
coding call before executing the task. A loaded LaunchAgent or a socket file
alone is not daemon-health evidence.

## Start here

First, observe and hand the state back to the model:

```bash
accio-computer-use <<'PY'
state = get_app_state(app="Safari")
print(state.text)
emit({"screenshots": state.screenshot_paths})
PY
```

After this block exits, read the printed state. Inspect the emitted image when
visual information is needed to choose the target or method. Only then compose
the first action block:

```bash
accio-computer-use <<'PY'
result = click(app="Safari", element_text="Address")
result = type_text(app="Safari", text="https://example.com")
result = press_key(app="Safari", key="Return")

final = wait_for_element(
    app="Safari",
    element_text="Example Domain",
    timeout_seconds=10,
)
verified = get_app_state(app="Safari")
emit({
    "ax_candidate": "Example Domain" in final.text,
    "screenshots": verified.screenshot_paths,
})
PY
```

After the action block exits, call the host image reader on the final emitted
screenshot and wait for the image content before reporting completion. The
path alone is not verification.

In MCP mode, screenshots are returned as image content only when their artifact
paths are explicitly present in the value passed to `emit()`. This is why the
examples emit `state.screenshot_paths`. Merely calling an observation helper
does not attach every intermediate screenshot. The model receives the MCP
result only after the entire coding block has finished; it cannot inspect an
image or other output midway through the same block.

Keep one block focused on one coherent task or recovery attempt. Prefer a
single coding block over many shell invocations when steps share state.

## Optional MCP integration

Use this section only when the installed integration exposes Accio's coding
MCP server. Call its single `execute` tool with `{"code": "..."}` instead of
invoking the command through a shell. The Python block, helper API, observation
gates, disposable worker, and result envelope are the same. Server startup
flags own all budgets; never attempt to pass timeout, call, memory, output,
artifact, or trace limits as tool arguments.

Start the optional single-tool coding MCP with
`accio-computer-use code mcp`. The top-level `accio-computer-use mcp` is a
different, lower-level server that exposes individual desktop tools. Do not
infer that either MCP server is installed merely because the local daemon is
running.

## Initial observation gate

Before the first side effect of every task, run an observation-only block and
let it exit. Use `get_app_state(app=...)` when the relevant application is
known; use `get_screen_state()` when the visible desktop or application scope
must be discovered. Print the state needed for semantic reasoning and emit its
screenshot paths.

The model cannot inspect printed state while a coding block is still running.
Only after the model has read that returned state may it choose targets,
resolve task context, and compose code that changes external state. Calling an
observation helper without this handoff does not satisfy the gate. Initial
image inspection is required only when visual information affects the next
decision; sufficient AX or screen text can satisfy the semantic observation.

If the observation does not establish the target and scope, continue with
another observation-only block. Do not start from a process default, guessed
location, or assumed application state.

This gate applies to every execution route, including desktop helpers, shell
commands, Python libraries, scripts, and application APIs. Do not replace
observed task context with a process default, guessed location, or assumed
application state. Read-only signature discovery or diagnostics may precede
the gate, but they must not change external state.

## Discover the API from Python

Function parameters belong to the coding API. Never infer a parameter name,
default, or target form from another browser/GUI harness.

Before the first call to a helper, confirm that its exact signature is visible
in the current-version Interaction Skill or in runtime output. If it is not, or
if Python reports an unexpected argument, run a short discovery-only block and
let it exit before composing the action block:

```python
import inspect

for function in (click, type_text):
    print(function.__name__, inspect.signature(function))
    print(inspect.getdoc(function))
```

`help(function)` is an equivalent combined view. Do not call the desktop from
the discovery block when the call shape is still uncertain. Once the current
signature has been confirmed in this context, reuse that knowledge instead of
querying it before every call.

Each `accio-computer-use` coding block starts a new Python process. Imports, variables, and
caught exceptions from one block do not exist in the next block; only the
model's observed output and external desktop/file state carry across blocks.

The core preloaded functions are:

```text
list_apps              get_screen_state       get_app_state
click                  double_click           hover                  drag
perform_secondary_action                      press_key
scroll                 set_value              type_text
wait_for_element       menu_select
```

They are ordinary Python functions with keyword-only signatures and docstrings.
Python reports missing or unexpected parameters before a desktop call is sent.

Read [references/helper-api.md](references/helper-api.md) when you need a
single overview of every helper, parameter, default, target form, and short
example. Its signature lines and the Interaction Skill signature blocks are
test-synchronized with the Python functions. The runtime signature is
authoritative for accepted parameter names and defaults; use the current
Interaction Skill for workflow semantics and the runtime docstring as concise
supplementary context.

Each desktop call returns a `ToolResult`:

- `result.text` contains the textual state, diff, or error context.
- `result.is_error` is false for a normally returned result. Native error
  results are attached to the raised `ToolError` as `error.result`.
- `result.screenshot_paths` lists extracted screenshot files.
- `result.state` contains structured app/snapshot metadata when available;
  `result.snapshot_id` exposes its current snapshot ID without text parsing.
- `result.to_dict()` returns the processed result payload.

Native tool failures raise `ToolError`. Catch it only when the block has a
specific bounded recovery path, then inspect `error.result.text` or
`error.result.is_error`. Use `emit(value)` for the block's structured result;
use concise `print()` output for diagnostics.

## Use the observation returned by each action

Every mutating helper returns a post-action observation; do not treat it as a
bare acknowledgement. Its text depends on the action route:

- App-level actions contain a `[Result]` summary plus refreshed AX state.
  Daemon-backed sessions normally return `AXDIFF v1`; when a safe diff is not
  available, the native tool returns a full AX tree instead.
- Screen-level `click`/`double_click`/`drag` calls with `app` omitted contain an
  action summary plus refreshed `[Screen]` state, not an app AX tree.
- `result.screenshot_paths`, when non-empty, contains screenshot artifacts
  extracted from the same post-action result.

Within the running block, Python can inspect `result.text` and branch
programmatically. The model/host cannot see printed text or screenshots until
the block exits. Choose the handoff based on the next decision:

```python
result = click(app="TextEdit", element_text="Save")

# Let Python branch immediately when the condition is machine-checkable.
if "Save" in result.text and "changed=none" not in result.text:
    print("save action changed the app")

# For model reasoning after this block exits, expose concise AX/screen text.
print(result.text)

# For visual reasoning after this block exits, expose the artifact paths.
emit({"screenshots": result.screenshot_paths})
```

- Continue in the same block only for a pre-planned sequence or a condition
  Python can determine from `result.text`.
- Keep coherent field edits such as filling several related inputs in one
  block when Python can validate each result. Do not immediately click a
  Save/Done/Submit control in that same block unless its target is still
  known to be stable: after edits that may reveal, move, or replace a
  floating or conditional button, end the block, inspect the latest state or
  screenshot, then resolve the target from that post-edit state. A
  `stable_ref` may be reused only when the latest result confirms that it
  still identifies the same logical control; always refresh an index or
  coordinate.
- Use returned AX or `AXDIFF` state as the immediate validity check for a single
  action. At a stage or task boundary, AX is supporting evidence rather than
  completion proof.
- When the next step needs model semantic reasoning, print only the relevant AX
  or `[Screen]` lines and end the block; dumping a full tree wastes tokens.
- When the next step needs visual reasoning, emit the screenshot paths and end
  the block, then use the host's image-reading capability.
- When both signals matter, print concise text evidence and emit screenshot
  paths together before ending the block.
- At every stage or task completion boundary, expose and inspect the latest
  matching screenshot before reporting completion. The final action's returned
  screenshot is sufficient when it is current; otherwise observe again.
- Re-observe only when returned context is incomplete/stale, a new phase begins,
  or independent verification needs fresh state. Use `get_app_state()` after an
  app-level route and `get_screen_state()` after a screen-level route.

## Load interaction skills on demand

Read only the mechanic relevant to the current task:

- [interaction-skills/observation-and-targeting.md](interaction-skills/observation-and-targeting.md): app versus screen state, stable refs, indices, and snapshot freshness.
- [interaction-skills/clicking-and-coordinates.md](interaction-skills/clicking-and-coordinates.md): click and hover target modes, coordinate spaces, double-click, and no-change recovery.
- [interaction-skills/text-and-keyboard.md](interaction-skills/text-and-keyboard.md): choose `type_text` versus `set_value`, commit edits, and key syntax.
- [interaction-skills/scrolling-and-dragging.md](interaction-skills/scrolling-and-dragging.md): nested scroll regions, virtualized content, and literal drag coordinates.
- [interaction-skills/menus-and-secondary-actions.md](interaction-skills/menus-and-secondary-actions.md): menu paths, AX actions, activation, and transient context menus.
- [interaction-skills/waiting-and-verification.md](interaction-skills/waiting-and-verification.md): wait modes, result interpretation, and independent completion proof.
- [interaction-skills/framework-routing.md](interaction-skills/framework-routing.md): native versus Electron, Qt, Flutter, and CEF input delivery.

## Operating policy

Follow this loop:

```text
observe -> choose target -> act -> inspect returned state -> verify goal
```

1. Satisfy the initial observation gate before the task's first side effect.
2. Read the returned semantic state before choosing a target, method, or scope;
   inspect its screenshot when the decision depends on visual information.
3. Act with the strongest target available.
4. Use the action's returned AX state to check that the single step took effect;
   action helpers already refresh it.
5. Call `wait_for_element(...)` only when an asynchronous transition is still
   in progress.
6. At each stage or task boundary, inspect the latest screenshot and verify the
   goal before reporting completion.

Do not add a redundant observation after every action. Observe again when the
returned state is stale, an asynchronous update is pending, or a new phase of
the task begins.

## Choose targets

Prefer targets in this order:

1. `stable_ref` from the latest daemon-backed state, paired with
   `element_text` when available so a replaced AX node can safely fall back to
   text matching.
2. Visible `element_text`; add the latest `element_index` when disambiguation
   helps.
3. Coordinates read from the latest screenshot.

Never reuse an index or coordinate from an older state. Use `menu_select` for
application menu bars. Use coordinates for desktop UI, unlabeled visual
controls, or a transient context menu.

A `stable_ref` may cross snapshots only while the daemon can reconcile the
same logical element. Removed or replaced elements fail stale when used alone;
when paired with `element_text`, resolution may safely fall back to the current
matching text element. A supplied `snapshot_id` is a fail-closed precondition;
after any action, use the new result rather than reusing the prior snapshot ID.

If an action reports `changed=none`, do not blindly repeat it. Re-read the
returned state and change target or route: stable ref, text, menu path, direct
value setting, or coordinates.

## App state versus screen state

Use app-level state for controls owned by a known application:

```python
state = get_app_state(app="TextEdit")
print(state.text)
emit({"screenshots": state.screenshot_paths})
```

Use screen-level state for the menu bar, Dock, desktop, window layout, or UI
that has no useful app accessibility tree. The observation block must finish
before the host/model can open its screenshot:

```python
screen = get_screen_state()
emit({"screenshots": screen.screenshot_paths})
```

After reading that artifact, compose a new `accio-computer-use` block containing the
measured coordinates. A coding block cannot pause mid-execution for visual
inspection. Coordinates must come from the most recent matching screenshot.
Read
[interaction-skills/clicking-and-coordinates.md](interaction-skills/clicking-and-coordinates.md)
when coordinate spaces or app/screen coordinate routing are relevant.

## Wait and recover

Prefer `wait_for_element(...)` over `time.sleep(...)` for UI transitions. Keep
loops bounded and make each retry change something meaningful.

When a call fails:

1. Read the exception and its `ToolResult` when available.
2. Inspect the last returned AX state and screenshot.
3. Retry with a different target or interaction route.
4. Stop and reassess after repeated no-change results.

For context menus, do not insert another AX observation between opening the
menu and clicking its item. Read
[interaction-skills/menus-and-secondary-actions.md](interaction-skills/menus-and-secondary-actions.md)
before using one.

## Verification

Treat successful function return as delivery evidence, not goal completion.
Use returned AX or `AXDIFF` state to validate an individual action and as an
auxiliary observation of stage or task completion. Do not use AX alone as
completion proof.

Every completed stage and completed task requires visual verification. Expose
the latest matching screenshot, end the coding block, read the image with the
host, and compare the visible result with the goal before reporting completion.
Receiving or emitting a screenshot path is not visual verification. Require an
actual host image-reading call. Wait until image content has returned to the model.

For persistent outcomes, screenshot verification is required but insufficient.
Also read the durable state back through an independent route such as
application-native scripting or automation (including AppleScript or JXA), an
application or service API, filesystem inspection, or direct data-state
inspection. Require the visual result and durable readback to agree.

Read
[interaction-skills/waiting-and-verification.md](interaction-skills/waiting-and-verification.md)
for the detailed completion checklist and interpretation of `changed=` results.

## Confirmation boundary

Before sending, publishing, purchasing, deleting, submitting, overwriting, or
changing an account/system setting, show the exact pending action and obtain
explicit user approval. Reading, navigating, scrolling, and composing an
unsent draft do not require confirmation.

Keep confirmation-gated actions out of a coding block until approval has
already been received.

## Diagnostics and fallback

Run `accio-computer-use doctor` when permissions, screenshots, or daemon
connectivity fail. Use `accio-computer-use daemon-status` to verify a live
current-user listener; `doctor` reports the same connectivity signal alongside
permission and install diagnostics. Run `accio-computer-use code --help` for
execution limits and artifact options.

If terminal diagnostics show permissions granted but the persistent daemon is
unavailable after rebuilding, refresh Accio Computer Use in Accessibility and
Screen Recording, restart the menu bar helper, then run
`scripts/install-daemon.sh install`. Verify with `daemon-status`; do not infer
health from `launchctl print`, a plist, or a socket path alone.

If a shell reports that the internal Python runner is missing, resolve the
installed command through `PATH` and retry the coding smoke test:

```bash
ACCIO_CLI="$(command -v accio-computer-use)"
"$ACCIO_CLI" code --version
```

Do not hardcode a user-specific absolute path in workflows. Use
`ACCIO_COMPUTER_USE_CODING_RUNNER` only for deliberate source-checkout
development, not as the normal installed configuration.

If `DaemonUnavailableError` contains `[Errno 1] Operation not permitted`, do
not restart the daemon. The client command is running in a sandbox that blocks
Unix socket access. Re-run only the same `accio-computer-use` command outside
the sandbox, using the shell tool's `sandbox_permissions: "require_escalated"`
mode when available. Keep the approval scoped to that command; do not disable
the project sandbox globally, widen filesystem access, or register an MCP
server as a workaround. If escalation is unavailable, ask the user to run the
command in a normal Terminal session.

Use the direct CLI only to diagnose one isolated native tool call:

```bash
accio-computer-use call get_app_state '{"app":"Safari"}'
```

Read [references/direct-cli.md](references/direct-cli.md) for direct CLI output
and flags. Read
[interaction-skills/framework-routing.md](interaction-skills/framework-routing.md)
only when input delivery differs across native, Electron, Qt, Flutter, or CEF
apps.
