"""Python helpers preloaded by the Accio Computer Use coding mode."""

import inspect
from typing import Optional

try:
    from .errors import IncompatibleRuntimeError
except ImportError:  # Loaded by worker.py when it is executed as a file.
    from errors import IncompatibleRuntimeError


class HelperContractError(IncompatibleRuntimeError):
    """Raised when one daemon tool disagrees with its Python helper."""


_call_tool = None
_available_tools = frozenset()

_NUMBER_PARAMETERS = frozenset(
    (
        "x",
        "y",
        "from_x",
        "from_y",
        "to_x",
        "to_y",
        "pages",
        "timeout_seconds",
        "poll_interval",
    )
)
_ENUM_PARAMETERS = {
    "coordinate_space": ("pixel", "normalized_1000", "normalized_1"),
    "mouse_button": ("left", "right", "middle"),
    "direction": ("up", "down", "left", "right"),
    "wait_mode": (
        "element_text",
        "window_title_contains",
        "element_count_changed",
        "focused_value_contains",
    ),
}
_NON_SEMANTIC_SCHEMA_KEYS = frozenset(("$comment", "description", "examples", "title"))


def _invoke(tool_name, required=None, optional=None):
    if _call_tool is None:
        raise RuntimeError("Accio coding helpers are not configured")
    if tool_name not in _available_tools:
        raise HelperContractError(
            "%s is not available from the connected Accio daemon" % tool_name
        )
    arguments = dict(required or {})
    arguments.update(
        {name: value for name, value in (optional or {}).items() if value is not None}
    )
    return _call_tool(tool_name, arguments)


def list_apps():
    """List running and recently used GUI apps. Returns a ToolResult."""

    return _invoke("list_apps")


def get_screen_state():
    """Capture the main-display screenshot and window state. Returns a ToolResult."""

    return _invoke("get_screen_state")


def get_app_state(*, app):
    """Snapshot an app's accessibility tree and screenshot.

    Args:
        app: Application name or bundle identifier.

    Returns:
        A ToolResult containing AX state and screenshot artifacts.
    """

    return _invoke("get_app_state", {"app": app})


def click(
    *,
    app=None,
    stable_ref=None,
    element_index: Optional[str] = None,
    element_text=None,
    snapshot_id=None,
    x=None,
    y=None,
    coordinate_space=None,
    click_count=1,
    mouse_button="left",
):
    """Click an AX element or screenshot coordinate.

    Target with a current stable_ref, visible element_text/index, or x/y from
    the latest matching screenshot. Pair stable_ref with element_text when
    possible so a replaced AX node can safely fall back to text matching.
    Omit app for screen-level coordinates.
    coordinate_space accepts pixel, normalized_1000, or normalized_1.
    snapshot_id is an optional fail-closed precondition from the latest state;
    stale IDs raise before the click.
    element_index is a string copied from the AX tree, for example "12";
    do not pass the displayed index as an int.

    Returns:
        A ToolResult containing refreshed state and screenshot artifacts.
    """

    return _invoke("click", optional=locals())


def double_click(
    *,
    app=None,
    stable_ref=None,
    element_index: Optional[str] = None,
    element_text=None,
    snapshot_id=None,
    x=None,
    y=None,
    coordinate_space=None,
    mouse_button="left",
):
    """Double-click an AX element or screenshot coordinate. Returns refreshed state."""

    return click(
        app=app,
        stable_ref=stable_ref,
        element_index=element_index,
        element_text=element_text,
        snapshot_id=snapshot_id,
        x=x,
        y=y,
        coordinate_space=coordinate_space,
        click_count=2,
        mouse_button=mouse_button,
    )


def hover(
    *,
    app,
    stable_ref=None,
    element_index: Optional[str] = None,
    element_text=None,
    snapshot_id=None,
    x=None,
    y=None,
    coordinate_space=None,
):
    """Move the pointer over an app element or app-screenshot coordinate.

    Use this for controls that reveal content on hover. The pointer remains at
    the target and the returned ToolResult contains refreshed state.
    """

    return _invoke(
        "hover",
        {"app": app},
        {
            "stable_ref": stable_ref,
            "element_index": element_index,
            "element_text": element_text,
            "snapshot_id": snapshot_id,
            "x": x,
            "y": y,
            "coordinate_space": coordinate_space,
        },
    )


def drag(
    *,
    from_x,
    from_y,
    to_x,
    to_y,
    app=None,
    coordinate_space=None,
):
    """Drag between two screenshot coordinates.

    Omit app for screen-level coordinates. coordinate_space accepts pixel,
    normalized_1000, or normalized_1. Returns refreshed state.
    """

    return _invoke(
        "drag",
        {"from_x": from_x, "from_y": from_y, "to_x": to_x, "to_y": to_y},
        {"app": app, "coordinate_space": coordinate_space},
    )


def perform_secondary_action(
    *,
    app,
    action,
    stable_ref=None,
    element_index: Optional[str] = None,
    element_text=None,
    snapshot_id=None,
):
    """Invoke a named AX action on an app or element.

    Copy action from the element's latest actions list, for example Open or
    Raise; raw AXOpen/AXRaise forms also work. Use activate_app for explicit
    foreground activation. Target a current element with stable_ref or
    element_text/index.
    """

    return _invoke(
        "perform_secondary_action",
        {"app": app, "action": action},
        {
            "stable_ref": stable_ref,
            "element_index": element_index,
            "element_text": element_text,
            "snapshot_id": snapshot_id,
        },
    )


def press_key(*, app, key):
    """Send a key or key combination to an app.

    Join modifiers with '+', for example Return, super+s, or super+shift+s.
    Returns refreshed state.
    """

    return _invoke("press_key", {"app": app, "key": key})


def scroll(
    *,
    app,
    direction,
    stable_ref=None,
    element_index: Optional[str] = None,
    element_text=None,
    snapshot_id=None,
    pages=1,
):
    """Scroll an app or a targeted AX region.

    direction is up, down, left, or right. pages may be fractional. Target a
    region with stable_ref or element_text/index. Returns refreshed state.
    """

    return _invoke(
        "scroll",
        {"app": app, "direction": direction},
        {
            "stable_ref": stable_ref,
            "element_index": element_index,
            "element_text": element_text,
            "snapshot_id": snapshot_id,
            "pages": pages,
        },
    )


def set_value(
    *,
    app,
    value,
    stable_ref=None,
    element_index: Optional[str] = None,
    element_text=None,
    snapshot_id=None,
):
    """Set a string-valued AX-settable element directly through AXValue.

    Target with stable_ref or element_text/index. value must be non-empty; clear
    a field with select-all plus Backspace. Some apps require Return or another
    commit action after the value is set. Returns refreshed state.
    """

    return _invoke(
        "set_value",
        {"app": app, "value": value},
        {
            "stable_ref": stable_ref,
            "element_index": element_index,
            "element_text": element_text,
            "snapshot_id": snapshot_id,
        },
    )


def type_text(
    *,
    app,
    text,
    stable_ref=None,
    element_index: Optional[str] = None,
    element_text=None,
    snapshot_id=None,
):
    """Type text by emitting keyboard events into an app or editable element.

    Target with stable_ref or element_text/index, or omit the target to type at
    the current focus. This never writes AXValue directly. Returns refreshed
    state with route and changed metadata on the ToolResult.
    """

    return _invoke(
        "type_text",
        {"app": app, "text": text},
        {
            "stable_ref": stable_ref,
            "element_index": element_index,
            "element_text": element_text,
            "snapshot_id": snapshot_id,
        },
    )


def wait_for_element(
    *,
    app,
    element_text=None,
    wait_mode="element_text",
    timeout_seconds=10,
    poll_interval=0.5,
):
    """Poll until an app-state condition matches or times out.

    wait_mode accepts element_text, window_title_contains,
    element_count_changed, or focused_value_contains. A successful wait returns
    textual AX state without a screenshot. Returns a ToolResult.
    """

    return _invoke(
        "wait_for_element",
        {"app": app},
        {
            "element_text": element_text,
            "wait_mode": wait_mode,
            "timeout_seconds": timeout_seconds,
            "poll_interval": poll_interval,
        },
    )


def menu_select(*, app, path):
    """Select an application menu item by path.

    path is a list such as ["File", "Export as PDF..."]. Returns refreshed
    state.
    """

    return _invoke("menu_select", {"app": app, "path": path})


_HELPERS = {
    function.__name__: function
    for function in (
        list_apps,
        get_screen_state,
        get_app_state,
        click,
        hover,
        drag,
        perform_secondary_action,
        press_key,
        scroll,
        set_value,
        type_text,
        wait_for_element,
        menu_select,
    )
}


def configure(call_tool, tools):
    """Bind helpers to a worker transport and validate the daemon API contract."""

    global _available_tools, _call_tool
    definitions = {tool.get("name"): tool for tool in tools if isinstance(tool, dict)}
    known_definitions = {
        name: tool for name, tool in definitions.items() if name in _HELPERS
    }
    for name, tool in known_definitions.items():
        _validate_signature(name, _HELPERS[name], tool)
    _call_tool = call_tool
    _available_tools = frozenset(known_definitions)
    exported = dict(_HELPERS)
    exported["double_click"] = double_click
    return exported


def validate_runtime_contract(tools):
    """Reject a daemon that cannot implement the complete coding API."""

    definitions = {
        tool.get("name"): tool for tool in tools if isinstance(tool, dict)
    }
    missing = sorted(set(_HELPERS) - set(definitions))
    if missing:
        raise IncompatibleRuntimeError(
            "connected Accio daemon is incompatible with this coding runner; "
            "missing required tool(s): %s" % ", ".join(missing)
        )

    for name, function in _HELPERS.items():
        try:
            _validate_signature(name, function, definitions[name])
        except IncompatibleRuntimeError as error:
            raise IncompatibleRuntimeError(
                "connected Accio daemon is incompatible with this coding runner; %s"
                % error
            ) from error


def _validate_signature(name, function, tool):
    schema = tool.get("inputSchema")
    if not isinstance(schema, dict) or schema.get("type") != "object":
        raise HelperContractError("%s input schema must be an object" % name)
    properties = schema.get("properties")
    if not isinstance(properties, dict):
        raise HelperContractError("%s schema properties must be an object" % name)
    required_value = schema.get("required", [])
    if not isinstance(required_value, list) or not all(
        isinstance(value, str) for value in required_value
    ):
        raise HelperContractError("%s schema required must be a string array" % name)
    if len(required_value) != len(set(required_value)):
        raise HelperContractError("%s schema required contains duplicates" % name)
    required = set(required_value)
    missing_required_properties = sorted(required - set(properties))
    if missing_required_properties:
        raise HelperContractError(
            "%s schema required names are missing from properties: %s"
            % (name, ", ".join(missing_required_properties))
        )
    if schema.get("additionalProperties") is not False:
        raise HelperContractError(
            "%s schema must reject additional properties" % name
        )
    semantic_top_level_keys = set(schema) - _NON_SEMANTIC_SCHEMA_KEYS
    unknown_top_level_keys = sorted(
        semantic_top_level_keys
        - {"type", "properties", "required", "additionalProperties"}
    )
    if unknown_top_level_keys:
        raise HelperContractError(
            "%s schema contains unsupported execution constraints: %s"
            % (name, ", ".join(unknown_top_level_keys))
        )
    parameters = inspect.signature(function).parameters
    if set(parameters) != set(properties):
        raise HelperContractError(
            "%s helper parameters do not match daemon schema" % name
        )
    for parameter_name, parameter in parameters.items():
        if parameter.kind is not inspect.Parameter.KEYWORD_ONLY:
            raise HelperContractError(
                "%s.%s must be keyword-only" % (name, parameter_name)
            )
        is_required = parameter.default is inspect.Parameter.empty
        if is_required != (parameter_name in required):
            raise HelperContractError(
                "%s.%s required/default status does not match daemon schema"
                % (name, parameter_name)
            )
        actual_contract = _property_contract(properties[parameter_name])
        expected_contract = _expected_property_contract(parameter_name)
        if actual_contract != expected_contract:
            raise HelperContractError(
                "%s.%s schema does not match coding API" % (name, parameter_name)
            )


def _expected_property_contract(parameter_name):
    if parameter_name == "click_count":
        return {"type": "integer"}
    if parameter_name == "path":
        return {"type": "array", "items": {"type": "string"}}
    contract = {
        "type": "number" if parameter_name in _NUMBER_PARAMETERS else "string"
    }
    enum_values = _ENUM_PARAMETERS.get(parameter_name)
    if enum_values is not None:
        contract["enum"] = enum_values
    return contract


def _property_contract(value):
    if not isinstance(value, dict) or not isinstance(value.get("type"), str):
        return None
    return _normalize_execution_schema(value)


def _normalize_execution_schema(value):
    """Remove documentation fields while preserving every execution constraint."""

    if isinstance(value, dict):
        return {
            key: _normalize_execution_schema(item)
            for key, item in value.items()
            if key not in _NON_SEMANTIC_SCHEMA_KEYS
        }
    if isinstance(value, list):
        return tuple(_normalize_execution_schema(item) for item in value)
    return value
