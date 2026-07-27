import Darwin
import Foundation

public enum CLICommand: Equatable {
    case gui
    case code(arguments: [String])
    case setup
    case mcp
    case serve(socketPath: String?)
    case daemonStatus(socketPath: String?)
    case doctor
    case listApps
    case snapshot(app: String)
    case call(toolName: String, argumentsJSON: String?, options: CallOptions)
    case help(command: String?)
    case version
}

public struct CallOptions: Equatable {
    public let raw: Bool
    public let imageOut: String?
    public let inlineImage: Bool
    public let compact: Bool
    public let filter: String?
    public let socketPath: String?
    public let noDaemon: Bool

    public init(raw: Bool = false, imageOut: String? = nil, inlineImage: Bool = false, compact: Bool = false, filter: String? = nil, socketPath: String? = nil, noDaemon: Bool = false) {
        self.raw = raw
        self.imageOut = imageOut
        self.inlineImage = inlineImage
        self.compact = compact
        self.filter = filter
        self.socketPath = socketPath
        self.noDaemon = noDaemon
    }
}

public struct CLIError: LocalizedError, Equatable {
    public let message: String
    public let helpCommand: String?

    public init(message: String, helpCommand: String? = nil) {
        self.message = message
        self.helpCommand = helpCommand
    }

    public var errorDescription: String? {
        var lines = [message, ""]
        lines.append(helpText(command: helpCommand))
        return lines.joined(separator: "\n")
    }
}

public func resolveCLI(
    arguments: [String],
    hasPipedStdin: Bool,
    isAppBundleLaunch: Bool = false
) throws -> CLICommand {
    if isAppBundleLaunch,
       arguments.count == 1,
       isLaunchServicesProcessSerialNumber(arguments[0]) {
        return .gui
    }

    let nativeGlobalOptions = ["-h", "--help", "-v", "--version"]
    if hasPipedStdin,
       arguments.isEmpty || (
        arguments.first?.hasPrefix("-") == true
            && !nativeGlobalOptions.contains(arguments[0])
       ) {
        return .code(arguments: arguments)
    }
    return try parseCLI(
        arguments: arguments,
        isAppBundleLaunch: isAppBundleLaunch
    )
}

public func standardInputSupportsPayload(isTerminal: Bool, fileMode: mode_t?) -> Bool {
    guard !isTerminal, let fileMode else { return false }
    let fileType = fileMode & mode_t(S_IFMT)
    return [S_IFIFO, S_IFREG, S_IFSOCK].contains(fileType)
}

public func parseCLI(
    arguments: [String],
    isAppBundleLaunch: Bool = false
) throws -> CLICommand {
    if isAppBundleLaunch,
       arguments.count == 1,
       isLaunchServicesProcessSerialNumber(arguments[0]) {
        return .gui
    }

    guard let first = arguments.first else {
        return .gui
    }

    switch first {
    case "-h", "--help", "help":
        return .help(command: arguments.dropFirst().first)
    case "-v", "--version", "version":
        return .version
    case "setup", "tui":
        guard arguments.count == 1 else {
            if arguments.count == 2, ["-h", "--help"].contains(arguments[1]) { return .help(command: "setup") }
            throw CLIError(message: "\(first) does not accept arguments", helpCommand: "setup")
        }
        return .setup
    case "code":
        return .code(arguments: Array(arguments.dropFirst()))
    case "mcp":
        guard arguments.count == 1 else {
            if arguments.count == 2, ["-h", "--help"].contains(arguments[1]) { return .help(command: "mcp") }
            throw CLIError(message: "mcp does not accept arguments", helpCommand: "mcp")
        }
        return .mcp
    case "serve":
        if arguments.count >= 2, ["-h", "--help"].contains(arguments[1]) { return .help(command: "serve") }
        let socketPath = arguments.count >= 2 ? arguments[1] : nil
        return .serve(socketPath: socketPath)
    case "daemon-status":
        if arguments.count >= 2, ["-h", "--help"].contains(arguments[1]) {
            return .help(command: "daemon-status")
        }
        guard arguments.count <= 2 else {
            throw CLIError(
                message: "daemon-status accepts at most one [socket-path] argument",
                helpCommand: "daemon-status"
            )
        }
        return .daemonStatus(socketPath: arguments.dropFirst().first)
    case "doctor":
        guard arguments.count == 1 else {
            if arguments.count == 2, ["-h", "--help"].contains(arguments[1]) { return .help(command: "doctor") }
            throw CLIError(message: "doctor does not accept arguments", helpCommand: "doctor")
        }
        return .doctor
    case "list-apps":
        guard arguments.count == 1 else {
            if arguments.count == 2, ["-h", "--help"].contains(arguments[1]) { return .help(command: "list-apps") }
            throw CLIError(message: "list-apps does not accept arguments", helpCommand: "list-apps")
        }
        return .listApps
    case "snapshot":
        if arguments.count == 2, ["-h", "--help"].contains(arguments[1]) { return .help(command: "snapshot") }
        guard arguments.count == 2 else {
            throw CLIError(message: "snapshot requires exactly one <app> argument", helpCommand: "snapshot")
        }
        return .snapshot(app: arguments[1])
    case "call":
        return try parseCall(arguments: Array(arguments.dropFirst()))
    default:
        if first.hasPrefix("-") {
            throw CLIError(message: "Unknown option: \(first)", helpCommand: nil)
        }
        throw CLIError(message: "Unknown command: \(first)", helpCommand: nil)
    }
}

private func isLaunchServicesProcessSerialNumber(_ argument: String) -> Bool {
    guard argument.hasPrefix("-psn_") else { return false }
    let components = argument.dropFirst(5).split(separator: "_", omittingEmptySubsequences: false)
    guard components.count == 2 else { return false }
    return components.allSatisfy { component in
        !component.isEmpty && component.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

public func helpText(command: String? = nil) -> String {
    switch command {
    case nil:
        return """
        Accio Computer Use

        Usage:
          accio-computer-use [command] [options]
          accio-computer-use < program.py

        Commands:
          code [options]       Run a Python coding block, or `code mcp`.
          setup                Recommended first-run setup and diagnostics TUI.
          mcp                  Start the low-level desktop-tool MCP server.
          serve [socket-path]  Start the daemon server on a Unix socket.
          daemon-status        Check for a live current-user daemon listener.
          doctor               Print permission, daemon, and install status.
          list-apps            Print running or recently used apps.
          snapshot <app>       Print the current accessibility snapshot for an app.
          call <tool>          Call one tool and print the result.
          help [command]       Show general or command-specific help.
          version              Print the CLI version.

        Global options:
          -h, --help           Show help.
          -v, --version        Show version.
        """
    case "code":
        return """
        Usage:
          accio-computer-use < program.py
          accio-computer-use code [options] < program.py
          accio-computer-use code mcp [options]

        Execute one Python block with the Accio desktop helpers preloaded.
        With no command, piped stdin enters coding mode automatically. Use the
        explicit `code` form to pass limits, override the daemon socket, inspect
        help, or run the single-tool `execute` MCP server.
        """
    case "setup", "tui":
        return """
        Usage:
          accio-computer-use setup

        Recommended first-run setup for permissions, daemon state, MCP config,
        install model, logs, and menu bar helper guidance. On macOS the app
        bundle is the permission container and the CLI is a symlink into it.
        Seeing "Accio Computer Use" in System Settings' app lists is expected.
        In an interactive terminal this opens a small TUI menu; in
        non-interactive contexts it prints a status dashboard and exits.
        """
    case "mcp":
        return """
        Usage:
          accio-computer-use mcp

        Start the low-level stdio MCP server that exposes individual desktop
        tools. For one hybrid `execute` tool that accepts a Python block, use
        `accio-computer-use code mcp` instead.
        """
    case "serve":
        return """
        Usage:
          accio-computer-use serve [socket-path]

        Start the daemon server listening on a Unix domain socket.
        Default path: \(DaemonServer.defaultSocketPath)

        The daemon runs with full permissions and handles tool calls
        forwarded from sandboxed CLI invocations. Start it in a
        terminal that has Accessibility + Screen Recording granted.
        """
    case "daemon-status":
        return """
        Usage:
          accio-computer-use daemon-status [socket-path]

        Check that the daemon socket has a live listener owned by the current
        user. A loaded LaunchAgent or an existing socket file alone is not
        considered healthy. Exits nonzero when the listener is unavailable.
        """
    case "doctor":
        return """
        Usage:
          accio-computer-use doctor

        Print Accessibility and Screen Recording permission state, daemon
        connectivity, and the current app-bundle and executable identities.
        Effective permission state comes from Apple's runtime APIs for this
        process. This command does not open permission prompts; use
        `accio-computer-use setup` for the interactive permission guide. A
        standalone CLI has a separate macOS permission identity; the supported
        install uses the app-bundled CLI.
        """
    case "list-apps":
        return """
        Usage:
          accio-computer-use list-apps

        Print running and recently used user apps. Accio Computer Use itself is
        omitted because it is the automation host, not a target app.
        """
    case "snapshot":
        return """
        Usage:
          accio-computer-use snapshot <app>

        Arguments:
          <app>    App name or bundle identifier.

        Print the accessibility snapshot for an app.
        """
    case "call":
        return """
        Usage:
          accio-computer-use call <tool-name> [<json-args>] [--raw] [--image-out <image-out>] [--inline-image] [--compact] [--no-relaunch] [--no-daemon] [--socket <socket>]

        Arguments:
          <tool-name>    Name of the tool to invoke.
          <json-args>    JSON object string for the tool's inputSchema. If omitted, reads from stdin when stdin is a pipe.

        Options:
          --raw                Print raw JSON result instead of unwrapping.
          --image-out <path>   Write the first image content block to this file.
          --inline-image       Inline base64 PNG in stdout JSON.
          --compact            Emit raw multiline AX text plus compact JSON metadata.
          --filter <text>      Filter AX tree output to lines matching <text> (case-insensitive) and their ancestors.
          --no-relaunch        Ignored (accepted for flag compatibility).
          --no-daemon          Skip daemon forwarding.
          --socket <path>      Override daemon Unix socket path.

        Examples:
          accio-computer-use call list_apps
          accio-computer-use call get_app_state '{"app":"TextEdit"}'
          accio-computer-use call click '{"app":"TextEdit","element_index":"3"}' --image-out /tmp/shot.png
        """
    default:
        return "Unknown help topic: \(command ?? "")\n\n\(helpText())"
    }
}

private func parseCall(arguments: [String]) throws -> CLICommand {
    if arguments.count == 1, ["-h", "--help"].contains(arguments[0]) {
        return .help(command: "call")
    }

    var toolName: String?
    var argumentsJSON: String?
    var raw = false
    var imageOut: String?
    var inlineImage = false
    var compact = false
    var filter: String?
    var socketPath: String?
    var noDaemon = false
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help":
            return .help(command: "call")
        case "--raw":
            raw = true
        case "--inline-image":
            inlineImage = true
        case "--compact":
            compact = true
        case "--no-relaunch":
            break
        case "--no-daemon":
            noDaemon = true
        case "--image-out":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw CLIError(message: "--image-out requires a file path", helpCommand: "call")
            }
            imageOut = arguments[valueIndex]
            index = valueIndex
        case "--filter":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw CLIError(message: "--filter requires a search string", helpCommand: "call")
            }
            filter = arguments[valueIndex]
            index = valueIndex
        case "--socket":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw CLIError(message: "--socket requires a path", helpCommand: "call")
            }
            socketPath = arguments[valueIndex]
            index = valueIndex
        default:
            if argument.hasPrefix("-") {
                throw CLIError(message: "Unknown option '\(argument)'. Did you mean '--raw'?", helpCommand: "call")
            }
            if toolName == nil {
                toolName = argument
            } else if argumentsJSON == nil {
                argumentsJSON = argument
            } else {
                throw CLIError(message: "Unexpected positional argument: \(argument)", helpCommand: "call")
            }
        }
        index += 1
    }

    guard let toolName else {
        throw CLIError(message: "call requires a tool name", helpCommand: "call")
    }

    let options = CallOptions(raw: raw, imageOut: imageOut, inlineImage: inlineImage, compact: compact, filter: filter, socketPath: socketPath, noDaemon: noDaemon)
    return .call(toolName: toolName, argumentsJSON: argumentsJSON, options: options)
}
