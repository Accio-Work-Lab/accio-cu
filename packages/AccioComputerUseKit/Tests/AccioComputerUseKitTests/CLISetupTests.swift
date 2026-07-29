import Darwin
import Testing
@testable import AccioComputerUseKit

@Test("code command forwards every remaining argument to the coding harness")
func codeCommandForwardsArguments() throws {
    #expect(try parseCLI(arguments: ["code"]) == .code(arguments: []))
    #expect(
        try parseCLI(arguments: ["code", "mcp", "--timeout", "90"])
            == .code(arguments: ["mcp", "--timeout", "90"])
    )
}

@Test("piped Python selects coding mode without changing native help")
func pipedPythonSelectsCodingMode() throws {
    #expect(try resolveCLI(arguments: [], hasPipedStdin: true) == .code(arguments: []))
    #expect(
        try resolveCLI(arguments: ["--pretty"], hasPipedStdin: true)
            == .code(arguments: ["--pretty"])
    )
    #expect(try resolveCLI(arguments: [], hasPipedStdin: false) == .gui)
    #expect(try resolveCLI(arguments: ["--help"], hasPipedStdin: true) == .help(command: nil))
}

@Test("stdin routing recognizes streams without waiting for bytes to arrive")
func stdinRoutingRecognizesDataStreams() {
    #expect(standardInputSupportsPayload(isTerminal: false, fileMode: mode_t(S_IFIFO)))
    #expect(standardInputSupportsPayload(isTerminal: false, fileMode: mode_t(S_IFREG)))
    #expect(standardInputSupportsPayload(isTerminal: false, fileMode: mode_t(S_IFSOCK)))
    #expect(!standardInputSupportsPayload(isTerminal: false, fileMode: mode_t(S_IFCHR)))
    #expect(!standardInputSupportsPayload(isTerminal: true, fileMode: mode_t(S_IFIFO)))
    #expect(!standardInputSupportsPayload(isTerminal: false, fileMode: nil))
}

@Test("general and code help present accio-computer-use as the only public command")
func codeHelpUsesSinglePublicCommand() {
    let generalHelp = helpText()
    let codeHelp = helpText(command: "code")

    #expect(generalHelp.contains("accio-computer-use < program.py"))
    #expect(generalHelp.contains("code [options]"))
    #expect(codeHelp.contains("accio-computer-use code mcp"))
    #expect(!generalHelp.contains("accio-cu-code"))
    #expect(!codeHelp.contains("accio-cu-code"))
}

@Test("setup and tui commands open the setup assistant")
func setupAndTUICommandsOpenSetupAssistant() throws {
    #expect(try parseCLI(arguments: ["setup"]) == .setup)
    #expect(try parseCLI(arguments: ["tui"]) == .setup)
}

@Test("daemon status accepts an optional socket path")
func daemonStatusAcceptsOptionalSocketPath() throws {
    #expect(try parseCLI(arguments: ["daemon-status"]) == .daemonStatus(socketPath: nil))
    #expect(
        try parseCLI(arguments: ["daemon-status", "/tmp/accio-test.sock"])
            == .daemonStatus(socketPath: "/tmp/accio-test.sock")
    )
    #expect(throws: CLIError.self) {
        try parseCLI(arguments: ["daemon-status", "one", "two"])
    }
}

@Test("Finder process serial number launches GUI only from an app bundle")
func finderProcessSerialNumberIsStrictlyScopedToAppLaunch() throws {
    #expect(try parseCLI(
        arguments: ["-psn_0_12345"],
        isAppBundleLaunch: true
    ) == .gui)

    #expect(throws: CLIError.self) {
        try parseCLI(arguments: ["-psn_0_12345"], isAppBundleLaunch: false)
    }
    #expect(throws: CLIError.self) {
        try parseCLI(arguments: ["-psn_bad"], isAppBundleLaunch: true)
    }
    #expect(throws: CLIError.self) {
        try parseCLI(arguments: ["-psn_٠_123"], isAppBundleLaunch: true)
    }
    #expect(throws: CLIError.self) {
        try parseCLI(arguments: ["-psn_0_1", "doctor"], isAppBundleLaunch: true)
    }
}

@Test("unified CLI routing preserves Finder app-bundle launches")
func unifiedCLIRoutingPreservesFinderLaunches() throws {
    #expect(try resolveCLI(
        arguments: ["-psn_0_12345"],
        hasPipedStdin: true,
        isAppBundleLaunch: true
    ) == .gui)
}

@Test("setup help is presented as the recommended onboarding entry")
func setupHelpIsRecommendedOnboardingEntry() {
    let generalHelp = helpText()
    #expect(generalHelp.contains("setup"))
    #expect(generalHelp.contains("Recommended first-run setup"))

    let setupHelp = helpText(command: "setup")
    #expect(setupHelp.contains("accio-computer-use setup"))
    #expect(setupHelp.contains("permissions"))
    #expect(setupHelp.contains("app"))
    #expect(setupHelp.contains("permission container"))
    #expect(setupHelp.contains("System Settings' app lists is expected"))
    #expect(setupHelp.contains("MCP"))
}

@Test("doctor help points users to setup for interactive permission work")
func doctorHelpPointsUsersToSetupForInteractivePermissionWork() {
    let doctorHelp = helpText(command: "doctor")
    let normalizedDoctorHelp = doctorHelp
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")

    #expect(doctorHelp.contains("does not open permission prompts"))
    #expect(doctorHelp.contains("accio-computer-use setup"))
    #expect(doctorHelp.contains("standalone CLI has a separate macOS"))
    #expect(normalizedDoctorHelp.contains("daemon connectivity"))
}

@Test("daemon status help defines live-listener health")
func daemonStatusHelpDefinesLiveListenerHealth() {
    let daemonHelp = helpText(command: "daemon-status")

    #expect(daemonHelp.contains("live listener"))
    #expect(daemonHelp.contains("socket file alone is not"))
    #expect(daemonHelp.contains("Exits nonzero"))
}

@Test("list-apps help explains Accio is omitted as the host")
func listAppsHelpExplainsAccioIsOmittedAsHost() {
    let listAppsHelp = helpText(command: "list-apps")

    #expect(listAppsHelp.contains("Accio Computer Use itself is"))
    #expect(listAppsHelp.contains("automation host"))
}

@Test("setup logo has a plain and colored terminal variant")
func setupLogoHasPlainAndColoredTerminalVariant() {
    let plain = SetupAssistant.logo(colored: false)
    let colored = SetupAssistant.logo(colored: true)

    #expect(plain.contains("████████"))
    #expect(plain.contains("████████████"))
    #expect(plain.contains("ᴄ ᴏ ᴍ ᴘ ᴜ ᴛ ᴇ ʀ"))
    #expect(plain.contains("ᴜ ꜱ ᴇ"))
    #expect(!plain.contains("\u{001B}["))
    #expect(colored.contains("\u{001B}[38;5;87m"))
    #expect(colored.contains("\u{001B}[2;38;5;245m"))
    #expect(colored.contains("ᴄ ᴏ ᴍ ᴘ ᴜ ᴛ ᴇ ʀ"))
}

@Test("setup dashboard shows permissions daemon and MCP next steps")
func setupDashboardShowsPermissionsDaemonAndMCPNextSteps() {
    let permissions = PermissionDiagnostics(accessibilityTrusted: false, screenCaptureGranted: true)
    let status = CompanionStatus(permissions: permissions, daemonSocketExists: false)

    let dashboard = SetupAssistant.dashboard(status: status, interactive: false)

    #expect(dashboard.contains("Accio setup"))
    #expect(dashboard.contains("╭ System Status"))
    #expect(dashboard.contains("╭ Next Steps"))
    #expect(dashboard.contains("Accessibility      missing"))
    #expect(dashboard.contains("Screen Recording   granted"))
    #expect(dashboard.contains("On-demand screenshots only; Accio does not continuously record video."))
    #expect(dashboard.contains("Automation         running"))
    #expect(dashboard.contains("Activity indicator  available"))
    #expect(dashboard.contains("Background daemon   not running"))
    #expect(dashboard.contains("Install: scripts/install-macos.sh --verify --install-skill"))
    #expect(dashboard.contains("System Settings should list Accio Computer Use."))
    #expect(dashboard.contains("After Screen Recording changes"))
    #expect(dashboard.contains("accio-computer-use mcp"))
    #expect(dashboard.contains("menu bar helper"))

    #expect(dashboard.contains("[r] Refresh status"))
    #expect(dashboard.contains("[2] Request Accessibility permission"))
    #expect(dashboard.contains("[3] Open Accessibility settings"))
    #expect(dashboard.contains("[4] Request Screen Recording permission"))
    #expect(dashboard.contains("[5] Open Screen Recording settings"))
    #expect(dashboard.contains("scripts/install-daemon.sh"))
    #expect(dashboard.contains("After permissions are effective"))
    #expect(dashboard.contains("✗"))
    #expect(dashboard.contains("✓"))
}

@Test("setup dashboard makes a user pause visible")
func setupDashboardShowsPausedAutomation() {
    let permissions = PermissionDiagnostics(accessibilityTrusted: true, screenCaptureGranted: true)
    let status = CompanionStatus(
        permissions: permissions,
        daemonSocketExists: true,
        automationPaused: true
    )

    let dashboard = SetupAssistant.dashboard(status: status, interactive: false)

    #expect(dashboard.contains("Automation         paused"))
    #expect(dashboard.contains("Resume future actions from the menu bar app"))
}

@Test("setup dashboard uses ANSI colors in interactive mode")
func setupDashboardUsesANSIColorsInInteractiveMode() {
    let permissions = PermissionDiagnostics(accessibilityTrusted: true, screenCaptureGranted: false)
    let status = CompanionStatus(permissions: permissions, daemonSocketExists: true)

    let plain = SetupAssistant.dashboard(status: status, interactive: false)
    let colored = SetupAssistant.dashboard(status: status, interactive: true)

    #expect(!plain.contains("\u{001B}["))
    #expect(colored.contains("\u{001B}["))
    #expect(colored.contains("\u{001B}[1m"))
}
