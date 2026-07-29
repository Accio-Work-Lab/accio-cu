import Foundation

public enum SetupAssistant {

    // MARK: - ANSI Helpers

    private static func styled(_ text: String, colored: Bool, _ codes: String...) -> String {
        guard colored, !codes.isEmpty else { return text }
        return "\u{001B}[\(codes.joined(separator: ";"))m\(text)\u{001B}[0m"
    }

    private static func key(_ label: String, colored: Bool) -> String {
        styled("[\(label)]", colored: colored, "38;5;44")
    }

    private static func visibleLength(_ text: String) -> Int {
        var count = 0
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            if char == "\u{001B}" {
                while let next = iterator.next(), next != "m" {}
            } else {
                count += 1
            }
        }
        return count
    }

    private static func padded(_ text: String, to width: Int) -> String {
        let padding = max(0, width - visibleLength(text))
        return text + String(repeating: " ", count: padding)
    }

    private static func panel(title: String, lines: [String], colored: Bool, width: Int = 66, indent: String = "  ") -> String {
        let contentWidth = max(24, width - 4)
        let borderWidth = width - 2
        let label = " \(title) "
        let topFill = String(repeating: "─", count: max(0, borderWidth - label.count))
        let top = "\(indent)╭\(styled(label, colored: colored, "1", "38;5;42"))\(styled(topFill, colored: colored, "2"))╮"
        let body = lines.map { "\(indent)│ \(padded($0, to: contentWidth)) │" }.joined(separator: "\n")
        let bottom = "\(indent)╰\(styled(String(repeating: "─", count: borderWidth), colored: colored, "2"))╯"
        return "\(top)\n\(body)\n\(bottom)"
    }

    // MARK: - Logo

    /// Logo adapted from the MIT-licensed `bit` ANSI font library
    /// (https://github.com/paulilaaso/bit): a 12×9 bitmap "ACCIO"
    /// wordmark rendered with full pixel blocks (█), washed in a VERTICAL
    /// cyan→mint gradient (one stop per row). A solid cyan rule closes the
    /// mark, and a dim "COMPUTER USE" tagline sits below, right-aligned.
    ///
    /// Layout contract — keeps logo and panels visually flush:
    ///   • indent: 2 cols (matches `panel(... indent: "  ")`)
    ///   • wordmark: 12 cols/glyph × 5 glyphs + 1-col gutter × 4 = 64 cols
    ///   • total left-edge → right-edge: 2 + 64 = 66 cols == panel width
    public static func logo(colored: Bool) -> String {
        let esc = "\u{001B}"
        let r  = colored ? "\(esc)[0m" : ""

        // Vertical gradient (top → bottom): cyan → mint, 9 stops for 9 rows.
        let stops: [String]
        if colored {
            stops = [
                "\(esc)[38;5;87m",   // cyan
                "\(esc)[38;5;86m",
                "\(esc)[38;5;86m",
                "\(esc)[38;5;80m",   // sky-teal
                "\(esc)[38;5;79m",   // teal
                "\(esc)[38;5;78m",   // mint
                "\(esc)[38;5;78m",
                "\(esc)[38;5;114m",
                "\(esc)[38;5;120m",  // light green
            ]
        } else {
            stops = Array(repeating: "", count: 9)
        }

        // Each glyph is 12 cols × 9 rows. Built as a 2× horizontal scale of a
        // 6×9 base bitmap — preserves the adapted glyph shape while giving bold,
        // chunky pixels that read well at typical terminal cell aspect ratios.
        // 5 glyphs + 4 single-space gutters = 12*5 + 4 = 64 cells.
        let A = [
            "            ",
            "  ████████  ",
            "██        ██",
            "██        ██",
            "████████████",
            "██        ██",
            "██        ██",
            "██        ██",
            "██        ██",
        ]
        let cc = [
            "            ",
            "  ████████  ",
            "██        ██",
            "██          ",
            "██          ",
            "██          ",
            "██          ",
            "██        ██",
            "  ████████  ",
        ]
        let i = [
            "            ",
            "████████████",
            "    ████    ",
            "    ████    ",
            "    ████    ",
            "    ████    ",
            "    ████    ",
            "    ████    ",
            "████████████",
        ]
        let o = [
            "            ",
            "  ████████  ",
            "██        ██",
            "██        ██",
            "██        ██",
            "██        ██",
            "██        ██",
            "██        ██",
            "  ████████  ",
        ]

        // Compose each row: one gradient color spans the whole row.
        let glyphs = [A, cc, cc, i, o]
        var lines: [String] = []
        for row in 0..<9 {
            var line = stops[row]
            for (idx, g) in glyphs.enumerated() {
                if idx > 0 { line += " " }
                line += g[row]
            }
            line += r
            lines.append(line)
        }

        // Solid cyan rule under the wordmark, 64 cells wide.
        let ruleColor = colored ? "\(esc)[38;5;80m" : ""
        let rule = "\(ruleColor)\(String(repeating: "─", count: 64))\(r)"

        // Tagline: Unicode small-caps (U+1D04 ᴄ, U+1D0F ᴏ, U+1D0D ᴍ,
        // U+1D18 ᴘ, U+1D1C ᴜ, U+1D1B ᴛ, U+1D07 ᴇ, U+0280 ʀ, U+A731 ꜱ).
        // These are single code-points that render as small-caps glyphs in
        // any Unicode-capable terminal — no bitmap art required, and they
        // look like a proper "designed" caption next to the pixel wordmark.
        // Letter-spaced once for a more deliberate, typographic feel.
        let tagColor = colored ? "\(esc)[2;38;5;245m" : ""
        let tagText  = "ᴄ ᴏ ᴍ ᴘ ᴜ ᴛ ᴇ ʀ   ᴜ ꜱ ᴇ"   // 23 visible cells
        let visibleTagWidth = 23
        let tagPad   = String(repeating: " ", count: max(0, 64 - visibleTagWidth))
        let tagLine  = "\(tagPad)\(tagColor)\(tagText)\(r)"

        let indent = "  "
        return """

        \(indent)\(lines[0])
        \(indent)\(lines[1])
        \(indent)\(lines[2])
        \(indent)\(lines[3])
        \(indent)\(lines[4])
        \(indent)\(lines[5])
        \(indent)\(lines[6])
        \(indent)\(lines[7])
        \(indent)\(lines[8])
        \(indent)\(rule)
        \(indent)\(tagLine)
        """
    }

    // MARK: - Dashboard

    public static func dashboard(status: CompanionStatus, interactive: Bool) -> String {
        let ax = status.permissions.accessibilityTrusted
        let sr = status.permissions.screenCaptureGranted
        let dn = status.daemonSocketExists
        let paused = status.automationPaused
        let activityAvailable = status.activityChannelAvailable
        let mode = interactive ? "interactive TUI" : "status"

        let overallDot: String
        let overallColor: String
        switch status.health {
        case .ready:              overallDot = styled("●", colored: interactive, "38;5;42")
                                  overallColor = "38;5;42"
        case .paused:             overallDot = styled("●", colored: interactive, "38;5;214")
                                  overallColor = "38;5;214"
        case .needsPermission:    overallDot = styled("●", colored: interactive, "38;5;214")
                                  overallColor = "38;5;214"
        case .activityUnavailable: overallDot = styled("●", colored: interactive, "38;5;203")
                                   overallColor = "38;5;203"
        case .daemonUnavailable:  overallDot = styled("●", colored: interactive, "38;5;245")
                                  overallColor = "38;5;245"
        }
        let axIcon = ax ? styled("✓", colored: interactive, "38;5;42")  : styled("✗", colored: interactive, "38;5;203")
        let srIcon = sr ? styled("✓", colored: interactive, "38;5;42")  : styled("✗", colored: interactive, "38;5;203")
        let dnIcon = dn ? styled("●", colored: interactive, "38;5;42")  : styled("○", colored: interactive, "2")
        let automationIcon = paused ? styled("⏸", colored: interactive, "38;5;214") : styled("●", colored: interactive, "38;5;42")
        let activityIcon = activityAvailable ? styled("●", colored: interactive, "38;5;42") : styled("✗", colored: interactive, "38;5;203")

        let overallVal  = styled(status.shortLabel, colored: interactive, overallColor)
        let axVal       = styled(ax ? "granted" : "missing", colored: interactive, ax ? "38;5;42" : "38;5;203")
        let srVal       = styled(sr ? "granted" : "missing", colored: interactive, sr ? "38;5;42" : "38;5;203")
        let dnVal       = styled(dn ? "running" : "not running", colored: interactive, dn ? "38;5;42" : "2")
        let automationVal = styled(paused ? "paused" : "running", colored: interactive, paused ? "38;5;214" : "38;5;42")
        let activityVal = styled(activityAvailable ? "available" : "unavailable", colored: interactive, activityAvailable ? "38;5;42" : "38;5;203")
        let sockVal     = styled(status.daemonSocketPath, colored: interactive, "2")

        let title    = "\(styled("Accio setup", colored: interactive, "1")) \(styled("(\(mode))", colored: interactive, "2"))"
        let mcpCmd   = styled("accio-computer-use mcp", colored: interactive, "38;5;44")
        let daemonCmd = styled("scripts/install-daemon.sh", colored: interactive, "38;5;44")
        let daemonRecovery = styled("scripts/install-daemon.sh install", colored: interactive, "38;5;44")
        let setupCmd = styled("scripts/install-macos.sh --verify --install-skill", colored: interactive, "38;5;44")

        return """
        \(logo(colored: interactive))

          \(title)

        \(panel(title: "System Status", lines: [
            "\(overallDot) Overall            \(overallVal)",
            "\(axIcon) Accessibility      \(axVal)",
            "\(srIcon) Screen Recording   \(srVal)",
            "\(automationIcon) Automation         \(automationVal)",
            "\(activityIcon) Activity indicator  \(activityVal)",
            "\(dnIcon) Background daemon   \(dnVal)",
            "  Socket             \(sockVal)"
          ], colored: interactive))

        \(panel(title: "Next Steps", lines: [
            "\(key("r", colored: interactive)) Refresh status after changing permissions.",
            "\(key("2", colored: interactive)) Request Accessibility permission.",
            "\(key("3", colored: interactive)) Open Accessibility settings.",
            "\(key("4", colored: interactive)) Request Screen Recording permission.",
            "\(key("5", colored: interactive)) Open Screen Recording settings.",
            "Install: \(setupCmd)",
            "System Settings should list Accio Computer Use.",
            "On-demand screenshots only; Accio does not continuously record video.",
            paused ? "Resume future actions from the menu bar app." : "Pause future actions at any time from the menu bar app.",
            "After Screen Recording changes, restart the menu bar helper.",
            "Agent clients use stdio MCP: \(mcpCmd)",
            dn
                ? "Persistent service: \(daemonCmd) (healthy)"
                : "After permissions are effective: \(daemonRecovery)"
          ], colored: interactive))
        """
    }

    // MARK: - Menu & Prompt

    private static func menuText(colored: Bool) -> String {
        return """

        \(panel(title: "Actions", lines: [
            "\(key("1", colored: colored)) Refresh status",
            "\(key("2", colored: colored)) Request Accessibility permission",
            "\(key("3", colored: colored)) Open Accessibility settings",
            "\(key("4", colored: colored)) Request Screen Recording permission",
            "\(key("5", colored: colored)) Open Screen Recording settings",
            "\(key("6", colored: colored)) Print MCP config",
            "\(key("7", colored: colored)) Print common CLI commands",
            "\(styled("[q]", colored: colored, "2")) Quit"
          ], colored: colored))
        """
    }

    private static func prompt(colored: Bool) -> String {
        colored ? "\n  \u{001B}[38;5;42m❯\u{001B}[0m " : "\n  > "
    }

    // MARK: - Run

    public static func run(
        socketPath: String = DaemonServer.defaultSocketPath,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        let interactive = isatty(input.fileDescriptor) != 0
        printLine(dashboard(status: CompanionStatus.current(socketPath: socketPath), interactive: interactive), output: output)

        guard interactive else { return }

        var shouldContinue = true
        while shouldContinue {
            printLine(menuText(colored: true), output: output)
            printLine(prompt(colored: true), output: output, terminator: "")

            guard let choice = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return
            }

            switch choice {
            case "1", "r", "refresh":
                printLine(dashboard(status: CompanionStatus.current(socketPath: socketPath), interactive: true), output: output)
            case "2", "a", "accessibility":
                printLine(styled("  → Requesting Accessibility permission…", colored: true, "2"), output: output)
                _ = PermissionSupport.startAuthorizationFlow(for: .accessibility)
            case "3":
                printLine(styled("  → Opening Accessibility settings…", colored: true, "2"), output: output)
                PermissionSupport.openSystemSettings(for: .accessibility)
            case "4", "s", "screen":
                printLine(styled("  → Requesting Screen Recording permission…", colored: true, "2"), output: output)
                _ = PermissionSupport.startAuthorizationFlow(for: .screenRecording)
            case "5":
                printLine(styled("  → Opening Screen Recording settings…", colored: true, "2"), output: output)
                PermissionSupport.openSystemSettings(for: .screenRecording)
            case "6", "m", "mcp":
                printLine("\n\(MCPConfigurationSnippet.text)", output: output)
            case "7", "c", "commands":
                printLine("\n\(CompanionClipboardText.quickCommands)", output: output)
            case "q", "quit", "exit":
                shouldContinue = false
            default:
                printLine(styled("  ✗ Unknown option: \(choice)", colored: true, "38;5;203"), output: output)
            }
        }
    }

    // MARK: - IO

    private static func printLine(_ value: String, output: FileHandle, terminator: String = "\n") {
        guard let data = (value + terminator).data(using: .utf8) else { return }
        output.write(data)
    }
}
