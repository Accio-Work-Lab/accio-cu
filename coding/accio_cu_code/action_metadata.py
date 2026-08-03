import re


VALID_ACTION_TOOLS = frozenset(
    (
        "click",
        "drag",
        "hover",
        "menu_select",
        "perform_secondary_action",
        "press_key",
        "scroll",
        "set_value",
        "type_text",
    )
)
VALID_ACTION_ROUTES = frozenset(
    (
        "activate_app",
        "ax_menu_press",
        "ax_press",
        "ax_value_write",
        "background_scroll",
        "coordinate_drag",
        "coordinate_fallback",
        "global_pointer",
        "hid_activation",
        "keyboard_hid",
        "keyboard_post_to_pid",
        "semantic_ax",
        "targeted_key",
    )
)
VALID_CHANGE_LEVELS = frozenset(
    ("confirmed", "structureOnly", "unverifiable", "none")
)
AX_ROUTE_PATTERN = re.compile(r"^AX[A-Za-z]{1,62}$")


def validated_action_metadata(value, expected_tool=None):
    if not isinstance(value, dict):
        return {}

    tool = value.get("tool")
    route = value.get("route")
    changed = value.get("changed")
    if (
        tool not in VALID_ACTION_TOOLS
        or (expected_tool is not None and tool != expected_tool)
        or not isinstance(route, str)
        or (
            route not in VALID_ACTION_ROUTES
            and AX_ROUTE_PATTERN.fullmatch(route) is None
        )
        or changed not in VALID_CHANGE_LEVELS
    ):
        return {}
    return {"tool": tool, "route": route, "changed": changed}
