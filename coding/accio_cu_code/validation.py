import math

from .errors import ArgumentValidationError


def tool_map(tools):
    result = {}
    for tool in tools:
        if not isinstance(tool, dict) or not isinstance(tool.get("name"), str):
            raise ArgumentValidationError(
                "tools/list returned an invalid tool definition"
            )
        name = tool["name"]
        if not name.isidentifier():
            raise ArgumentValidationError(
                "tool name is not a valid Python identifier: %s" % name
            )
        if name in result:
            raise ArgumentValidationError(
                "tools/list returned duplicate tool: %s" % name
            )
        result[name] = tool
    return result


def validate_arguments(tool, arguments):
    if not isinstance(arguments, dict):
        raise ArgumentValidationError(
            "arguments for %s must be an object" % tool["name"]
        )
    schema = tool.get("inputSchema") or {}
    properties = schema.get("properties") or {}
    required = schema.get("required") or []

    unknown = sorted(set(arguments) - set(properties))
    if unknown and schema.get("additionalProperties") is False:
        raise ArgumentValidationError(
            "%s received unknown argument(s): %s" % (tool["name"], ", ".join(unknown))
        )

    missing = [name for name in required if name not in arguments]
    if missing:
        raise ArgumentValidationError(
            "%s is missing required argument(s): %s"
            % (tool["name"], ", ".join(missing))
        )

    for name, value in arguments.items():
        property_schema = properties.get(name)
        if property_schema is not None:
            _validate_value("%s.%s" % (tool["name"], name), value, property_schema)


def _validate_value(path, value, schema):
    expected = schema.get("type")
    if expected == "string" and not isinstance(value, str):
        _type_error(path, expected, value)
    elif expected == "integer" and (
        isinstance(value, bool) or not isinstance(value, int)
    ):
        _type_error(path, expected, value)
    elif expected == "number":
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            _type_error(path, expected, value)
        if not math.isfinite(value):
            raise ArgumentValidationError("%s must be finite" % path)
    elif expected == "boolean" and not isinstance(value, bool):
        _type_error(path, expected, value)
    elif expected == "array":
        if not isinstance(value, list):
            _type_error(path, expected, value)
        item_schema = schema.get("items") or {}
        for index, item in enumerate(value):
            _validate_value("%s[%d]" % (path, index), item, item_schema)
    elif expected == "object" and not isinstance(value, dict):
        _type_error(path, expected, value)

    enum_values = schema.get("enum")
    if enum_values is not None and value not in enum_values:
        raise ArgumentValidationError(
            "%s must be one of: %s" % (path, ", ".join(map(str, enum_values)))
        )


def _type_error(path, expected, value):
    raise ArgumentValidationError(
        "%s must be %s, got %s" % (path, expected, type(value).__name__)
    )
