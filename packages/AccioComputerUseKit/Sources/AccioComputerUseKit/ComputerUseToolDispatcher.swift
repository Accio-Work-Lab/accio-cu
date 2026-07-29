import Foundation

public final class ComputerUseToolDispatcher {
    private let maxClickCount = 3
    private let maxScrollPages = 20.0
    private let maxWaitTimeoutSeconds = 30.0
    private let maxWaitPollIntervalSeconds = 2.0
    private let service: ComputerUseService
    private let automationPolicy: AutomationPolicy
    private let activityPublisher: any AutomationActivityPublishing
    private let requiresVisibleActivity: Bool
    private let activityListenerAvailable: () -> Bool

    public init(
        service: ComputerUseService = ComputerUseService(),
        automationPolicy: AutomationPolicy = AutomationPolicy(),
        activityPublisher: any AutomationActivityPublishing = ActivitySocketClient.shared,
        requiresVisibleActivity: Bool? = nil,
        activityListenerAvailable: (() -> Bool)? = nil
    ) {
        self.service = service
        self.automationPolicy = automationPolicy
        self.activityPublisher = activityPublisher
        let socketPublisher = activityPublisher as? ActivitySocketClient
        self.requiresVisibleActivity = requiresVisibleActivity
            ?? (socketPublisher != nil && Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame)
        if let activityListenerAvailable {
            self.activityListenerAvailable = activityListenerAvailable
        } else if let socketPublisher {
            let socketPath = socketPublisher.socketPath
            self.activityListenerAvailable = {
                ActivitySocketClient.hasTrustedListener(at: socketPath)
            }
        } else {
            self.activityListenerAvailable = { true }
        }
    }

    public func callTool(name: String, arguments: [String: Any]) throws -> ToolCallResult {
        try automationPolicy.authorizeToolCall(named: name)

        let resolvedTargetApp = (arguments["app"] as? String)
            .flatMap(AppDiscovery.activityDisplayName(matching:))
        guard let descriptor = ToolActivityDescriptor(
            toolName: name,
            arguments: arguments,
            resolvedTargetApp: resolvedTargetApp
        ) else {
            return try dispatchTool(name: name, arguments: arguments)
        }
        if requiresVisibleActivity,
           descriptor.actionKind != .listApps,
           !activityListenerAvailable() {
            throw ComputerUseError.message(
                "The visible activity indicator is unavailable. Open Accio Computer Use from Applications, then retry."
            )
        }
        let anticipatedCapture = descriptor.anticipatedCaptureKind(arguments: arguments)
        let beginEvent = descriptor.event(captureKind: anticipatedCapture)
        if requiresVisibleActivity,
           descriptor.actionKind != .listApps,
           let socketPublisher = activityPublisher as? ActivitySocketClient {
            // The activity server acknowledges only after its main-thread HUD
            // handler returns. A successful preflight alone is not sufficient:
            // the helper may exit or reject delivery before the action starts.
            guard socketPublisher.publishAndWaitForAcknowledgement(beginEvent) else {
                throw ComputerUseError.message(
                    "The visible activity indicator did not confirm display. Open Accio Computer Use from Applications, then retry."
                )
            }
        } else {
            activityPublisher.publish(beginEvent)
        }

        do {
            let result = try dispatchTool(name: name, arguments: arguments)
            let capturedImage = result.content.contains(where: { $0.dictionary["type"] as? String == "image" })
            let captureKind: AutomationCaptureKind = capturedImage
                ? (anticipatedCapture == .screenSnapshot ? .screenSnapshot : .windowSnapshot)
                : .none
            activityPublisher.publish(descriptor.event(phase: .completed, captureKind: captureKind))
            return result
        } catch {
            activityPublisher.publish(descriptor.event(phase: .failed))
            throw error
        }
    }

    private func dispatchTool(name: String, arguments: [String: Any]) throws -> ToolCallResult {
        switch name {
        case "list_apps":
            return service.listApps()
        case "get_app_state":
            return try service.getAppState(app: requireString("app", in: arguments))
        case "get_screen_state":
            return try service.getScreenState()
        case "click":
            let app = optionalString("app", in: arguments)
            let coordSpace = try requireCoordinateSpace(in: arguments)
            if let app {
                return try service.click(
                    app: app,
                    stableRef: optionalString("stable_ref", in: arguments),
                    elementIndex: optionalString("element_index", in: arguments),
                    elementText: resolveElementText(in: arguments),
                    snapshotId: optionalString("snapshot_id", in: arguments),
                    x: try optionalDouble("x", in: arguments),
                    y: try optionalDouble("y", in: arguments),
                    coordinateSpace: coordSpace,
                    clickCount: try optionalClickCount(in: arguments),
                    mouseButton: optionalString("mouse_button", in: arguments) ?? "left"
                )
            } else {
                guard let x = try optionalDouble("x", in: arguments),
                      let y = try optionalDouble("y", in: arguments) else {
                    let hasElementTarget = optionalString("stable_ref", in: arguments) != nil
                        || optionalString("element_text", in: arguments) != nil
                        || optionalString("element_label", in: arguments) != nil
                        || optionalString("element_index", in: arguments) != nil
                    let hint = hasElementTarget
                        ? "click with element targeting requires 'app'. For screen-level click, use x/y coordinates instead. Usage: {\"app\":\"TextEdit\",\"stable_ref\":\"a12\"}"
                        : "click without app requires x and y coordinates from get_screen_state screenshot. Usage: {\"x\":100,\"y\":200}"
                    throw ComputerUseError.invalidArguments(hint)
                }
                return try service.clickScreen(
                    x: x, y: y,
                    coordinateSpace: coordSpace,
                    clickCount: try optionalClickCount(in: arguments),
                    mouseButton: optionalString("mouse_button", in: arguments) ?? "left"
                )
            }
        case "double_click":
            let app = optionalString("app", in: arguments)
            let coordSpace = try requireCoordinateSpace(in: arguments)
            if let app {
                return try service.click(
                    app: app,
                    stableRef: optionalString("stable_ref", in: arguments),
                    elementIndex: optionalString("element_index", in: arguments),
                    elementText: resolveElementText(in: arguments),
                    snapshotId: optionalString("snapshot_id", in: arguments),
                    x: try optionalDouble("x", in: arguments),
                    y: try optionalDouble("y", in: arguments),
                    coordinateSpace: coordSpace,
                    clickCount: 2,
                    mouseButton: optionalString("mouse_button", in: arguments) ?? "left"
                )
            } else {
                guard let x = try optionalDouble("x", in: arguments),
                      let y = try optionalDouble("y", in: arguments) else {
                    throw ComputerUseError.invalidArguments("double_click without app requires x and y coordinates from get_screen_state screenshot")
                }
                return try service.clickScreen(
                    x: x, y: y,
                    coordinateSpace: coordSpace,
                    clickCount: 2,
                    mouseButton: optionalString("mouse_button", in: arguments) ?? "left"
                )
            }
        case "hover":
            let hoverX = try optionalDouble("x", in: arguments)
            let hoverY = try optionalDouble("y", in: arguments)
            let hasElementTarget = optionalString("stable_ref", in: arguments) != nil
                || optionalString("element_index", in: arguments) != nil
                || resolveElementText(in: arguments) != nil
            guard hasElementTarget || (hoverX != nil && hoverY != nil) else {
                throw ComputerUseError.invalidArguments(
                    "hover requires an element target or both x and y coordinates."
                )
            }
            return try service.hover(
                app: requireString("app", in: arguments),
                stableRef: optionalString("stable_ref", in: arguments),
                elementIndex: optionalString("element_index", in: arguments),
                elementText: resolveElementText(in: arguments),
                snapshotId: optionalString("snapshot_id", in: arguments),
                x: hoverX,
                y: hoverY,
                coordinateSpace: try requireCoordinateSpace(in: arguments)
            )
        case "perform_secondary_action":
            return try service.performSecondaryAction(
                app: requireString("app", in: arguments),
                stableRef: optionalString("stable_ref", in: arguments),
                elementIndex: optionalString("element_index", in: arguments),
                elementText: resolveElementText(in: arguments),
                snapshotId: optionalString("snapshot_id", in: arguments),
                action: requireString("action", in: arguments)
            )
        case "scroll":
            return try service.scroll(
                app: requireString("app", in: arguments),
                direction: requireString("direction", in: arguments),
                stableRef: optionalString("stable_ref", in: arguments),
                elementIndex: optionalString("element_index", in: arguments),
                elementText: resolveElementText(in: arguments),
                snapshotId: optionalString("snapshot_id", in: arguments),
                pages: try optionalBoundedPositiveDouble("pages", in: arguments, max: maxScrollPages) ?? 1
            )
        case "drag":
            let app = optionalString("app", in: arguments)
            let coordSpace = try requireCoordinateSpace(in: arguments)
            if let app {
                return try service.drag(
                    app: app,
                    fromX: requireDouble("from_x", in: arguments),
                    fromY: requireDouble("from_y", in: arguments),
                    toX: requireDouble("to_x", in: arguments),
                    toY: requireDouble("to_y", in: arguments),
                    coordinateSpace: coordSpace
                )
            } else {
                return try service.dragScreen(
                    fromX: requireDouble("from_x", in: arguments),
                    fromY: requireDouble("from_y", in: arguments),
                    toX: requireDouble("to_x", in: arguments),
                    toY: requireDouble("to_y", in: arguments),
                    coordinateSpace: coordSpace
                )
            }
        case "type_text":
            return try service.typeText(
                app: requireString("app", in: arguments),
                text: requireString("text", in: arguments),
                stableRef: optionalString("stable_ref", in: arguments),
                elementIndex: optionalString("element_index", in: arguments),
                elementText: resolveElementText(in: arguments),
                snapshotId: optionalString("snapshot_id", in: arguments)
            )
        case "press_key":
            return try service.pressKey(
                app: requireString("app", in: arguments),
                key: requireString("key", in: arguments)
            )
        case "set_value":
            return try service.setValue(
                app: requireString("app", in: arguments),
                stableRef: optionalString("stable_ref", in: arguments),
                elementIndex: optionalString("element_index", in: arguments),
                elementText: resolveElementText(in: arguments),
                snapshotId: optionalString("snapshot_id", in: arguments),
                value: requireString("value", in: arguments)
            )
        case "wait_for_element":
            let waitMode = optionalString("wait_mode", in: arguments) ?? "element_text"
            let elementText = resolveElementText(in: arguments)
            if waitMode != "element_count_changed", elementText == nil {
                throw ComputerUseError.missingArgument("element_text (or element_label)")
            }
            return try service.waitForElement(
                app: requireString("app", in: arguments),
                elementText: elementText,
                timeoutSeconds: try optionalBoundedPositiveDouble("timeout_seconds", in: arguments, max: maxWaitTimeoutSeconds) ?? 10,
                waitMode: waitMode,
                pollInterval: try optionalBoundedPositiveDouble("poll_interval", in: arguments, max: maxWaitPollIntervalSeconds) ?? 0.5
            )
        case "menu_select":
            return try service.menuSelect(
                app: requireString("app", in: arguments),
                path: try requireStringArray("path", in: arguments)
            )
        default:
            let known = ["list_apps", "get_app_state", "get_screen_state", "click", "double_click", "hover", "scroll", "drag",
                         "type_text", "press_key", "set_value", "perform_secondary_action", "wait_for_element",
                         "menu_select"]
            throw ComputerUseError.unsupportedTool(name, known: known)
        }
    }

    public func callToolAsResult(name: String, arguments: [String: Any]) -> ToolCallResult {
        do {
            return try callTool(name: name, arguments: arguments)
        } catch let error as ComputerUseError {
            return ToolCallResult.text(error.errorDescription ?? String(describing: error), isError: error.toolResultIsError)
        } catch {
            return ToolCallResult.text((error as? LocalizedError)?.errorDescription ?? String(describing: error), isError: true)
        }
    }

    /// Accepts both `element_text` and `element_label` (alias) for element targeting.
    private func resolveElementText(in arguments: [String: Any]) -> String? {
        optionalString("element_text", in: arguments)
            ?? optionalString("element_label", in: arguments)
    }

    /// Resolves the coordinate space for x/y inputs. Precedence:
    /// 1. Per-call `coordinate_space` argument
    /// 2. `ACCIO_COMPUTER_USE_COORDINATE_SPACE` environment variable
    /// 3. `.pixel` (default)
    private func requireCoordinateSpace(in arguments: [String: Any]) throws -> CoordinateSpace {
        if let raw = optionalString("coordinate_space", in: arguments) {
            return try CoordinateSpace.parseDeclared(raw)
        }
        return CoordinateSpace.sessionDefault()
    }

    private func requireString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let raw = arguments[key] else {
            throw ComputerUseError.missingArgument(key)
        }
        let value = coerceToString(raw)
        guard !value.isEmpty else {
            throw ComputerUseError.missingArgument(key)
        }
        return value
    }

    private func optionalString(_ key: String, in arguments: [String: Any]) -> String? {
        guard let raw = arguments[key] else { return nil }
        let value = coerceToString(raw)
        return value.isEmpty ? nil : value
    }

    private func coerceToString(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFNumberIsFloatType(number) {
                let d = number.doubleValue
                if d == d.rounded(.towardZero) && abs(d) < 1e15 {
                    return String(Int64(d))
                }
                return number.stringValue
            }
            return number.stringValue
        }
        return String(describing: value)
    }

    private func requireDouble(_ key: String, in arguments: [String: Any]) throws -> Double {
        guard let value = try optionalDouble(key, in: arguments) else {
            throw ComputerUseError.missingArgument(key)
        }
        return value
    }

    private func requireStringArray(_ key: String, in arguments: [String: Any]) throws -> [String] {
        guard let raw = arguments[key] else {
            throw ComputerUseError.missingArgument(key)
        }
        guard let values = raw as? [Any] else {
            throw ComputerUseError.invalidArguments("\(key) must be an array of strings.")
        }
        let strings = values.map(coerceToString).filter { !$0.isEmpty }
        guard strings.count == values.count, !strings.isEmpty else {
            throw ComputerUseError.invalidArguments("\(key) must contain at least one non-empty string.")
        }
        return strings
    }

    private func optionalDouble(_ key: String, in arguments: [String: Any]) throws -> Double? {
        guard let raw = arguments[key] else { return nil }

        let value: Double
        if let double = raw as? Double {
            value = double
        } else if let integer = raw as? Int {
            value = Double(integer)
        } else if let number = raw as? NSNumber {
            value = number.doubleValue
        } else {
            return nil
        }

        guard value.isFinite else {
            throw ComputerUseError.invalidArguments("\(key) must be a finite number.")
        }
        return value
    }

    private func optionalPositiveDouble(_ key: String, in arguments: [String: Any]) throws -> Double? {
        guard let value = try optionalDouble(key, in: arguments) else {
            return nil
        }
        guard value > 0 else {
            throw ComputerUseError.invalidArguments("\(key) must be > 0.")
        }
        return value
    }

    private func optionalBoundedPositiveDouble(_ key: String, in arguments: [String: Any], max maxValue: Double) throws -> Double? {
        guard let value = try optionalPositiveDouble(key, in: arguments) else {
            return nil
        }
        guard value <= maxValue else {
            throw ComputerUseError.invalidArguments("\(key) must be <= \(maxValue).")
        }
        return value
    }

    private func optionalClickCount(in arguments: [String: Any]) throws -> Int {
        guard let value = try optionalDouble("click_count", in: arguments) else {
            return 1
        }
        guard value <= Double(Int.max) else {
            throw ComputerUseError.invalidArguments("click_count is too large.")
        }
        let count = max(Int(value.rounded(.towardZero)), 1)
        guard count <= maxClickCount else {
            throw ComputerUseError.invalidArguments("click_count must be between 1 and \(maxClickCount).")
        }
        return count
    }
}

public func runSingleToolCall(
    toolName: String,
    argumentsJSON: String?,
    options: CallOptions = CallOptions(),
    service: ComputerUseService? = nil
) throws -> String {
    var arguments: [String: Any] = [:]
    if let json = argumentsJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
       !json.isEmpty,
       let data = json.data(using: .utf8),
       let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
        arguments = parsed
    }

    // Try daemon forwarding first (unless --no-daemon)
    if !options.noDaemon {
        let socketPath = options.socketPath ?? DaemonServer.defaultSocketPath
        if let daemonResult = DaemonClient.callTool(socketPath: socketPath, toolName: toolName, arguments: arguments) {
            // Detect degraded daemon responses: if the daemon returned elements=0
            // with a screen recording warning, it likely lacks effective runtime
            // permissions (common for LaunchAgent daemons on macOS 15+). Fall
            // back to direct local execution which inherits the caller's TCC
            // context.
            if isDaemonResultDegraded(daemonResult) {
                FileHandle.standardError.write(Data(
                    "Daemon response degraded (elements=0 or missing screenshot). Falling back to direct execution.\n".utf8
                ))
            } else {
                return try formatDaemonResult(daemonResult, options: options)
            }
        }
        // Daemon unavailable or degraded — proceed to local execution
    }

    // Local fallback is intentionally legacy-shaped: no stable_ref emission and
    // no AXDIFF. Naked refs only make sense when a daemon/session preserves the
    // ref namespace across calls.
    let localService = service ?? ComputerUseService(stableRefsEnabled: false, actionDiffEnabled: false)
    let dispatcher = ComputerUseToolDispatcher(service: localService)
    let result = dispatcher.callToolAsResult(name: toolName, arguments: arguments)

    if let imageOutPath = options.imageOut {
        writeFirstImage(from: result, to: imageOutPath)
    }

    var outputDict: [String: Any]
    if options.raw {
        outputDict = result.asDictionary
    } else {
        outputDict = unwrappedOutput(from: result, inlineImage: options.inlineImage)
    }

    if let filter = options.filter, !filter.isEmpty {
        if let text = outputDict["text"] as? String {
            outputDict["text"] = filterTreeOutput(text, query: filter)
        } else if var contentArray = outputDict["content"] as? [[String: Any]] {
            for i in contentArray.indices {
                if contentArray[i]["type"] as? String == "text",
                   let text = contentArray[i]["text"] as? String {
                    contentArray[i]["text"] = filterTreeOutput(text, query: filter)
                }
            }
            outputDict["content"] = contentArray
        }
    }

    let text: String
    if options.compact {
        // Compact mode: serialize the "text" field (AX tree) as raw lines outside
        // the JSON envelope to avoid a single ultra-long JSON string that gets
        // truncated by tool layers (e.g. Claude Code's Bash tool).
        text = try compactMultilineOutput(outputDict)
    } else {
        let jsonOptions: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        let data = try JSONSerialization.data(withJSONObject: outputDict, options: jsonOptions)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode call output as JSON.")
        }
        text = encoded
    }

    if !options.raw, result.isError {
        FileHandle.standardError.write(Data((result.primaryText ?? "Tool reported an error.").utf8))
        FileHandle.standardError.write(Data("\n".utf8))
    }

    return text
}

private func unwrappedOutput(from result: ToolCallResult, inlineImage: Bool) -> [String: Any] {
    var dict: [String: Any] = [:]
    if let text = result.primaryText {
        dict["text"] = text
    }
    if result.isError {
        dict["isError"] = true
    }

    for item in result.content {
        if let mimeType = item.dictionary["mimeType"] as? String, mimeType == "image/png" {
            dict["has_screenshot"] = true
            if inlineImage, let b64 = item.dictionary["data"] as? String {
                dict["screenshot_png_b64"] = b64
            }
            if let b64 = item.dictionary["data"] as? String,
               let bytes = Data(base64Encoded: b64) {
                let path = autoSaveScreenshot(bytes)
                if let path {
                    dict["screenshot_path"] = path
                }
            }
            break
        }
    }

    return dict
}

private func autoSaveScreenshot(_ pngData: Data) -> String? {
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("accio-cu-screenshots")
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir) {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    let filename = "snapshot-\(ProcessInfo.processInfo.globallyUniqueString.prefix(8)).png"
    let path = (dir as NSString).appendingPathComponent(filename)
    do {
        try pngData.write(to: URL(fileURLWithPath: path))
        return path
    } catch {
        return nil
    }
}

/// Filters AX tree text output to show only lines matching the query (case-insensitive)
/// plus their ancestor lines (determined by indentation), and the header lines.
private func filterTreeOutput(_ text: String, query: String) -> String {
    let lines = text.components(separatedBy: "\n")
    let loweredQuery = query.lowercased()

    func indentDepth(_ line: String) -> Int {
        let trimmed = line.drop(while: { $0 == " " })
        return (line.count - trimmed.count) / 2
    }

    func isTreeLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[")
    }

    // Phase 1: separate header lines from tree lines. Continuation lines (non-[
    // lines that appear after the first tree line) are merged into the preceding
    // tree line so multi-line action descriptions don't leak into the header.
    var headerLines: [String] = []
    var treeLines: [(index: Int, line: String)] = []
    var seenFirstTreeLine = false
    for (i, line) in lines.enumerated() {
        if isTreeLine(line) {
            seenFirstTreeLine = true
            treeLines.append((i, line))
        } else if seenFirstTreeLine, !treeLines.isEmpty {
            let last = treeLines.count - 1
            treeLines[last].line += "\n" + line
        } else {
            headerLines.append(line)
        }
    }

    // Find matching tree lines.
    var matchIndices = Set<Int>()
    for (i, entry) in treeLines.enumerated() {
        if entry.line.lowercased().contains(loweredQuery) {
            matchIndices.insert(i)
        }
    }

    if matchIndices.isEmpty {
        return headerLines.joined(separator: "\n") +
            "\n\n(No elements matching '\(query)' found in the AX tree.)"
    }

    // For each match, walk backwards to include ancestor lines (by decreasing indent).
    var includedIndices = Set<Int>()
    for matchIdx in matchIndices {
        includedIndices.insert(matchIdx)
        let matchDepth = indentDepth(treeLines[matchIdx].line)
        var parentDepth = matchDepth - 1
        var cursor = matchIdx - 1
        while cursor >= 0 && parentDepth >= 0 {
            let d = indentDepth(treeLines[cursor].line)
            if d == parentDepth {
                includedIndices.insert(cursor)
                parentDepth -= 1
            }
            cursor -= 1
        }
    }

    let sortedIndices = includedIndices.sorted()
    var result = headerLines
    result.append("")
    result.append("(Filtered by '\(query)': \(matchIndices.count) match(es), showing ancestors for context)")
    for idx in sortedIndices {
        result.append(treeLines[idx].line)
    }

    return result.joined(separator: "\n")
}

/// Compact mode output: emits the "text" field (AX tree + action summary) as
/// raw multi-line text, followed by a small JSON metadata block for the remaining
/// keys. This avoids a single ultra-long JSON string value that tool layers
/// (Claude Code Bash) truncate.
///
/// Format:
///   <raw text lines>
///   ---
///   {"has_screenshot":true,"screenshot_path":"/tmp/..."}
private func compactMultilineOutput(_ dict: [String: Any]) throws -> String {
    var result: [String] = []

    if let text = dict["text"] as? String {
        result.append(text)
    }

    var meta = dict
    meta.removeValue(forKey: "text")
    // Also strip base64 screenshot from compact output — it's enormous and the
    // screenshot_path provides the same data via file read.
    meta.removeValue(forKey: "screenshot_png_b64")

    if !meta.isEmpty {
        result.append("---")
        let jsonOptions: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        let data = try JSONSerialization.data(withJSONObject: meta, options: jsonOptions)
        if let jsonStr = String(data: data, encoding: .utf8) {
            result.append(jsonStr)
        }
    }

    return result.joined(separator: "\n")
}

private func writeFirstImage(from result: ToolCallResult, to path: String) {
    for item in result.content {
        guard let mimeType = item.dictionary["mimeType"] as? String,
              mimeType == "image/png",
              let base64 = item.dictionary["data"] as? String,
              let bytes = Data(base64Encoded: base64) else {
            continue
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try bytes.write(to: url)
        } catch {
            FileHandle.standardError.write(
                Data("--image-out: failed to write \(url.path): \(error.localizedDescription)\n".utf8)
            )
        }
        return
    }
    FileHandle.standardError.write(
        Data("--image-out: no image content in tool response; file not written\n".utf8)
    )
}

/// Detects if a daemon response indicates degraded capabilities (broken permissions).
/// A degraded response typically has elements=0 and/or a screen recording warning,
/// indicating the daemon process lacks effective TCC permissions at runtime.
private func isDaemonResultDegraded(_ result: [String: Any]) -> Bool {
    let contentArray = result["content"] as? [[String: Any]] ?? []
    for item in contentArray {
        guard item["type"] as? String == "text",
              let text = item["text"] as? String else { continue }
        let hasZeroElements = text.contains("elements=0")
        let hasScreenWarning = text.contains("Screen Recording permission not granted")
        if hasZeroElements || hasScreenWarning {
            return true
        }
    }
    return false
}

/// Formats the raw JSON-RPC result dictionary from the daemon into CLI output,
/// applying the same output options (--raw, --filter, --image-out, --compact, --inline-image).
private func formatDaemonResult(_ daemonResult: [String: Any], options: CallOptions) throws -> String {
    // The daemon returns the MCP result envelope: {"content":[...],"isError":false}
    let contentArray = daemonResult["content"] as? [[String: Any]] ?? []
    let isError = daemonResult["isError"] as? Bool ?? false

    // Write first image if --image-out specified
    if let imageOutPath = options.imageOut {
        for item in contentArray {
            guard let mimeType = item["mimeType"] as? String,
                  mimeType == "image/png",
                  let base64 = item["data"] as? String,
                  let bytes = Data(base64Encoded: base64) else { continue }
            let url = URL(fileURLWithPath: (imageOutPath as NSString).expandingTildeInPath)
            try? bytes.write(to: url)
            break
        }
    }

    // Build output dictionary
    var outputDict: [String: Any]
    if options.raw {
        outputDict = daemonResult
    } else {
        outputDict = [:]
        // Extract primary text
        for item in contentArray {
            if item["type"] as? String == "text", let text = item["text"] as? String {
                outputDict["text"] = text
                break
            }
        }
        if isError {
            outputDict["isError"] = true
        }
        // Handle image
        for item in contentArray {
            if let mimeType = item["mimeType"] as? String, mimeType == "image/png" {
                outputDict["has_screenshot"] = true
                if options.inlineImage, let b64 = item["data"] as? String {
                    outputDict["screenshot_png_b64"] = b64
                }
                if let b64 = item["data"] as? String,
                   let bytes = Data(base64Encoded: b64) {
                    if let path = autoSaveScreenshot(bytes) {
                        outputDict["screenshot_path"] = path
                    }
                }
                break
            }
        }
    }

    // Apply --filter
    if let filter = options.filter, !filter.isEmpty {
        if let text = outputDict["text"] as? String {
            outputDict["text"] = filterTreeOutput(text, query: filter)
        }
    }

    // Format output
    let text: String
    if options.compact {
        text = try compactMultilineOutput(outputDict)
    } else {
        let jsonOptions: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        let data = try JSONSerialization.data(withJSONObject: outputDict, options: jsonOptions)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode daemon result as JSON.")
        }
        text = encoded
    }

    // Print error to stderr if applicable
    if !options.raw, isError {
        let errorText = (outputDict["text"] as? String) ?? "Tool reported an error."
        FileHandle.standardError.write(Data((errorText + "\n").utf8))
    }

    return text
}
