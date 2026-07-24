VALID_ACTION_TOOLS = frozenset(("type_text", "set_value"))
VALID_ACTION_ROUTES = frozenset(
    ("keyboard_post_to_pid", "keyboard_hid", "ax_value_write")
)
VALID_CHANGE_LEVELS = frozenset(
    ("confirmed", "structureOnly", "unverifiable", "none")
)


def validated_action_metadata(value):
    if not isinstance(value, dict):
        return {}

    tool = value.get("tool")
    route = value.get("route")
    changed = value.get("changed")
    if (
        tool not in VALID_ACTION_TOOLS
        or route not in VALID_ACTION_ROUTES
        or changed not in VALID_CHANGE_LEVELS
    ):
        return {}
    return {"tool": tool, "route": route, "changed": changed}
