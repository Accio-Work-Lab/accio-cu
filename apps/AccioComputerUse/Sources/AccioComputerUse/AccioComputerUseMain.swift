import AppKit
import Foundation
import AccioComputerUseKit

@main
enum AccioComputerUseMain {
    @MainActor
    private static var menuBarController: MenuBarController?

    static func main() {
        defer { ActivitySocketClient.flush() }
        do {
            try run()
        } catch let error as CLIError {
            writeToStandardError(error.errorDescription ?? error.message)
            ActivitySocketClient.flush()
            exit(EXIT_FAILURE)
        } catch let error as ComputerUseError {
            writeToStandardError(error.errorDescription ?? String(describing: error))
            ActivitySocketClient.flush()
            exit(EXIT_FAILURE)
        } catch let error as DaemonStartupError {
            writeToStandardError(error.errorDescription ?? String(describing: error))
            ActivitySocketClient.flush()
            exit(error.exitCode)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            writeToStandardError(message)
            ActivitySocketClient.flush()
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        registerComputerUseDefaults()

        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = try resolveCLI(
            arguments: arguments,
            hasPipedStdin: standardInputCarriesPayload(),
            isAppBundleLaunch: Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        )

        switch command {
        case .gui:
            MainActor.assumeIsolated {
                menuBarController = MenuBarController()
                menuBarController?.run()
            }

        case let .code(arguments):
            let status = try CodingHarnessLauncher.run(arguments: arguments)
            if status != 0 {
                ActivitySocketClient.flush()
                exit(status)
            }

        case let .setup(waitForPermissions):
            let completed = SetupAssistant.run(waitForPermissions: waitForPermissions)
            if waitForPermissions && !completed {
                exit(EXIT_FAILURE)
            }

        case .permissionStatus:
            let permissions = PermissionDiagnostics.runtimeProbe()
            print(permissions.summary)
            if !permissions.allGranted {
                exit(EXIT_FAILURE)
            }

        case .mcp:
            // stdio MCP runs as a subprocess of the MCP client; a modal alert
            // would be invisible. Log to stderr so misconfigured grants surface
            // before the first tool call fails inside SnapshotBuilder.
            PermissionSupport.logAuthorizationStatus()
            let service = ComputerUseService()
            let server = StdioMCPServer(service: service)
            try server.run()

        case let .serve(socketPath):
            let path = socketPath ?? DaemonServer.defaultSocketPath
            // Daemon/server modes must not show modal permission alerts. The
            // server throws a permission-pending error with exit status 2 so
            // the installer can start interactive onboarding instead.
            let service = ComputerUseService()
            let daemon = DaemonServer(socketPath: path, service: service)
            try daemon.run()

        case let .daemonStatus(socketPath):
            let path = socketPath ?? DaemonServer.defaultSocketPath
            if DaemonClient.isAvailable(socketPath: path) {
                print("Daemon: running")
                print("Socket: \(path)")
            } else {
                print("Daemon: unavailable")
                print("Socket: \(path)")
                exit(EXIT_FAILURE)
            }

        case .doctor:
            print("Version: \(resolvedVersionDescription())")
            let permissions = PermissionDiagnostics.current()
            print(permissions.summary)
            let daemonAvailable = DaemonClient.isAvailable()
            print("Daemon: \(daemonAvailable ? "running" : "unavailable")")
            print("Socket: \(DaemonServer.defaultSocketPath)")
            print(PermissionSupport.installModelSummary())
            print("Current code identities (diagnostic only):")
            for line in PermissionSupport.authorizationIdentityLines() {
                print(line)
            }

            if !permissions.allGranted {
                print("")
                for missing in permissions.missingPermissions {
                    print("  Missing: \(missing.title)")
                    print("  Open System Settings → Privacy & Security → \(missing.title)")
                    print("  Or open: \(missing.settingsURL)")
                    print("")
                }
                print("Run `accio-computer-use setup` to open an interactive permission guide.")
            }
            if !daemonAvailable {
                print("")
                print("No live current-user daemon listener is available.")
                print("A loaded LaunchAgent or an existing socket file alone does not prove health.")
                print("After permissions are effective, run `scripts/install-daemon.sh install`.")
            }

        case .listApps:
            try AutomationPolicy().authorizeToolCall(named: "list_apps")
            let service = ComputerUseService()
            print(service.listApps().primaryText ?? "")

        case let .snapshot(app):
            try AutomationPolicy().authorizeToolCall(named: "get_app_state")
            let service = ComputerUseService()
            print(try service.getAppState(app: app).primaryText ?? "")

        case let .call(toolName, argumentsJSON, options):
            let resolvedJSON = argumentsJSON ?? readPipedStdinIfAvailable()
            let output = try runSingleToolCall(
                toolName: toolName,
                argumentsJSON: resolvedJSON,
                options: options
            )
            print(output)

        case let .help(command):
            print(helpText(command: command))

        case .version:
            print(resolvedVersionDescription())
        }
    }

    private static func writeToStandardError(_ message: String) {
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

private func readPipedStdinIfAvailable() -> String? {
    guard standardInputCarriesPayload() else { return nil }

    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return text
}

private func standardInputCarriesPayload() -> Bool {
    let fd = fileno(stdin)
    var metadata = stat()
    let fileMode = fstat(fd, &metadata) == 0 ? metadata.st_mode : nil
    return standardInputSupportsPayload(
        isTerminal: isatty(fd) != 0,
        fileMode: fileMode
    )
}
