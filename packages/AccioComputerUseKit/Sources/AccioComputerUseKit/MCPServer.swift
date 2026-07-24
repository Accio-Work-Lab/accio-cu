import Foundation

let computerUseServerInstructions = """
Computer Use tools let you interact with desktop apps by performing UI actions.

Begin by calling `get_app_state` or `get_screen_state` every turn you want to use Computer Use to get the latest state before acting.

The available tools are list_apps, get_screen_state, get_app_state, click, perform_secondary_action, scroll, drag, type_text, press_key, and set_value.

Use `get_screen_state` to see the main-display layout (menubar, Dock, window positions, hidden/minimized apps). Use `get_app_state` to inspect a specific app's UI elements. Click and drag can be used without `app` for main-display coordinate interactions based on the get_screen_state screenshot. For a target on a secondary display, use app-level AX/app-screenshot targeting or move its window to the main display first.

Computer Use tools allow you to use the user's apps in the background, so while you're using an app, the user can continue to use other apps on their computer. Avoid doing anything that would disrupt the user's active session, such as overwriting the contents of their clipboard, unless they asked you to!

After each action, use the action result or fetch the latest state to verify the UI changed as expected.
Prefer element-targeted interactions over coordinate clicks when an index for the targeted element is available. Note that element indices are the sequential integers from the app state's accessibility tree.

IMPORTANT: Context menus (right-click menus) are transient — calling get_app_state or using element_text/element_index while a context menu is open will dismiss it. After a right-click, read the returned screenshot and click the menu item by screen coordinates (x, y without app) immediately. Do not insert any observation step between opening and clicking a context menu.

Avoid falling back to AppleScript during a computer use session. Prefer Computer Use tools as much as possible to complete tasks.
Ask the user before taking destructive or externally visible actions such as sending, deleting, or purchasing.
"""

public final class StdioMCPServer {
    private let dispatcher: ComputerUseToolDispatcher

    public init(service: ComputerUseService = ComputerUseService()) {
        self.dispatcher = ComputerUseToolDispatcher(service: service)
    }

    public func run() throws {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let response = handle(line: line) {
                FileHandle.standardOutput.write((response + "\n").data(using: .utf8)!)
            }
        }
    }

    public func handle(line: String) -> String? {
        do {
            guard let payload = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return try encodeJSONRPCError(id: nil, code: -32700, message: "Invalid JSON-RPC payload")
            }

            let method = payload["method"] as? String
            let id = payload["id"]
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                return try encodeJSONRPCResult(id: id, result: [
                    "protocolVersion": "2026-05-20",
                    "serverInfo": ["name": "accio-computer-use", "version": accioComputerUseVersion],
                    "capabilities": ["tools": ["listChanged": false]],
                    "instructions": computerUseServerInstructions,
                ])
            case "notifications/initialized":
                return nil
            case "notifications/turn-ended":
                ActivitySocketClient.shared.publish(
                    AutomationActivityEvent(
                        phase: .completed,
                        actionKind: .readApp,
                        targetApp: nil
                    )
                )
                VisualCursorSupport.performOnMain {
                    resetOpenComputerUseVisualCursor()
                }
                return nil
            case "ping":
                return try encodeJSONRPCResult(id: id, result: [:])
            case "tools/list":
                return try encodeJSONRPCResult(id: id, result: ["tools": ToolDefinitions.all.map(\.asDictionary)])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let result = try dispatcher.callTool(name: name, arguments: arguments)
                return try encodeJSONRPCResult(id: id, result: result.asDictionary)
            default:
                if method == nil { return nil }
                return try encodeJSONRPCError(id: id, code: -32601, message: "Method not found: \(method ?? "")")
            }
        } catch let error as ComputerUseError {
            let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let id = payload?["id"]
            let result = ToolCallResult.text(error.errorDescription ?? String(describing: error), isError: error.toolResultIsError)
            return try? encodeJSONRPCResult(id: id, result: result.asDictionary)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let id = payload?["id"]
            return try? encodeJSONRPCResult(id: id, result: ["content": [["type": "text", "text": message]], "isError": true])
        }
    }

    private func encodeJSONRPCResult(id: Any?, result: [String: Any]) throws -> String {
        try encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func encodeJSONRPCError(id: Any?, code: Int, message: String) throws -> String {
        try encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode JSON-RPC response.")
        }
        return text
    }
}
