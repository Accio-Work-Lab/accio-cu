from .action_metadata import VALID_ACTION_TOOLS, validated_action_metadata


MAX_NOTIFICATIONS = 8
STATE_STRING_LIMIT = 512
STATE_STRING_FIELDS = (
    "app",
    "bundle_id",
    "window_title",
    "snapshot_id",
)
STATE_INTEGER_FIELDS = ("pid", "window_id")


def is_mutating_tool(tool):
    if not isinstance(tool, dict):
        return False
    if tool.get("name") in VALID_ACTION_TOOLS:
        return True
    annotations = tool.get("annotations")
    annotations = annotations if isinstance(annotations, dict) else {}
    destructive = annotations.get("destructiveHint")
    return destructive is True


def project_call_feedback(
    *,
    index,
    tool,
    is_mutation,
    result=None,
    artifact_paths=None,
    error=None,
):
    result = result if isinstance(result, dict) else None
    structured = (result or {}).get("structuredContent")
    structured = structured if isinstance(structured, dict) else {}
    action = validated_action_metadata(structured.get("action"), expected_tool=tool)
    state = _compact_state(structured.get("state"))
    screenshot_path = _last_png_path(artifact_paths)
    is_error = bool((result or {}).get("isError", False))
    error_type = error.get("type") if isinstance(error, dict) else None
    return {
        "index": index,
        "tool": tool,
        "is_mutation": bool(is_mutation),
        "success": error is None and result is not None and not is_error,
        "is_error": is_error,
        "state": state,
        "screenshot_path": screenshot_path,
        "changed": action.get("changed"),
        "error_type": error_type if isinstance(error_type, str) else None,
    }


def build_execution_feedback(events):
    events = tuple(event for event in events if isinstance(event, dict))
    mutations = tuple(event for event in events if event.get("is_mutation") is True)
    if not mutations:
        return None

    latest_mutation = mutations[-1]
    state_event, state_freshness, screenshot_event, screenshot_freshness = (
        _latest_observation(events, latest_mutation)
    )
    notifications = _notifications(
        mutations,
        state_freshness,
        screenshot_event,
        screenshot_freshness,
    )
    return {
        "mutations": {
            "attempted": len(mutations),
            "succeeded": sum(event.get("success") is True for event in mutations),
            "failed": sum(event.get("success") is not True for event in mutations),
            "no_ax_change": sum(
                event.get("changed") == "none" for event in mutations
            ),
            "unverifiable": sum(
                event.get("changed") == "unverifiable" for event in mutations
            ),
        },
        "latest_observation": _public_observation(
            state_event,
            state_freshness,
            screenshot_event,
            screenshot_freshness,
        ),
        "notifications": notifications,
    }


def _compact_state(value):
    if not isinstance(value, dict):
        return None
    state = {}
    for key in STATE_STRING_FIELDS:
        item = value.get(key)
        if isinstance(item, str) and item:
            state[key] = item[:STATE_STRING_LIMIT]
    for key in STATE_INTEGER_FIELDS:
        item = value.get(key)
        if isinstance(item, int) and not isinstance(item, bool):
            state[key] = item
    return state or None


def _last_png_path(paths):
    if not isinstance(paths, (list, tuple)):
        return None
    for path in reversed(paths):
        if isinstance(path, str) and path.lower().endswith(".png"):
            return path
    return None


def _latest_observation(events, latest_mutation):
    state_event = next(
        (event for event in reversed(events) if event.get("state") is not None),
        None,
    )
    screenshot_event = next(
        (
            event
            for event in reversed(events)
            if event.get("screenshot_path") is not None
        ),
        None,
    )
    return (
        state_event,
        _observation_freshness(state_event, latest_mutation),
        screenshot_event,
        _observation_freshness(screenshot_event, latest_mutation),
    )


def _observation_freshness(event, latest_mutation):
    if event is None:
        return None
    event_index = event.get("index")
    mutation_index = latest_mutation.get("index")
    if (
        isinstance(event_index, int)
        and isinstance(mutation_index, int)
        and event_index >= mutation_index
    ):
        return "after_latest_mutation"
    return (
        "before_failed_mutation"
        if latest_mutation.get("success") is not True
        else "before_latest_mutation"
    )


def _public_observation(
    state_event,
    state_freshness,
    screenshot_event,
    screenshot_freshness,
):
    if state_event is None and screenshot_event is None:
        return None
    primary_event = _later_event(state_event, screenshot_event)
    screenshot_path = (
        screenshot_event.get("screenshot_path")
        if screenshot_event is not None
        else None
    )
    screenshot = None
    if isinstance(screenshot_path, str):
        screenshot = {"path": screenshot_path, "mime_type": "image/png"}
    return {
        "source_call_index": primary_event.get("index"),
        "source_tool": primary_event.get("tool"),
        "freshness": state_freshness or screenshot_freshness,
        "state": state_event.get("state") if state_event is not None else None,
        "state_source_call_index": (
            state_event.get("index") if state_event is not None else None
        ),
        "state_source_tool": (
            state_event.get("tool") if state_event is not None else None
        ),
        "state_freshness": state_freshness,
        "screenshot": screenshot,
        "screenshot_source_call_index": (
            screenshot_event.get("index") if screenshot_event is not None else None
        ),
        "screenshot_source_tool": (
            screenshot_event.get("tool") if screenshot_event is not None else None
        ),
        "screenshot_freshness": screenshot_freshness,
    }


def _later_event(first, second):
    if first is None:
        return second
    if second is None:
        return first
    first_index = first.get("index")
    second_index = second.get("index")
    if isinstance(second_index, int) and (
        not isinstance(first_index, int) or second_index > first_index
    ):
        return second
    return first


def _notifications(
    mutations,
    state_freshness,
    screenshot_event,
    screenshot_freshness,
):
    notifications = []
    for event in mutations:
        base = {"call_index": event.get("index"), "tool": event.get("tool")}
        if event.get("success") is not True:
            notification = {"kind": "action_error", **base}
            if event.get("error_type"):
                notification["error_type"] = event["error_type"]
            notifications.append(notification)
        if event.get("changed") == "none":
            notifications.append({"kind": "no_ax_change", **base})
        elif event.get("changed") == "unverifiable":
            notifications.append({"kind": "unverifiable", **base})

    latest_mutation = mutations[-1]
    if screenshot_event is None:
        notifications.append(
            {
                "kind": "screenshot_unavailable",
                "call_index": latest_mutation.get("index"),
                "tool": latest_mutation.get("tool"),
            }
        )
    stale_values = ("before_failed_mutation", "before_latest_mutation")
    if state_freshness in stale_values or screenshot_freshness in stale_values:
        notifications.append(
            {
                "kind": "observation_may_be_stale",
                "call_index": latest_mutation.get("index"),
                "tool": latest_mutation.get("tool"),
            }
        )

    if len(notifications) <= MAX_NOTIFICATIONS:
        return notifications
    kept = notifications[-(MAX_NOTIFICATIONS - 1) :]
    return [
        {
            "kind": "notifications_truncated",
            "omitted": len(notifications) - len(kept),
        },
        *kept,
    ]
