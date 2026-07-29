import Foundation

public struct ToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    public let annotations: [String: Any]
    public let inputSchema: [String: Any]

    public var asDictionary: [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]
        if !annotations.isEmpty { dict["annotations"] = annotations }
        return dict
    }
}

public enum ToolDefinitions {
    public static let all: [ToolDefinition] = [
        ToolDefinition(
            name: "click",
            description: """
                Click an element. Prefer stable_ref from the latest daemon/session-backed snapshot/diff when available, and pair it with element_text when possible so a replaced AX node can safely fall back to text matching. Otherwise provide BOTH element_text and element_index for robust targeting — \
                element_text is the stable anchor, element_index is the fast path verified against it. \
                If element_index is stale (doesn't match element_text), the tool automatically falls back to text search. \
                Every action tool returns the updated observation + screenshot with a snapshot ID: AXDIFF v1 when daemon/session-backed and safe, otherwise a full AX tree, so you do NOT need a separate get_app_state call after. \
                Use click_count=2 for double-click, 3 for triple-click. \
                Omit app to click at screen-level coordinates from get_screen_state (requires x and y). \
                Coordinate inputs default to screenshot pixels; set coordinate_space when your model emits normalized coords. \
                For screen-level x/y (app omitted), the tool tries to AX-snap to an actionable element under that point before raw input fallback. App-level x/y uses coordinate input fallback directly. \
                WARNING: Context menus (right-click menus) are transient — using element_text or app-level click triggers an AX tree walk that dismisses the menu. \
                To click a context menu item, use screen-level coordinates (x, y without app) from the screenshot instead.
                """,
            annotations: actionAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier. Omit to click at screen-level coordinates from get_screen_state"),
                    "stable_ref": stringProperty(description: "Stable ref from the latest daemon/session-backed AX snapshot/diff, e.g. a12. Pair with element_text to allow safe fallback when the AX node is replaced"),
                    "element_index": stringProperty(description: "Element index from AX tree. Best used together with element_text for cross-validation"),
                    "element_text": stringProperty(description: "Match element by visible label text (case-insensitive substring). Stable across UI changes — always provide this when possible"),
                    "snapshot_id": stringProperty(description: "Optional snapshot precondition. A superseded or unknown ID fails before the action instead of retargeting stale selectors"),
                    "x": numberProperty(description: "X coordinate in the space declared by coordinate_space (default: screenshot pixels). Fallback when no AX element matches"),
                    "y": numberProperty(description: "Y coordinate in the space declared by coordinate_space (default: screenshot pixels). Fallback when no AX element matches"),
                    "coordinate_space": stringProperty(
                        description: "Coordinate system for x/y. \"pixel\" (default, raw screenshot pixels), \"normalized_1000\" (0–1000, Gemini), or \"normalized_1\" (0–1). Overrides ACCIO_COMPUTER_USE_COORDINATE_SPACE env var",
                        enumValues: ["pixel", "normalized_1000", "normalized_1"]
                    ),
                    "click_count": integerProperty(description: "1=single (default), 2=double, 3=triple"),
                    "mouse_button": stringProperty(description: "left (default), right, middle", enumValues: ["left", "right", "middle"]),
                ],
                required: []
            )
        ),
        ToolDefinition(
            name: "hover",
            description: """
                Move the pointer over an app element or app-screenshot coordinate and keep it there. \
                Use when a control reveals menus, tooltips, or child content on hover. Returns updated observation.
                """,
            annotations: actionAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "stable_ref": stringProperty(description: "Stable ref from the latest app state"),
                    "element_index": stringProperty(description: "Element index, preferably paired with element_text"),
                    "element_text": stringProperty(description: "Match element by visible label text"),
                    "snapshot_id": stringProperty(description: "Optional snapshot precondition; stale IDs fail before the action"),
                    "x": numberProperty(description: "X coordinate from the latest app screenshot"),
                    "y": numberProperty(description: "Y coordinate from the latest app screenshot"),
                    "coordinate_space": stringProperty(
                        description: "Coordinate system for x/y",
                        enumValues: ["pixel", "normalized_1000", "normalized_1"]
                    ),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "drag",
            description: """
                Drag from one point to another. Coordinates default to screenshot pixels; set coordinate_space when your model emits normalized coords. \
                Omit app to drag at screen-level coordinates from get_screen_state. Returns updated state.
                """,
            annotations: actionAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier. Omit to drag at screen-level coordinates from get_screen_state"),
                    "from_x": numberProperty(description: "Start X (in coordinate_space)"),
                    "from_y": numberProperty(description: "Start Y (in coordinate_space)"),
                    "to_x": numberProperty(description: "End X (in coordinate_space)"),
                    "to_y": numberProperty(description: "End Y (in coordinate_space)"),
                    "coordinate_space": stringProperty(
                        description: "Coordinate system for from_*/to_* values. \"pixel\" (default), \"normalized_1000\" (Gemini), \"normalized_1\". Overrides ACCIO_COMPUTER_USE_COORDINATE_SPACE env var",
                        enumValues: ["pixel", "normalized_1000", "normalized_1"]
                    ),
                ],
                required: ["from_x", "from_y", "to_x", "to_y"]
            )
        ),
        ToolDefinition(
            name: "get_app_state",
            description: """
                Snapshot the app's key window: full AX tree with ephemeral element indices, daemon/session-backed stable refs when available, and screenshot. \
                Launches app if not running. \
                NOTE: You often do NOT need this — action tools (click, scroll, type_text, etc.) return the updated observation, usually as AXDIFF v1 when daemon/session-backed and safe. \
                Only call this when you need to inspect the UI without performing an action. \
                WARNING: Do NOT call this while a context menu (right-click menu) is open — the AX tree walk will dismiss the menu. \
                Use the screenshot from the action that opened the menu and click by screen coordinates instead.
                """,
            annotations: observationAnnotations(),
            inputSchema: objectSchema(
                properties: ["app": stringProperty(description: "App name or bundle identifier")],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "get_screen_state",
            description: """
                Capture a full-screen screenshot of the main display with visible window positions and hidden/minimized apps. \
                Use this to see the desktop layout, system UI (menubar, Dock), or find which apps are visible. \
                For inspecting a specific app's UI elements, use get_app_state instead. \
                Coordinates from this screenshot can be used with click and drag (without app parameter) for screen-level interactions.
                """,
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: "list_apps",
            description: "List running and recently used apps.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: "perform_secondary_action",
            description: "Invoke a secondary AX action (e.g. AXShowMenu for context menu, AXRaise), or action=activate_app to bring the target app frontmost and raise its window. Returns updated observation.",
            annotations: actionAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "stable_ref": stringProperty(description: "Stable ref from the latest daemon/session-backed AX snapshot/diff, e.g. a12. Preferred over element_index when present"),
                    "element_index": stringProperty(description: "Element index (best used with element_text for cross-validation)"),
                    "element_text": stringProperty(description: "Match element by visible label text"),
                    "snapshot_id": stringProperty(description: "Optional snapshot precondition; stale IDs fail before the action"),
                    "action": stringProperty(description: "AX action name (e.g. AXShowMenu), or activate_app to bring the app frontmost"),
                ],
                required: ["app", "action"]
            )
        ),
        ToolDefinition(
            name: "press_key",
            description: """
                Press a key or key-combination. Returns updated app state. \
                Syntax: modifiers joined by '+' then key. \
                Examples: "Return", "Tab", "space", "super+c", "shift+a", "super+shift+s", "Up", "Escape", "Delete". \
                Modifiers: cmd/super, shift, option/alt, ctrl.
                """,
            annotations: actionAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "key": stringProperty(description: "Key or combo (e.g. \"Return\", \"super+c\")"),
                ],
                required: ["app", "key"]
            )
        ),
        ToolDefinition(
            name: "scroll",
            description: """
                Scroll within the app. Without stable_ref/element_index/element_text, scrolls the largest scrollable area. \
                Returns updated observation. Use pages=0.5 for half-page, pages=3 for three pages, etc.
                """,
            annotations: actionAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "direction": stringProperty(description: "Scroll direction", enumValues: ["up", "down", "left", "right"]),
                    "stable_ref": stringProperty(description: "Scroll within this stable ref from the latest daemon/session-backed AX snapshot/diff (optional, preferred over element_index when present)"),
                    "element_index": stringProperty(description: "Scroll within this element (optional, best used with element_text)"),
                    "element_text": stringProperty(description: "Scroll within element matching this text (optional)"),
                    "snapshot_id": stringProperty(description: "Optional snapshot precondition; stale IDs fail before the action"),
                    "pages": numberProperty(description: "Pages to scroll (fractional OK, default 1)"),
                ],
                required: ["app", "direction"]
            )
        ),
        ToolDefinition(
            name: "set_value",
            description: "Set the string value of an AX-settable text field directly through AXValue. This is distinct from type_text, which emits keyboard events. Focuses the target first, refreshes/re-resolves it, then writes AXValue. Numeric sliders are not currently supported. If the edited field remains focused, the result warns that some apps may still need Return/click/another commit action to persist.",
            annotations: actionAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "stable_ref": stringProperty(description: "Stable ref from the latest daemon/session-backed AX snapshot/diff, e.g. a12. Preferred over element_index when present"),
                    "element_index": stringProperty(description: "Element index (best used with element_text for cross-validation)"),
                    "element_text": stringProperty(description: "Match element by visible label text"),
                    "snapshot_id": stringProperty(description: "Optional snapshot precondition; stale IDs fail before the action"),
                    "value": stringProperty(description: "Value to set"),
                ],
                required: ["app", "value"]
            )
        ),
        ToolDefinition(
            name: "type_text",
            description: "Type text by emitting keyboard events; never replaces AXValue directly. If stable_ref, element_index, or element_text is provided, focuses that element first. Returns updated observation with structured action route/change metadata.",
            annotations: actionAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text": stringProperty(description: "Text to type"),
                    "stable_ref": stringProperty(description: "Element stable ref to focus before typing (optional, preferred over element_index when present)"),
                    "element_index": stringProperty(description: "Element to focus before typing (optional, best used with element_text)"),
                    "element_text": stringProperty(description: "Focus element matching this text before typing (optional)"),
                    "snapshot_id": stringProperty(description: "Optional snapshot precondition; stale IDs fail before the action"),
                ],
                required: ["app", "text"]
            )
        ),
        ToolDefinition(
            name: "wait_for_element",
            description: "Poll until a UI condition is met, or timeout. Use after actions that trigger async UI changes (navigation, loading). Returns structured wait status and app state.",
            annotations: observationAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_text": stringProperty(description: "Text/value/title to wait for, depending on wait_mode (case-insensitive substring). Not required for element_count_changed"),
                    "wait_mode": stringProperty(
                        description: "Condition to wait for: element_text (default), window_title_contains, element_count_changed, focused_value_contains",
                        enumValues: ["element_text", "window_title_contains", "element_count_changed", "focused_value_contains"]
                    ),
                    "timeout_seconds": numberProperty(description: "Max wait seconds (1–30, default 10)"),
                    "poll_interval": numberProperty(description: "Seconds between polls (0.1–2.0, default 0.5)"),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "menu_select",
            description: """
                Select a menu bar item by path using Accessibility, e.g. path=["File","Export as PDF..."]. \
                Prefer this over clicking menu coordinates. Matching ignores case and treats ... and … as equivalent. \
                If a path segment is missing, the error lists available menu items at that level.
                """,
            annotations: actionAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "path": arrayProperty(
                        item: stringProperty(description: "Menu path component"),
                        description: "Menu path, e.g. [\"File\", \"Export as PDF...\"]"
                    ),
                ],
                required: ["app", "path"]
            )
        ),
    ]
}

private func objectSchema(properties: [String: Any], required: [String]) -> [String: Any] {
    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
    ]
    if !required.isEmpty { schema["required"] = required }
    return schema
}

private func actionAnnotations() -> [String: Any] {
    ["destructiveHint": true, "openWorldHint": true, "readOnlyHint": false]
}

private func observationAnnotations() -> [String: Any] {
    ["destructiveHint": false, "openWorldHint": false, "readOnlyHint": false]
}

private func readOnlyAnnotations() -> [String: Any] {
    ["destructiveHint": false, "idempotentHint": true, "openWorldHint": false, "readOnlyHint": true]
}

private func stringProperty(description: String, enumValues: [String]? = nil) -> [String: Any] {
    var prop: [String: Any] = ["type": "string", "description": description]
    if let enumValues { prop["enum"] = enumValues }
    return prop
}

private func integerProperty(description: String) -> [String: Any] {
    ["type": "integer", "description": description]
}

private func numberProperty(description: String) -> [String: Any] {
    ["type": "number", "description": description]
}

private func arrayProperty(item: [String: Any], description: String) -> [String: Any] {
    ["type": "array", "items": item, "description": description]
}
