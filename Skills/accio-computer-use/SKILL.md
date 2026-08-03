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
emit({"ax_candidate": "Example Domain" in final.text})
PY
```

After a block containing a desktop mutation exits, read its result envelope.
Inspect the compact feedback first, including `execution_feedback.notifications`
and `latest_observation`. Do not open its screenshot by default. When the
feedback resolves the fact needed for the next decision, continue from that
fresh semantic state. In CLI mode the latest screenshot is available at
`latest_observation.screenshot.path`; in coding MCP mode the same trusted PNG is
attached automatically. Only inspect the screenshot when it can resolve a
remaining visual question or when verifying the user-visible task result.
The state and screenshot are independent evidence: compare
`state_source_call_index` with `screenshot_source_call_index` and their
freshness fields. When their sources differ, do not assume that screenshot
depicts that state; capture a new matching screenshot only if the unresolved
predicate needs visual proof.
Before reporting completion, wait for the required image content; a path alone
is not verification.

An observation-only block has no automatic image handoff, so explicitly emit
the screenshot paths needed by the model, as in the first example. `emit()`
also remains the way to return a specific earlier or additional screenshot.
When an emitted image is already the automatic latest screenshot, MCP returns
it only once. MCP verifies the captured artifact digest and does not inline an
image set larger than the 32 MiB aggregate delivery budget. The model receives
the result only after the entire coding block
has finished; it cannot inspect an image or other output midway through the
same block.

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
- `result.route` and `result.changed` expose validated structured action
  metadata when the native action supplies it.
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
programmatically. Without `print()` or `emit()`, the full AX text remains
inside the block. The compact block envelope still returns mutation counts,
the latest post-action state and screenshot path, and important notifications
such as `no_ax_change`, `unverifiable`, or `action_error`. `no_ax_change`
means the accessibility snapshot did not confirm a change; inspect the screenshot
before concluding that nothing visible happened. Choose any additional
handoff based on the next decision:

```python
result = click(app="TextEdit", element_text="Save")

# Let Python branch immediately when the condition is machine-checkable.
if "Save" in result.text and "changed=none" not in result.text:
    print("save action changed the app")

# For model reasoning after this block exits, expose only relevant lines.
for line in result.text.splitlines():
    if line.startswith("[Result]") or "Save" in line:
        print(line)

# No emit is needed for this latest mutation screenshot. In CLI mode read
# execution_feedback.latest_observation.screenshot.path; MCP attaches it.
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
  action. At task completion, AX is supporting evidence rather than completion
  proof.
- When compact feedback confirms a routine action and the next semantic target
  is already known, continue without opening the screenshot. Screenshot
  availability is not an instruction to inspect it.
- When the next step needs model semantic reasoning, print only the relevant AX
  or `[Screen]` lines and end the block; dumping a full tree wastes tokens.
- Only inspect the screenshot when the next step depends on visual layout or
  coordinates; feedback reports `no_ax_change` or `unverifiable`; an error or
  incomplete/stale semantic state leaves a relevant fact unresolved; or the
  task is ready for final visual verification. Use `emit()` only for an
  additional or observation-only screenshot.
- When both signals matter, print concise text evidence; the latest mutation
  screenshot is handed off automatically.
- At task completion, inspect the freshest matching screenshot once before
  reporting success. In CLI mode read the reported path; in MCP mode read the
  attached image. Observe again only when that evidence is stale or does not
  show the goal.
- Re-observe only when the current evidence cannot resolve a fact required for
  the next decision or completion claim.

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
6. At task completion, inspect the freshest matching screenshot and verify the
   user-visible goal before reporting success.

## Evidence sufficiency

Before requesting another observation, name the unresolved goal predicate: the
specific fact still needed to choose the next action or support completion.

1. If the fresh result resolves that predicate, continue or stop. Do not
   observe again merely because another observation route exists.
2. Otherwise choose one observation that can resolve the missing fact. Prefer
   the narrowest suitable semantic or visual signal.
3. Never observe when it adds no new evidence over the current result. A new
   screenshot, AX tree, or readback is useful only if it can change the next
   decision or completion judgment.
4. At task completion, verify the user-visible goal once with the freshest
   matching screenshot. Re-capture only when it is stale, missing, or does not
   show the relevant result.
5. Use another execution route only when the runtime, a loaded domain skill, or
   the task context declares it available and it provides semantically
   independent evidence. Do not invent an integration solely to manufacture
   verification.

An action return, `execution_feedback`, AX state, a screenshot, and a durable
readback are evidence sources, not mandatory steps. Select the smallest set
that resolves the current predicate. Do not add a redundant observation after
every action.

## Choose targets

Prefer targets in this order:

1. `stable_ref` from the latest daemon-backed state, paired with
   `element_text` when available so a replaced AX node can safely fall back to
   text matching.
2. Visible `element_text`; add the latest `element_index` when disambiguation
   helps.
3. Coordinates read from the latest screenshot.

When a known AX target is outside the latest screenshot, keep the semantic
target and scroll the intended container in fractional increments. Use each
returned state to resolve the target again before clicking; inspect its
screenshot only when visible layout or coordinates remain unresolved. Use
untargeted whole-view scrolling only when no nested scroll region is available.

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
2. Identify the unresolved fact, then inspect only the returned evidence that
   can distinguish the recovery choices.
3. Retry with a different target or interaction route.
4. Stop and reassess after repeated no-change results.

For context menus, do not insert another AX observation between opening the
menu and clicking its item. Read
[interaction-skills/menus-and-secondary-actions.md](interaction-skills/menus-and-secondary-actions.md)
before using one.

## Verification

Treat successful function return as delivery evidence, not goal completion.
Use returned AX or `AXDIFF` state to validate an individual action and as
supporting evidence for completion.

At task completion, end the coding block and inspect the freshest matching
screenshot from automatic mutation feedback, or explicitly emit one from an
observation-only block. Compare the visible result with the user's goal once
before reporting success. Receiving a path is not visual verification. In CLI
mode require an actual host image-reading call; in MCP mode wait until the
attached image content reaches the model.

When the task changes persistent state and a declared, semantically independent
readback route is available, use it to verify the durable goal predicate as
well. If no such route is available, do not improvise one or repeat the same UI
observation under a different name; report only what the available evidence
supports.

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
