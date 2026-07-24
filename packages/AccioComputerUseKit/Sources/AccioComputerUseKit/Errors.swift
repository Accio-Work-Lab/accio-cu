import Foundation

public enum ComputerUseError: Error, LocalizedError {
    case message(String)
    case unsupportedTool(String, known: [String])
    case invalidArguments(String)
    case appNotFound(String)
    case permissionDenied(String)
    case stateUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .message(let value):
            return value
        case .unsupportedTool(let name, let known):
            return "Unknown tool '\(name)'. Available tools: \(known.joined(separator: ", "))."
        case .invalidArguments(let msg):
            return msg
        case .appNotFound(let app):
            return "App '\(app)' not found. Try: (1) use bundle identifier like com.apple.TextEdit, " +
                "(2) check running apps with list_apps, (3) verify the app is installed."
        case .permissionDenied(let msg):
            return msg
        case .stateUnavailable(let msg):
            return msg
        }
    }

    var toolResultIsError: Bool { true }

    static func missingArgument(_ name: String) -> ComputerUseError {
        let hint = Self.usageHint(for: name)
        return .message("Missing required argument: \(name). \(hint)")
    }

    private static func usageHint(for argument: String) -> String {
        switch argument {
        case "app":
            return "Usage: {\"app\":\"TextEdit\",\"element_text\":\"Save\"}. Use list_apps to find running app names."
        case "text":
            return "Usage: {\"app\":\"TextEdit\",\"text\":\"Hello world\"}"
        case "key":
            return "Usage: {\"app\":\"TextEdit\",\"key\":\"super+s\"}. Modifiers: cmd/super, shift, option/alt, ctrl."
        case "direction":
            return "Usage: {\"app\":\"Safari\",\"direction\":\"down\"}. Values: up, down, left, right."
        case "action":
            return "Usage: {\"app\":\"Finder\",\"element_text\":\"file.txt\",\"action\":\"ShowMenu\"}. Check element's actions list from get_app_state."
        case "value":
            return "Usage: {\"app\":\"Safari\",\"element_text\":\"Address\",\"value\":\"https://example.com\"}"
        case "from_x", "from_y", "to_x", "to_y":
            return "Usage: {\"app\":\"Finder\",\"from_x\":100,\"from_y\":200,\"to_x\":300,\"to_y\":400}"
        default:
            return ""
        }
    }
}
