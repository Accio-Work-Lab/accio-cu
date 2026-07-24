import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import ScreenCaptureKit

// _cgWindowListCreateImage is declared in Permissions.swift as an internal function

// MARK: - Constants

private let accessibilityTreeMaxNodeCount = 600
private let accessibilityTreeMaxDepth = 64
private let screenshotCaptureTimeout: TimeInterval = 5
private let screenshotResultMaxPNGBytes = 900_000
private let screenshotResultMaxDimension: CGFloat = 1280
private let screenshotResultMinScale: CGFloat = 0.25
private let windowVisibilityRecoveryDelay: TimeInterval = 0.7
private let axWebAreaRole = "AXWebArea"
private let axContentsAttribute = "AXContents"
private let axVisibleChildrenAttribute = "AXVisibleChildren"

private let snapshotNoWindowFoundMessage = "Apple event error -10005: cgWindowNotFound"

// MARK: - Element record

public final class ElementRecord: @unchecked Sendable {
    public let index: Int
    public let identifier: String?
    public let element: AXUIElement?
    public let localFrame: CGRect?
    public let rawActions: [String]
    public let prettyActions: [String]
    public let displayText: String?
    public let role: String?
    public var stableRef: String?
    public var stableKey: String

    public init(
        index: Int,
        identifier: String?,
        element: AXUIElement?,
        localFrame: CGRect?,
        rawActions: [String],
        prettyActions: [String],
        displayText: String? = nil,
        role: String? = nil,
        stableRef: String? = nil,
        stableKey: String = ""
    ) {
        self.index = index
        self.identifier = identifier
        self.element = element
        self.localFrame = localFrame
        self.rawActions = rawActions
        self.prettyActions = prettyActions
        self.displayText = displayText
        self.role = role
        self.stableRef = stableRef
        self.stableKey = stableKey
    }
}

// MARK: - Snapshot text style

public enum SnapshotTextStyle: Sendable {
    case fullState
    case actionResult
}

// MARK: - App snapshot

public struct AppSnapshot {
    public let snapshotID: String
    public let app: RunningAppDescriptor
    public let windowTitle: String?
    public let windowBounds: CGRect?
    public let targetWindowID: CGWindowID?
    public let targetWindowLayer: Int?
    public let screenshotPNGData: Data?
    public let screenRecordingDenied: Bool
    public let treeLines: [String]
    public let focusedSummary: String?
    public let selectedText: String?
    public let elements: [Int: ElementRecord]
    public let elementCount: Int

    public var screenshotPixelSize: CGSize? {
        guard
            let screenshotPNGData,
            let imageSource = CGImageSourceCreateWithData(screenshotPNGData as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            pixelWidth > 0,
            pixelHeight > 0
        else {
            return nil
        }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }

    public var renderedText: String {
        renderedText(style: .fullState)
    }

    public func renderedText(style: SnapshotTextStyle) -> String {
        var lines: [String] = []
        let displayTitle = displayWindowTitle(windowTitle, appName: app.name)
        let appReference = app.bundleIdentifier ?? app.name
        let screenshotDimensions: String? = screenshotPixelSize.map {
            "screenshot_size=\(Int($0.width))x\(Int($0.height))"
        }
        let stateLine = stateSummaryLine(appReference: appReference, displayTitle: displayTitle)

        switch style {
        case .fullState:
            var header = "App=\(appReference) (pid \(app.pid)), snapshot=\(snapshotID), elements=\(elementCount)"
            if let screenshotDimensions { header += ", \(screenshotDimensions)" }
            lines.append(stateLine)
            lines.append(header)
            lines.append("Window: \(quoted(displayTitle)), App: \(app.name).")
            lines.append(contentsOf: treeLinesWithStableRefs())

            if elementCount == 0 {
                lines.append("")
                lines.append("⚠ No AX elements found. This app may have a non-standard accessibility structure.")
                lines.append("  Suggestions:")
                lines.append("  - Use get_screen_state screenshot + coordinate-based click/drag for visual interactions")
                lines.append("  - Use shell commands (osascript, defaults read) to query or verify app state")
            }

            if let selectedText, !selectedText.isEmpty {
                lines.append("")
                lines.append("Selected text: [\(selectedText)]")
            } else if let focusedSummary {
                lines.append("")
                lines.append("The focused UI element is \(focusedSummary).")
            }

        case .actionResult:
            var header = "snapshot=\(snapshotID), Window: \(quoted(displayTitle)), App: \(app.name), elements=\(elementCount)"
            if let screenshotDimensions { header += ", \(screenshotDimensions)" }
            header += "."
            lines.append(stateLine)
            lines.append(header)
            lines.append(contentsOf: treeLinesWithStableRefs())

            if elementCount == 0 {
                lines.append("")
                lines.append("⚠ No AX elements found. Use get_screen_state + coordinate-based interaction or shell commands instead.")
            }

            if let selectedText, !selectedText.isEmpty {
                lines.append("")
                lines.append("Selected text: [\(selectedText)]")
            } else if let focusedSummary {
                lines.append("")
                lines.append("Focused: \(focusedSummary).")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func stateSummaryLine(appReference: String, displayTitle: String) -> String {
        let menuBarPresent = treeLines.contains { $0.contains("AXMenuBar") }
        let modalCount = countLines(containingAnyRole: ["AXDialog"])
        let sheetCount = countLines(containingAnyRole: ["AXSheet"])
        let editableCount = elements.values.filter { record in
            if record.role == kAXTextFieldRole as String
                || record.role == "AXTextArea"
                || record.role == "AXTextView"
                || record.role == kAXComboBoxRole as String
                || record.role == "AXSearchField" {
                return true
            }
            return record.displayText.map { $0.contains("traits=(settable") || $0.contains("settable") } ?? false
        }.count
        let buttonCount = elements.values.filter { $0.role == kAXButtonRole as String }.count
        return "[State] app=\(appReference) pid=\(app.pid) window=\(quoted(displayTitle)) focused=\(focusedSummary ?? "none") menu_bar=\(menuBarPresent ? "true" : "false") modals=\(modalCount) sheets=\(sheetCount) editable_fields=\(editableCount) buttons=\(buttonCount)"
    }

    private func countLines(containingAnyRole roles: [String]) -> Int {
        treeLines.filter { line in
            roles.contains { role in line.contains(role) }
        }.count
    }

    func treeLinesWithStableRefs() -> [String] {
        treeLines.map { line in
            guard let index = AXSnapshotDiff.lineIndex(in: line),
                  let ref = elements[index]?.stableRef else {
                return line
            }
            return AXSnapshotDiff.insertStableRef(into: line, ref: ref)
        }
    }
}

// MARK: - Snapshot builder

public enum SnapshotBuilder {
    /// When `readOnly` is true, the snapshot builder will NOT unminimize or
    /// unhide windows. The AX tree is still fully accessible for minimized
    /// windows; only the screenshot may be unavailable.
    public static func build(for app: RunningAppDescriptor, readOnly: Bool = false) throws -> AppSnapshot {
        let permissions = PermissionDiagnostics.current()

        // PermissionDiagnostics.current() uses Apple's current-process runtime
        // APIs, so this reflects the capability that this snapshot call can use.
        if !permissions.accessibilityTrusted {
            throw ComputerUseError.permissionDenied(
                "Accessibility permission is required for Accio Computer Use. Open System Settings → Privacy & Security → Accessibility and enable this app."
            )
        }

        let appElement = AXUIElementCreateApplication(app.pid)
        enableBestEffortAccessibilityModes(appElement)

        let systemWide = AXUIElementCreateSystemWide()
        var focusedApplication = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute)
        var focusedWindow = preferredFocusedWindow(appElement: appElement, appPID: app.pid, focusedApplication: focusedApplication, systemWide: systemWide)
        if focusedWindow == nil, !readOnly, recoverVisibleWindow(for: app, appElement: appElement, preferredWindow: nil) {
            focusedApplication = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute)
            focusedWindow = preferredFocusedWindow(appElement: appElement, appPID: app.pid, focusedApplication: focusedApplication, systemWide: systemWide)
        }

        var rootWindow: AXUIElement?
        var axWindowTitle: String?

        if let resolvedFocusedWindow = focusedWindow {
            rootWindow = resolvedFocusedWindow
            axWindowTitle = stringValue(of: resolvedFocusedWindow, attribute: kAXTitleAttribute)
        } else {
            // AX-blind or no focused window: still attempt capture via CGWindow.
            rootWindow = firstWindow(for: appElement) ?? firstAnyWindow(for: appElement)
            if let w = rootWindow {
                axWindowTitle = stringValue(of: w, attribute: kAXTitleAttribute)
            }
        }

        var capture = WindowCapture.resolve(for: app.pid, titleHint: axWindowTitle)
        if capture == nil, !readOnly, let root = rootWindow, recoverVisibleWindow(for: app, appElement: appElement, preferredWindow: root) {
            focusedApplication = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute)
            if let recoveredWindow = preferredFocusedWindow(appElement: appElement, appPID: app.pid, focusedApplication: focusedApplication, systemWide: systemWide) {
                rootWindow = recoveredWindow
                axWindowTitle = stringValue(of: recoveredWindow, attribute: kAXTitleAttribute)
                capture = WindowCapture.resolve(for: app.pid, titleHint: axWindowTitle)
            }
        }

        if capture == nil {
            capture = WindowCapture.resolve(for: app.pid, titleHint: nil)
        }

        // Electron apps (DingTalk, Slack, etc.) transiently destroy and recreate
        // windows during internal transitions. Retry with progressive delays
        // before reporting the window as gone. Also covers apps that were just
        // launched and need time to create their first window.
        if capture == nil, !readOnly {
            for retryDelay in [0.3, 0.5, 1.0] {
                Thread.sleep(forTimeInterval: retryDelay)
                capture = WindowCapture.resolve(for: app.pid, titleHint: axWindowTitle)
                    ?? WindowCapture.resolve(for: app.pid, titleHint: nil)
                if capture != nil { break }
            }
        }

        guard let windowCapture = capture else {
            if readOnly, rootWindow != nil {
                // In readOnly mode, proceed without screenshot (window is
                // minimized or off-screen). The AX tree is still accessible.
                return buildAXOnlySnapshot(app: app, appElement: appElement, rootWindow: rootWindow, systemWide: systemWide, permissions: permissions)
            }
            throw ComputerUseError.stateUnavailable(snapshotNoWindowFoundMessage)
        }

        // Electron apps (DingTalk, Slack) can enter a state where the AX window
        // exists but its children are gone — the window element is found but
        // the tree walk produces only the window + menu bar (typically < 20
        // elements).  This happens when the app was deactivated and Chromium
        // destroyed its DOM/AX subtree.  Briefly activating the app forces
        // Chromium to rebuild the full AX tree.
        // Check if rootWindow is actually a window (not the app element itself,
        // which Electron returns from kAXFocusedWindowAttribute when the real
        // window tree is broken).  Also verify it has children — an empty shell
        // means Chromium destroyed its DOM subtree after deactivation.
        let isRealWindow = rootWindow.map {
            stringValue(of: $0, attribute: kAXRoleAttribute) == kAXWindowRole as String
        } ?? false
        let windowChildCount = rootWindow.flatMap {
            (copyArray($0, attribute: kAXChildrenAttribute) as [AXUIElement]?)?.count
        } ?? 0
        let needsAXRecovery = !readOnly && !forceBackgroundMode && (!isRealWindow || windowChildCount == 0)
        if needsAXRecovery {
            // AX tree is broken (CEF/Electron destroyed its DOM subtree after
            // deactivation). Activate to force a rebuild, then re-discover the
            // window. Focus restoration is handled by preservingFrontmostApp.
            // When prefer-background mode is ON, we skip this and proceed with
            // a degraded AX tree (screenshot still available via CGWindow).
            let runningApp = NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier == app.pid
            }
            if let runningApp {
                try ActivationToastBridge.confirmIfNeeded(
                    for: app.pid,
                    appName: app.name,
                    reason: .accessibilityRecovery
                )
                runningApp.activate()

                let hasOnScreenWindow = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]])?
                    .contains { ($0[kCGWindowOwnerPID as String] as? Int32) == app.pid } ?? false
                if !hasOnScreenWindow, let bundleId = app.bundleIdentifier {
                    _ = openBundleIdentifier(bundleId)
                }

                // Electron/Chromium/CEF needs ~1-2s after activation to rebuild
                // its AX tree. Poll with progressive delays.
                for delay in [0.5, 0.5, 0.5, 0.5] {
                    Thread.sleep(forTimeInterval: delay)
                    focusedApplication = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute)
                    let candidate = preferredFocusedWindow(appElement: appElement, appPID: app.pid, focusedApplication: focusedApplication, systemWide: systemWide)
                        ?? firstWindow(for: appElement) ?? firstAnyWindow(for: appElement)
                    if let candidate,
                       stringValue(of: candidate, attribute: kAXRoleAttribute) == kAXWindowRole as String,
                       let children = copyArray(candidate, attribute: kAXChildrenAttribute) as [AXUIElement]?,
                       !children.isEmpty {
                        rootWindow = candidate
                        break
                    }
                }
                if let w = rootWindow {
                    axWindowTitle = stringValue(of: w, attribute: kAXTitleAttribute)
                }

                // Refresh window capture since activation may have brought
                // a previously off-screen window on-screen.
                if rootWindow != nil || !isRealWindow {
                    let refreshedTitle = rootWindow.flatMap { stringValue(of: $0, attribute: kAXTitleAttribute) }
                    if let refreshed = WindowCapture.resolve(for: app.pid, titleHint: refreshedTitle) {
                        capture = refreshed
                    }
                }
            }
        }

        let resolvedTitle = axWindowTitle ?? windowCapture.cgWindowTitle
        let windowBounds = windowCapture.bounds
        // Always attempt the capture — CGPreflightScreenCaptureAccess() is
        // unreliable for CLI tools in Terminal and in VMs. The actual capture
        // APIs check the responsible process (Terminal.app) and may succeed
        // even when the preflight says denied.
        let screenshotPNGData = windowCapture.pngDataIfAvailable()
        let screenRecordingDenied = screenshotPNGData == nil && !permissions.screenCaptureGranted

        let focusedElement = preferredFocusedElement(
            appElement: appElement,
            appPID: app.pid,
            focusedApplication: focusedApplication,
            systemWide: systemWide
        )

        let selectedText = focusedElement.flatMap(copySelectedText(_:))
        let context = TreeWalkContext(windowBounds: windowBounds, focusedElement: focusedElement)

        var walker = AccessibilityTreeWalker(context: context)
        if let rootWindow {
            walker.visit(rootWindow)
            if let menuBar = copyElement(appElement, attribute: kAXMenuBarAttribute),
               !CFEqual(menuBar, rootWindow)
            {
                walker.visit(menuBar)
            }
        }

        // Fallback: if window walk produced no elements, try app-level children
        // directly. System apps like Dock have non-standard AX structures where
        // UI elements (e.g. AXList) are children of the application element
        // rather than a window.
        if walker.records.isEmpty {
            if let appChildren = copyArray(appElement, attribute: kAXChildrenAttribute) as [AXUIElement]? {
                for child in appChildren {
                    let childRole = stringValue(of: child, attribute: kAXRoleAttribute) ?? ""
                    if childRole == kAXWindowRole as String { continue }
                    if childRole == "AXMenuBar" { continue }
                    walker.visit(child)
                }
            }
        }

        let snapshotID = String(format: "%08x", UInt32.random(in: 0...UInt32.max))

        return AppSnapshot(
            snapshotID: snapshotID,
            app: app,
            windowTitle: resolvedTitle,
            windowBounds: windowBounds,
            targetWindowID: windowCapture.windowID,
            targetWindowLayer: windowCapture.layer,
            screenshotPNGData: screenshotPNGData,
            screenRecordingDenied: screenRecordingDenied,
            treeLines: walker.lines,
            focusedSummary: walker.focusedSummary,
            selectedText: selectedText,
            elements: walker.records,
            elementCount: walker.records.count
        )
    }

    /// Builds a snapshot from the AX tree only (no screenshot). Used in readOnly
    /// mode when the window is minimized or otherwise not capturable via CGWindow.
    private static func buildAXOnlySnapshot(
        app: RunningAppDescriptor,
        appElement: AXUIElement,
        rootWindow: AXUIElement?,
        systemWide: AXUIElement,
        permissions: PermissionDiagnostics
    ) -> AppSnapshot {
        let axWindowTitle = rootWindow.flatMap { stringValue(of: $0, attribute: kAXTitleAttribute) }
        let focusedApplication = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute)
        let focusedElement = preferredFocusedElement(
            appElement: appElement,
            appPID: app.pid,
            focusedApplication: focusedApplication,
            systemWide: systemWide
        )
        let selectedText = focusedElement.flatMap(copySelectedText(_:))
        let context = TreeWalkContext(windowBounds: .zero, focusedElement: focusedElement)
        var walker = AccessibilityTreeWalker(context: context)
        if let rootWindow {
            walker.visit(rootWindow)
            if let menuBar = copyElement(appElement, attribute: kAXMenuBarAttribute),
               !CFEqual(menuBar, rootWindow) {
                walker.visit(menuBar)
            }
        }

        if walker.records.isEmpty {
            if let appChildren = copyArray(appElement, attribute: kAXChildrenAttribute) as [AXUIElement]? {
                for child in appChildren {
                    let childRole = stringValue(of: child, attribute: kAXRoleAttribute) ?? ""
                    if childRole == kAXWindowRole as String { continue }
                    if childRole == "AXMenuBar" { continue }
                    walker.visit(child)
                }
            }
        }

        let snapshotID = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        return AppSnapshot(
            snapshotID: snapshotID,
            app: app,
            windowTitle: axWindowTitle ?? app.name,
            windowBounds: nil,
            targetWindowID: nil,
            targetWindowLayer: nil,
            screenshotPNGData: nil,
            screenRecordingDenied: false,
            treeLines: walker.lines,
            focusedSummary: walker.focusedSummary,
            selectedText: selectedText,
            elements: walker.records,
            elementCount: walker.records.count
        )
    }

    // MARK: Window / visibility helpers

    private static func recoverVisibleWindow(for app: RunningAppDescriptor, appElement: AXUIElement, preferredWindow: AXUIElement?) -> Bool {
        var recovered = false

        // Only unhide if the app is actually hidden; unhide() on a visible app
        // can reactivate it and steal the foreground.
        if let runningApplication = NSRunningApplication(processIdentifier: app.pid),
           runningApplication.isHidden {
            recovered = runningApplication.unhide() || recovered
        }

        if let window = preferredWindow ?? firstAnyWindow(for: appElement) {
            recovered = unminimize(window) || recovered
        }

        if recovered {
            // This function is only called in non-readOnly (action) paths where
            // the window needs to be visible for input delivery. No focus
            // restoration here — the caller's preservingFrontmostApp handles it.
            Thread.sleep(forTimeInterval: windowVisibilityRecoveryDelay)
        }

        return recovered
    }

    private static func openBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", bundleIdentifier]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func firstWindow(for appElement: AXUIElement) -> AXUIElement? {
        guard let windows = copyArray(appElement, attribute: kAXWindowsAttribute) else { return nil }
        return windows.first(where: isUsableWindowElement(_:))
    }

    private static func firstAnyWindow(for appElement: AXUIElement) -> AXUIElement? {
        if let focused = copyElement(appElement, attribute: kAXFocusedWindowAttribute),
           stringValue(of: focused, attribute: kAXRoleAttribute) == kAXWindowRole as String {
            return focused
        }
        return copyArray(appElement, attribute: kAXWindowsAttribute)?
            .first(where: { stringValue(of: $0, attribute: kAXRoleAttribute) == kAXWindowRole as String })
    }

    private static func unminimize(_ window: AXUIElement) -> Bool {
        guard boolValue(of: window, attribute: kAXMinimizedAttribute) == true else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
    }

    private static func raise(_ window: AXUIElement) -> Bool {
        guard copyActions(window)?.contains(where: { $0.caseInsensitiveCompare(kAXRaiseAction as String) == .orderedSame }) == true else {
            return false
        }
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    private static func setBoolAttribute(named attribute: String, on element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue) == .success
    }

    private static func preferredFocusedWindow(
        appElement: AXUIElement,
        appPID: pid_t,
        focusedApplication: AXUIElement?,
        systemWide: AXUIElement
    ) -> AXUIElement? {
        if let focusedApplication, pid(of: focusedApplication) == appPID {
            return usableWindowElement(from: copyElement(systemWide, attribute: kAXFocusedWindowAttribute))
                ?? usableWindowElement(from: copyElement(focusedApplication, attribute: kAXFocusedWindowAttribute))
                ?? firstWindow(for: focusedApplication)
                ?? usableWindowElement(from: copyElement(appElement, attribute: kAXFocusedWindowAttribute))
                ?? firstWindow(for: appElement)
        }
        return usableWindowElement(from: copyElement(appElement, attribute: kAXFocusedWindowAttribute)) ?? firstWindow(for: appElement)
    }

    private static func usableWindowElement(from element: AXUIElement?) -> AXUIElement? {
        guard let element, isUsableWindowElement(element) else { return nil }
        return element
    }

    private static func isUsableWindowElement(_ element: AXUIElement) -> Bool {
        stringValue(of: element, attribute: kAXRoleAttribute) == kAXWindowRole as String
            && boolValue(of: element, attribute: kAXMinimizedAttribute) != true
    }

    private static func preferredFocusedElement(
        appElement: AXUIElement,
        appPID: pid_t,
        focusedApplication: AXUIElement?,
        systemWide: AXUIElement
    ) -> AXUIElement? {
        if let focusedApplication, pid(of: focusedApplication) == appPID {
            return copyElement(systemWide, attribute: kAXFocusedUIElementAttribute)
                ?? copyElement(focusedApplication, attribute: kAXFocusedUIElementAttribute)
                ?? copyElement(appElement, attribute: kAXFocusedUIElementAttribute)
        }
        return copyElement(appElement, attribute: kAXFocusedUIElementAttribute)
    }
}

// MARK: - Window capture

struct WindowCapture {
    let windowID: CGWindowID
    let bounds: CGRect
    let layer: Int?
    /// Window name from `CGWindowListCopyWindowInfo` for the resolved capture target.
    let cgWindowTitle: String?

    static func resolve(for pid: pid_t, titleHint: String?) -> WindowCapture? {
        // Try on-screen windows first (preferred — these have valid screen bounds).
        if let result = resolveFromList(for: pid, titleHint: titleHint, listOption: [.optionOnScreenOnly]) {
            return result
        }
        // Electron/web apps transiently hide windows during internal transitions.
        // Fall back to all windows (includes off-screen) so we don't error on a
        // momentary gap.
        return resolveFromList(for: pid, titleHint: titleHint, listOption: [.optionAll])
    }

    private static func resolveFromList(for pid: pid_t, titleHint: String?, listOption: CGWindowListOption) -> WindowCapture? {
        guard let infoList = CGWindowListCopyWindowInfo(listOption, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates: [WindowCaptureCandidate] = infoList.enumerated().compactMap { offset, info in
            guard
                let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                ownerPID == pid,
                let number = info[kCGWindowNumber as String] as? NSNumber,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
            else {
                return nil
            }

            let layer = info[kCGWindowLayer as String] as? Int
            let title = info[kCGWindowName as String] as? String
            let area = Int(bounds.width * bounds.height)
            return WindowCaptureCandidate(
                windowID: CGWindowID(number.uint32Value),
                layer: layer,
                bounds: bounds,
                title: title,
                area: area,
                frontToBackIndex: offset
            )
        }

        guard let best = preferredWindowCaptureCandidate(candidates, titleHint: titleHint) else {
            return nil
        }

        // Chrome/Electron apps use multiple overlapping CGWindows for
        // toolbar, tab bar, and content. Compute the union of all
        // normal-layer windows so that AX element visibility checks cover
        // the entire app surface, not just the selected sub-window.
        let normalLayerBounds = candidates
            .filter { ($0.layer ?? 0) == 0 && $0.area > 0 }
            .map(\.bounds)
        let effectiveBounds: CGRect
        if normalLayerBounds.count > 1 {
            effectiveBounds = normalLayerBounds.dropFirst()
                .reduce(normalLayerBounds[0]) { $0.union($1) }
        } else {
            effectiveBounds = best.bounds
        }

        return WindowCapture(windowID: best.windowID, bounds: effectiveBounds, layer: best.layer, cgWindowTitle: best.title)
    }

    func pngDataIfAvailable() -> Data? {
        // Always attempt ScreenCaptureKit first. Permission state can change
        // after a preflight, so the capture operation remains the final source
        // of truth for this request. On macOS 15+ CGWindowListCreateImage is
        // obsoleted and returns nil, making ScreenCaptureKit the only viable
        // capture path.
        //
        // If the binary lacks Screen Recording permission entirely,
        // captureScreenCaptureKit catches the error and returns nil rather
        // than triggering a system consent dialog (the dialog is only shown
        // by CGRequestScreenCaptureAccess, not by SCShareableContent).
        let image = Self.captureScreenCaptureKit(windowID: windowID, bounds: bounds)
            ?? Self.captureCGWindowListImage(windowID: windowID)
        guard let image else { return nil }
        return boundedScreenshotPNGData(for: image)
    }

    private static func captureScreenCaptureKit(windowID: CGWindowID, bounds: CGRect) -> CGImage? {
        try? BlockingAsyncBridge.run(timeout: screenshotCaptureTimeout) {
            let shareableContent = try await SCShareableContent.current
            guard let window = shareableContent.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let configuration = SCStreamConfiguration()
            let scaleFactor = bestEffortScaleFactor(for: bounds)
            let captureSize = window.frame.isEmpty ? bounds.size : window.frame.size
            configuration.width = max(1, Int(ceil(captureSize.width * scaleFactor)))
            configuration.height = max(1, Int(ceil(captureSize.height * scaleFactor)))
            configuration.showsCursor = false
            configuration.scalesToFit = false
            configuration.ignoreShadowsSingleWindow = true

            let filter = SCContentFilter(desktopIndependentWindow: window)

            do {
                return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration)
                return Self.cgImage(from: sample)
            }
        }
    }

    private static func cgImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvImageBuffer: buffer)
        let context = CIContext(options: nil)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    private static func captureCGWindowListImage(windowID: CGWindowID) -> CGImage? {
        _cgWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution])
    }

    private static func bestEffortScaleFactor(for bounds: CGRect) -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.intersects(bounds) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }
}

// MARK: - Window candidate selection

struct WindowCaptureCandidate {
    let windowID: CGWindowID
    let layer: Int?
    let bounds: CGRect
    let title: String?
    let area: Int
    let frontToBackIndex: Int
}

func preferredWindowCaptureCandidate(_ candidates: [WindowCaptureCandidate], titleHint: String?) -> WindowCaptureCandidate? {
    let usable = candidates
        .filter { ($0.layer ?? 0) == 0 && $0.area >= 20_000 }
        .sorted { lhs, rhs in
            lhs.frontToBackIndex < rhs.frontToBackIndex
        }

    guard !usable.isEmpty else {
        return candidates.sorted { lhs, rhs in
            lhs.area > rhs.area
        }.first
    }

    // Match title hint flexibly: exact match first, then containment
    // (Chrome/Electron AX titles often have " - AppName" suffix that
    // the CGWindow title omits).
    let hinted: WindowCaptureCandidate? = {
        guard let titleHint, !titleHint.isEmpty else { return nil }
        if let exact = usable.first(where: { $0.title == titleHint }) {
            return exact
        }
        return usable.first(where: { title in
            guard let t = title.title, !t.isEmpty else { return false }
            return titleHint.contains(t) || t.contains(titleHint)
        })
    }()

    guard let hinted else {
        // No title match: prefer the largest usable window rather than
        // the frontmost, to avoid picking small auxiliary popups.
        return usable.max(by: { $0.area < $1.area })
    }

    guard let frontmost = usable.first else {
        return hinted
    }

    // Prefer frontmost overlay only when it's clearly an overlay ON TOP
    // of the hinted window (fully contained within hinted bounds).
    // A small popup that merely intersects the main window should not
    // override the title-matched main window.
    if frontmost.windowID != hinted.windowID,
       hinted.bounds.contains(frontmost.bounds)
    {
        return frontmost
    }

    return hinted
}

// MARK: - Screen capture (full display)

public struct ScreenSnapshot {
    public let displayID: CGDirectDisplayID
    public let displayBounds: CGRect
    public let screenshotPNGData: Data?
    public let screenshotPixelSize: CGSize?
    public let menubarHeight: CGFloat
    public let visibleWindows: [VisibleWindowInfo]
    public let offscreenApps: [OffscreenAppInfo]
}

public struct VisibleWindowInfo {
    public let appName: String
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let bounds: CGRect
    public let layer: Int
}

public struct OffscreenAppInfo {
    public let appName: String
    public let bundleIdentifier: String?
    public let state: String
}

func shouldExcludeFromScreenCapture(
    ownerPID: pid_t,
    currentPID: pid_t = getpid(),
    trustedActivityPID: pid_t?
) -> Bool {
    ownerPID == currentPID || ownerPID == trustedActivityPID
}

func captureExclusionIsSafe(
    ownApplicationCount: Int,
    ownWindowCount: Int,
    activityHUDRunning: Bool
) -> Bool {
    if activityHUDRunning {
        return ownApplicationCount > 0
    }
    return ownApplicationCount > 0 || ownWindowCount > 0 || !activityHUDRunning
}

public enum ScreenCapture {
    public static func captureMainScreen() throws -> ScreenSnapshot {
        let displayID = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(displayID)

        // Screenshot via ScreenCaptureKit
        let image = captureMainDisplay(displayBounds: displayBounds)
        let pngData = image.flatMap { boundedScreenshotPNGData(for: $0) }
        let pixelSize: CGSize? = pngData.flatMap { data in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
                  let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
                  w > 0, h > 0
            else { return nil }
            return CGSize(width: w, height: h)
        }

        // Menubar height (standard 24pt on all macOS displays)
        let menubarHeight: CGFloat = 24

        // Visible windows from CGWindowList
        let visibleWindows = onScreenWindows()

        // Offscreen apps: running regular apps not represented in visible windows
        let visiblePIDs = Set(visibleWindows.map { $0.pid })
        let offscreenApps = offscreenRunningApps(excludingPIDs: visiblePIDs)

        return ScreenSnapshot(
            displayID: displayID,
            displayBounds: displayBounds,
            screenshotPNGData: pngData,
            screenshotPixelSize: pixelSize,
            menubarHeight: menubarHeight,
            visibleWindows: visibleWindows.map { entry in
                VisibleWindowInfo(
                    appName: entry.appName,
                    bundleIdentifier: entry.bundleIdentifier,
                    windowTitle: entry.windowTitle,
                    bounds: entry.bounds,
                    layer: entry.layer
                )
            },
            offscreenApps: offscreenApps
        )
    }

    private static func captureMainDisplay(displayBounds: CGRect) -> CGImage? {
        try? BlockingAsyncBridge.run(timeout: screenshotCaptureTimeout) {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first
            else { return nil }

            let trustedActivityPID = ActivitySocketClient.trustedListenerPID()
            let ownApplications = content.applications.filter {
                shouldExcludeFromScreenCapture(
                    ownerPID: $0.processID,
                    trustedActivityPID: trustedActivityPID
                )
            }
            let filter: SCContentFilter
            if ownApplications.isEmpty {
                let ownWindows = content.windows.filter {
                    guard let ownerPID = $0.owningApplication?.processID else { return false }
                    return shouldExcludeFromScreenCapture(
                        ownerPID: ownerPID,
                        trustedActivityPID: trustedActivityPID
                    )
                }
                // If the activity HUD helper is alive but ScreenCaptureKit
                // cannot identify any of its app/windows, do not capture with
                // an empty exclusion list. Returning nil preserves AX state
                // while failing closed for pixels.
                guard captureExclusionIsSafe(
                    ownApplicationCount: ownApplications.count,
                    ownWindowCount: ownWindows.count,
                    activityHUDRunning: trustedActivityPID != nil
                ) else {
                    return nil
                }
                filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            } else {
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: ownApplications,
                    exceptingWindows: []
                )
            }
            let config = SCStreamConfiguration()
            let scaleFactor = NSScreen.main?.backingScaleFactor ?? 1
            config.width = max(1, Int(ceil(displayBounds.width * scaleFactor)))
            config.height = max(1, Int(ceil(displayBounds.height * scaleFactor)))
            config.showsCursor = true
            config.scalesToFit = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    private struct OnScreenWindowEntry {
        let appName: String
        let bundleIdentifier: String?
        let pid: pid_t
        let windowTitle: String?
        let bounds: CGRect
        let layer: Int
    }

    private static func onScreenWindows() -> [OnScreenWindowEntry] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        // Build PID → bundle ID map from running apps
        let pidToBundleID: [pid_t: String] = NSWorkspace.shared.runningApplications
            .reduce(into: [:]) { result, app in
                if let bid = app.bundleIdentifier {
                    result[app.processIdentifier] = bid
                }
            }
        let trustedActivityPID = ActivitySocketClient.trustedListenerPID()

        return infoList.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 1, bounds.height > 1
            else { return nil }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? "pid-\(pid)"
            let title = info[kCGWindowName as String] as? String

            let bundleIdentifier = pidToBundleID[pid]
            guard !shouldExcludeFromScreenCapture(
                ownerPID: pid,
                trustedActivityPID: trustedActivityPID
            ) else {
                return nil
            }

            return OnScreenWindowEntry(
                appName: ownerName,
                bundleIdentifier: bundleIdentifier,
                pid: pid,
                windowTitle: title,
                bounds: bounds,
                layer: layer
            )
        }
    }

    private static func offscreenRunningApps(excludingPIDs visiblePIDs: Set<pid_t>) -> [OffscreenAppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular
                    && !app.isTerminated
                    && !visiblePIDs.contains(app.processIdentifier)
                    && !AppSafetyPolicy.isBlocked(bundleIdentifier: app.bundleIdentifier)
            }
            .map { app in
                let state: String = app.isHidden ? "hidden" : "minimized"
                return OffscreenAppInfo(
                    appName: AppDiscovery.appName(app),
                    bundleIdentifier: app.bundleIdentifier,
                    state: state
                )
            }
    }
}

// MARK: - Screenshot encoding

func boundedScreenshotPNGData(
    for image: CGImage,
    maxBytes: Int = screenshotResultMaxPNGBytes,
    maxDimension: CGFloat = screenshotResultMaxDimension,
    minScale: CGFloat = screenshotResultMinScale
) -> Data? {
    guard image.width > 0, image.height > 0, maxBytes > 0 else { return nil }

    let original = pngData(for: image)
    let largestDimension = CGFloat(max(image.width, image.height))
    var scale = min(1, maxDimension / largestDimension)

    if scale >= 1, let original, original.count <= maxBytes {
        return original
    }

    var best = original
    while scale >= minScale {
        guard let resized = resizedCGImage(image, scale: scale),
              let data = pngData(for: resized)
        else {
            break
        }

        best = data
        if data.count <= maxBytes {
            return data
        }

        scale *= 0.85
    }

    return best
}

private func pngData(for image: CGImage) -> Data? {
    let bitmap = NSBitmapImageRep(cgImage: image)
    return bitmap.representation(using: .png, properties: [:])
}

private func resizedCGImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return nil
    }

    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

// MARK: - Async bridge (ScreenCaptureKit)

private final class AsyncResultBox<T>: @unchecked Sendable {
    nonisolated(unsafe) var result: Result<T, Error>?
}

private enum BlockingAsyncBridge {
    static func run<T>(timeout: TimeInterval? = nil, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = AsyncResultBox<T>()

        let task = Task.detached {
            do {
                resultBox.result = .success(try await operation())
            } catch {
                resultBox.result = .failure(error)
            }
            semaphore.signal()
        }

        guard waitForSignal(semaphore, timeout: timeout) else {
            task.cancel()
            throw ComputerUseError.message("ScreenCaptureKit screenshot task timed out after \(timeout ?? 0) seconds.")
        }

        return try resultBox.result?.get() ?? {
            throw ComputerUseError.message("ScreenCaptureKit screenshot task finished without producing a result.")
        }()
    }

    private static func waitForSignal(_ semaphore: DispatchSemaphore, timeout: TimeInterval?) -> Bool {
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }

        if Thread.isMainThread {
            while semaphore.wait(timeout: .now()) == .timedOut {
                if let deadline, Date() >= deadline {
                    return false
                }
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            return true
        }

        if let timeout {
            return semaphore.wait(timeout: .now() + timeout) == .success
        }

        semaphore.wait()
        return true
    }
}

// MARK: - AX private toggles

private func enableBestEffortAccessibilityModes(_ appElement: AXUIElement) {
    _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
}

// MARK: - Tree walking

private struct TreeWalkContext {
    let windowBounds: CGRect?
    let focusedElement: AXUIElement?
}

private struct AccessibilityTreeWalker {
    let context: TreeWalkContext
    var nextIndex = 0
    var lines: [String] = []
    var records: [Int: ElementRecord] = [:]
    var focusedSummary: String?

    mutating func visit(
        _ root: AXUIElement,
        depth: Int = 0,
        ancestors: [AXUIElement] = [],
        parentTitle: String? = nil,
        stablePath: [String] = [],
        siblingOrdinal: Int = 0
    ) {
        guard shouldContinueRendering(nextIndex: nextIndex, depth: depth) else { return }
        guard !ancestors.contains(where: { CFEqual($0, root) }) else { return }
        let nextAncestors = ancestors + [root]

        let role = stringValue(of: root, attribute: kAXRoleAttribute) ?? "AXUnknown"
        let rawTitle = stringValue(of: root, attribute: kAXTitleAttribute)
        let label = stringValue(of: root, attribute: kAXDescriptionAttribute)
        let axIdentifier = displayIdentifier(stringValue(of: root, attribute: kAXIdentifierAttribute))
        let value = sanitizedValue(of: root, role: role, labelParts: [rawTitle, label, axIdentifier])
        let traits = summarizeTraits(of: root)
        let actions = copyActions(root) ?? []
        let prettyActions = meaningfulActions(actions, role: role)
        let localFrame = resolveLocalFrame(of: root, windowBounds: context.windowBounds)
        let rowTexts = role == kAXRowRole as String ? flattenedRowTexts(of: root) : []
        let childElements = children(of: root)

        let title = preferredDisplayTitle(
            for: root,
            role: role,
            label: label,
            identifier: axIdentifier,
            explicitValue: value,
            rowTexts: rowTexts
        )
        let linkText = role == "AXLink" ? markdownLinkText(for: root, title: title, label: label, value: value) : nil
        let displayTitle = linkText ?? title
        let stableSegment = stableIdentitySegment(
            role: role,
            identifier: axIdentifier,
            displayTitle: displayTitle,
            label: label,
            actions: prettyActions,
            siblingOrdinal: siblingOrdinal
        )
        let currentStablePath = stablePath + [stableSegment]
        let stableKey = currentStablePath.joined(separator: "/")

        // Skip AXStaticText whose value/title just duplicates the parent's
        // already-emitted title — this is very common and wastes tokens.
        if role == kAXStaticTextRole as String,
           let parentTitle,
           childElements.isEmpty,
           prettyActions.isEmpty
        {
            let text = value ?? displayTitle
            if let text, text == parentTitle {
                return
            }
        }

        let webAreaDepth = webAreaDepth(role: role, ancestors: ancestors)
        let hidesChildren = shouldSuppressChildren(role: role, title: displayTitle)

        if shouldElideNode(
            role: role,
            title: displayTitle,
            label: label,
            value: value,
            identifier: axIdentifier,
            traits: traits,
            actions: prettyActions,
            childCount: childElements.count,
            webAreaDepth: webAreaDepth
        ) {
            for (childOrdinal, child) in childElements.enumerated() {
                visit(
                    child,
                    depth: depth,
                    ancestors: nextAncestors,
                    parentTitle: parentTitle,
                    stablePath: stablePath,
                    siblingOrdinal: childOrdinal
                )
            }
            return
        }

        let index = nextIndex
        nextIndex += 1

        // Strip "settable"+"string" traits from non-actionable AXStaticText —
        // nearly every text label is technically settable but that information
        // is noise for the LLM.
        let emittedTraits: [String]
        if role == kAXStaticTextRole as String, prettyActions.isEmpty,
           traits == ["settable", "string"]
        {
            emittedTraits = []
        } else {
            emittedTraits = traits
        }

        let traitsSegment = emittedTraits.isEmpty ? "" : " traits=(\(emittedTraits.joined(separator: ", ")))"
        let quotedTitle = displayTitle.map { quoted($0) } ?? ""
        let titleSegment = quotedTitle.isEmpty ? "" : " \(quotedTitle)"
        let valueSegment = value.map { formattedValueSnippet(element: root, role: role, title: displayTitle, value: $0) } ?? ""
        let identifierSegment = axIdentifier.map { " id=\($0)" } ?? ""
        let actionsSegment = prettyActions.isEmpty ? "" : " actions=[\(prettyActions.joined(separator: ", "))]"

        let lineBody = "[\(index)] \(role)\(traitsSegment)\(titleSegment)\(valueSegment)\(identifierSegment)\(actionsSegment)"
        let indent = String(repeating: "  ", count: depth)
        lines.append("\(indent)\(lineBody)")

        let record = ElementRecord(
            index: index,
            identifier: axIdentifier,
            element: root,
            localFrame: localFrame,
            rawActions: actions,
            prettyActions: prettyActions,
            displayText: displayTitle ?? label ?? value,
            role: role,
            stableKey: stableKey
        )
        records[index] = record

        if let focusedElement = context.focusedElement, CFEqual(focusedElement, root) {
            focusedSummary = lineBody
        }

        if role == kAXRowRole as String, boolValue(of: root, attribute: kAXSelectedAttribute) != true {
            for text in Array(rowTexts.dropFirst()) {
                lines.append("\(indent)  \(text)")
            }
            return
        }

        if hidesChildren {
            return
        }

        for (childOrdinal, child) in childElements.enumerated() {
            visit(
                child,
                depth: depth + 1,
                ancestors: nextAncestors,
                parentTitle: displayTitle,
                stablePath: currentStablePath,
                siblingOrdinal: childOrdinal
            )
        }
    }
}

private func stableIdentitySegment(
    role: String,
    identifier: String?,
    displayTitle: String?,
    label: String?,
    actions: [String],
    siblingOrdinal: Int
) -> String {
    let actionKey = actions.sorted().joined(separator: ",")
    if let identifier, !identifier.isEmpty {
        return "id|\(role)|\(identifier)"
    }
    let textSource = stableTextSource(role: role, displayTitle: displayTitle, label: label)
    let text = AXSnapshotDiff.normalize(textSource ?? "")
    return "text|\(role)|\(text)|\(actionKey)|\(siblingOrdinal)"
}

private func stableTextSource(role: String, displayTitle: String?, label: String?) -> String? {
    // Window titles are mutable presentation state (for example an "Edited"
    // suffix), not window identity. The window instance is scoped by the
    // snapshot bucket's PID/window ID, so including its title here would churn
    // the stable path of every descendant on an ordinary title update.
    if role == kAXWindowRole as String {
        return nil
    }
    if role == kAXTextFieldRole as String
        || role == "AXTextArea"
        || role == "AXTextView"
        || role == kAXComboBoxRole as String
        || role == "AXSearchField" {
        return label
    }
    return displayTitle ?? label
}

func shouldContinueRendering(nextIndex: Int, depth: Int) -> Bool {
    nextIndex < accessibilityTreeMaxNodeCount && depth < accessibilityTreeMaxDepth
}

// MARK: - Child traversal

private func children(of element: AXUIElement) -> [AXUIElement] {
    let role = stringValue(of: element, attribute: kAXRoleAttribute)
    let rows = copyArray(element, attribute: kAXRowsAttribute) ?? []
    let visibleChildren = copyArray(element, attribute: axVisibleChildrenAttribute) ?? []
    let attributes = childTraversalAttributes(role: role, hasRows: !rows.isEmpty, hasVisibleChildren: !visibleChildren.isEmpty)
    var children: [AXUIElement] = []

    for attribute in attributes {
        let sourceValues: [AXUIElement]
        if attribute == kAXRowsAttribute {
            sourceValues = rows
        } else if attribute == axVisibleChildrenAttribute {
            sourceValues = visibleChildren
        } else {
            sourceValues = copyArray(element, attribute: attribute) ?? []
        }

        let values = attribute == kAXRowsAttribute ? visibleRows(in: sourceValues, parent: element) : sourceValues

        for child in values {
            if shouldSkipChild(child, of: element) { continue }
            if !children.contains(where: { CFEqual($0, child) }) {
                children.append(child)
            }
        }
    }

    return children
}

func childTraversalAttributes(role: String?, hasRows: Bool, hasVisibleChildren: Bool) -> [String] {
    var attributes: [String] = []
    if !(hasRows && usesRowsAsPrimaryRole(role)) && !(hasVisibleChildren && usesVisibleChildrenAsPrimaryRole(role)) {
        attributes.append(kAXChildrenAttribute)
    }
    attributes.append(kAXRowsAttribute)
    attributes.append(axContentsAttribute)
    attributes.append(axVisibleChildrenAttribute)
    return attributes
}

private func usesRowsAsPrimaryRole(_ role: String?) -> Bool {
    [
        kAXOutlineRole as String,
        kAXListRole as String,
        kAXTableRole as String,
        "AXBrowser",
    ].contains(role)
}

private func usesVisibleChildrenAsPrimaryRole(_ role: String?) -> Bool {
    role == kAXListRole as String
}

private func shouldSkipChild(_ child: AXUIElement, of parent: AXUIElement) -> Bool {
    let parentRole = stringValue(of: parent, attribute: kAXRoleAttribute)
    guard parentRole == kAXMenuBarRole as String else { return false }
    return stringValue(of: child, attribute: kAXTitleAttribute) == "Apple"
}

// MARK: - Elision / suppression

func shouldElideNode(
    role: String,
    title: String?,
    label: String?,
    value: String?,
    identifier: String?,
    traits: [String],
    actions: [String],
    childCount: Int,
    webAreaDepth: Int?
) -> Bool {
    // Always elide purely decorative/structural roles that carry no
    // user-actionable information — their children (if any) are promoted.
    let decorativeRoles: Set<String> = [
        kAXSplitterRole as String,
        kAXRulerRole as String,
        kAXGrowAreaRole as String,
        kAXMatteRole as String,
        "AXLayoutArea",
        "AXLayoutItem",
    ]
    if decorativeRoles.contains(role) {
        return true
    }

    let genericRoles = [kAXGroupRole as String, kAXUnknownRole as String]
    guard genericRoles.contains(role) else { return false }

    if shouldPreserveWebAreaGenericContainer(childCount: childCount, webAreaDepth: webAreaDepth) {
        return false
    }

    if childCount == 1,
       title == nil,
       label == nil,
       value == nil,
       identifier == nil,
       actions.isEmpty,
       traitsAreNonDescriptiveWrapperTraits(traits)
    {
        return true
    }

    return title == nil
        && label == nil
        && value == nil
        && identifier == nil
        && traits.isEmpty
        && actions.isEmpty
}

func shouldPreserveWebAreaGenericContainer(childCount: Int, webAreaDepth: Int?) -> Bool {
    guard childCount > 0, webAreaDepth != nil else { return false }
    return childCount > 1
}

private func traitsAreNonDescriptiveWrapperTraits(_ traits: [String]) -> Bool {
    traits.isEmpty || traits == ["settable", "string"]
}

private func shouldSuppressChildren(role: String, title: String?) -> Bool {
    if role == kAXMenuBarItemRole as String { return true }
    if role == "AXLink", title?.hasPrefix("[") == true { return true }
    return false
}

private func webAreaDepth(role: String, ancestors: [AXUIElement]) -> Int? {
    if role == axWebAreaRole { return 0 }
    guard let webAreaIndex = ancestors.firstIndex(where: { stringValue(of: $0, attribute: kAXRoleAttribute) == axWebAreaRole }) else {
        return nil
    }
    return ancestors.count - webAreaIndex
}

// MARK: - Traits / values / frames

private func summarizeTraits(of element: AXUIElement) -> [String] {
    var values: [String] = []

    if boolValue(of: element, attribute: kAXSelectedAttribute) == true {
        values.append("selected")
    }
    if boolValue(of: element, attribute: kAXExpandedAttribute) == true {
        values.append("expanded")
    }
    if boolValue(of: element, attribute: kAXEnabledAttribute) == false {
        values.append("disabled")
    }
    if isSettable(of: element, attribute: kAXValueAttribute) {
        values.append("settable")
    }
    if let valueType = valueTypeTrait(of: element) {
        values.append(valueType)
    }
    return values
}

private func valueTypeTrait(of element: AXUIElement) -> String? {
    guard isSettable(of: element, attribute: kAXValueAttribute) else { return nil }
    guard let value = attributeValue(of: element, attribute: kAXValueAttribute) else { return nil }

    if CFGetTypeID(value) == CFStringGetTypeID() {
        return "string"
    }
    if value is NSNumber {
        if numericValueRepresentsBoolean(for: element, value: value) {
            return "boolean"
        }
        return "float"
    }
    return nil
}

private func formattedValueSnippet(element: AXUIElement, role: String, title: String?, value: String) -> String {
    let roleText = roleDescription(of: element, role: role, subrole: stringValue(of: element, attribute: kAXSubroleAttribute))
    if roleText == "search text field", title == value { return "" }
    if title == nil, role == kAXStaticTextRole as String {
        return " value=\(value)"
    }
    if ["scroll bar", "value indicator"].contains(roleText) {
        return " value=\(value)"
    }
    if roleText == "text entry area" {
        return " value=\(value)"
    }
    return " value=\(value)"
}

private func resolveLocalFrame(of element: AXUIElement, windowBounds: CGRect?) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    let positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
    let sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
    guard positionError == .success, sizeError == .success, let positionValue, let sizeValue else {
        return nil
    }

    let positionAXValue = positionValue as! AXValue
    let sizeAXValue = sizeValue as! AXValue
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionAXValue, .cgPoint, &position), AXValueGetValue(sizeAXValue, .cgSize, &size) else {
        return nil
    }

    let frame = CGRect(origin: position, size: size)
    guard let windowBounds else {
        return frame
    }
    return windowRelativeFrame(elementFrame: frame, windowBounds: windowBounds)
}

func windowRelativeFrame(elementFrame: CGRect, windowBounds: CGRect) -> CGRect {
    CGRect(
        x: elementFrame.minX - windowBounds.minX,
        y: elementFrame.minY - windowBounds.minY,
        width: elementFrame.width,
        height: elementFrame.height
    )
}

// MARK: - AX attribute helpers

private func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success, let value else { return nil }
    return (value as! AXUIElement)
}

private func copyArray(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success, let value else { return nil }
    return value as? [AXUIElement]
}

private func copyActions(_ element: AXUIElement) -> [String]? {
    var actions: CFArray?
    let error = AXUIElementCopyActionNames(element, &actions)
    guard error == .success else { return nil }
    return actions as? [String]
}

private func attributeValue(of element: AXUIElement, attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else { return nil }
    return value
}

private func stringValue(of element: AXUIElement, attribute: String) -> String? {
    guard let value = attributeValue(of: element, attribute: attribute) else { return nil }

    if CFGetTypeID(value) == CFStringGetTypeID() {
        guard let string = value as? String else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
    }
    return nil
}

private func copySelectedText(_ element: AXUIElement) -> String? {
    guard let value = stringValue(of: element, attribute: kAXSelectedTextAttribute) else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let role = stringValue(of: element, attribute: kAXRoleAttribute)
    let title = stringValue(of: element, attribute: kAXTitleAttribute)
    let label = stringValue(of: element, attribute: kAXDescriptionAttribute)
    let identifier = displayIdentifier(stringValue(of: element, attribute: kAXIdentifierAttribute))
    return redactedAXValue(trimmed, role: role, labelParts: [title, label, identifier])
}

private func boolValue(of element: AXUIElement, attribute: String) -> Bool? {
    guard let value = attributeValue(of: element, attribute: attribute) else { return nil }
    return value as? Bool
}

private func pid(of element: AXUIElement) -> pid_t {
    var processIdentifier: pid_t = 0
    AXUIElementGetPid(element, &processIdentifier)
    return processIdentifier
}

private func isSettable(of element: AXUIElement, attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
    return error == .success && settable.boolValue
}

private func sanitizedValue(of element: AXUIElement, role: String? = nil, labelParts: [String?] = []) -> String? {
    if let string = stringValue(of: element, attribute: kAXValueAttribute) {
        let sanitized = sanitizeText(string)
        guard !sanitized.isEmpty else { return nil }
        return redactedAXValue(sanitized, role: role, labelParts: labelParts)
    }

    guard let value = attributeValue(of: element, attribute: kAXValueAttribute) else { return nil }

    if let number = value as? NSNumber {
        if numericValueRepresentsBoolean(for: element, value: value) {
            return number.boolValue ? "on" : "off"
        }
        return number.stringValue
    }
    return nil
}

private func numericValueRepresentsBoolean(for element: AXUIElement, value: CFTypeRef) -> Bool {
    guard let number = value as? NSNumber else { return false }
    guard number == 0 || number == 1 else { return false }
    let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? ""
    let subrole = stringValue(of: element, attribute: kAXSubroleAttribute)
    let roleText = roleDescription(of: element, role: role, subrole: subrole)
    return roleText == "tab"
        || role == kAXCheckBoxRole as String
        || role == kAXRadioButtonRole as String
}

// MARK: - Display helpers

private func preferredDisplayTitle(
    for element: AXUIElement,
    role: String,
    label: String?,
    identifier: String?,
    explicitValue: String?,
    rowTexts: [String]
) -> String? {
    if let title = stringValue(of: element, attribute: kAXTitleAttribute), !title.isEmpty {
        return sanitizeText(title)
    }

    if role == kAXRowRole as String {
        return rowTexts.first
    }

    if (role == kAXOutlineRole as String || role == kAXListRole as String), let identifier {
        return identifier
    }

    if (role == kAXButtonRole as String || role == kAXPopUpButtonRole as String), let label, !label.isEmpty {
        return sanitizeText(label)
    }

    if role == kAXImageRole as String, let label, !label.isEmpty {
        return sanitizeText(label)
    }

    if (role == kAXGroupRole as String || role == kAXUnknownRole as String || role == axWebAreaRole),
       let label,
       !label.isEmpty
    {
        return sanitizeText(label)
    }

    guard roleDescription(of: element, role: role, subrole: stringValue(of: element, attribute: kAXSubroleAttribute)) == "search text field" else {
        return nil
    }

    return explicitValue
}

private func markdownLinkText(for element: AXUIElement, title: String?, label: String?, value: String?) -> String? {
    guard let url = urlValue(of: element, attribute: kAXURLAttribute), !url.isEmpty else {
        return nil
    }

    let text = [label, title, value]
        .compactMap { candidate -> String? in
            guard let candidate else { return nil }
            let sanitized = sanitizeText(candidate)
            return sanitized.isEmpty ? nil : sanitized
        }
        .first

    guard let text else { return nil }
    return "[\(markdownEscapedLinkText(text))](\(url))"
}

private func markdownEscapedLinkText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
}

private func roleDescription(of element: AXUIElement, role: String, subrole: String?) -> String {
    if role == kAXRowRole as String { return "row" }
    if role == kAXGroupRole as String { return "container" }
    if role == kAXMenuBarItemRole as String { return "" }
    if role == "AXLink" { return "link" }
    if role == axWebAreaRole {
        return stringValue(of: element, attribute: kAXRoleDescriptionAttribute) ?? "HTML 内容"
    }

    if let roleDescription = stringValue(of: element, attribute: kAXRoleDescriptionAttribute), !roleDescription.isEmpty {
        return roleDescription.lowercased()
    }

    if let subrole, subrole == kAXStandardWindowSubrole as String {
        return "standard window"
    }

    return humanizeAXToken(role)
}

private func humanizeAXToken(_ value: String) -> String {
    let stripped = value.hasPrefix("AX") ? String(value.dropFirst(2)) : value
    return splitCamelCase(stripped).lowercased()
}

func meaningfulActions(_ values: [String], role: String) -> [String] {
    values
        .filter {
            var ignored = [
                kAXPressAction as String,
                "AXShowDefaultUI",
                "AXShowAlternateUI",
                "AXShowMenu",
                "AXConfirm",
                "AXScrollToVisible",
            ]

            if [
                kAXMenuBarRole as String,
                kAXMenuBarItemRole as String,
                kAXMenuRole as String,
                kAXMenuItemRole as String,
            ].contains(role) {
                ignored.append(contentsOf: ["AXCancel", "AXPick"])
            }

            return !ignored.contains($0)
        }
        .filter {
            guard role == kAXScrollAreaRole as String else { return true }
            if values.contains("AXScrollUpByPage") || values.contains("AXScrollDownByPage") {
                return $0 != "AXScrollLeftByPage" && $0 != "AXScrollRightByPage"
            }
            return true
        }
        .map(prettyActionName(_:))
}

private func prettyActionName(_ value: String) -> String {
    if value == "AXZoomWindow" {
        return "zoom the window"
    }
    let stripped = value.hasPrefix("AX") ? String(value.dropFirst(2)) : value
    let withoutPage = stripped.replacingOccurrences(of: "ByPage", with: "")
    return splitCamelCase(withoutPage)
}

private func splitCamelCase(_ value: String) -> String {
    var result = ""
    for character in value {
        if character.isUppercase, !result.isEmpty {
            result.append(" ")
        }
        result.append(character)
    }
    return result
}

private func sanitizeText(_ value: String) -> String {
    let collapsed = value
        .replacingOccurrences(of: "\n", with: "\\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    if collapsed.count > 160 {
        return String(collapsed.prefix(160)) + "..."
    }
    return collapsed
}

private func flattenedRowTexts(of element: AXUIElement) -> [String] {
    let cells = copyArray(element, attribute: kAXChildrenAttribute) ?? []
    let texts = cells
        .flatMap { descendantTexts(of: $0) }
        .map(sanitizeText)
        .filter { !$0.isEmpty }

    var unique: [String] = []
    var seen: Set<String> = []
    for text in texts {
        if seen.insert(text).inserted {
            unique.append(text)
        }
    }
    return unique
}

private func descendantTexts(of element: AXUIElement, depth: Int = 0) -> [String] {
    guard depth < 4 else { return [] }

    var values: [String] = []
    let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? ""
    if role == kAXStaticTextRole as String || role == kAXTextFieldRole as String {
        let title = stringValue(of: element, attribute: kAXTitleAttribute)
        let label = stringValue(of: element, attribute: kAXDescriptionAttribute)
        let identifier = displayIdentifier(stringValue(of: element, attribute: kAXIdentifierAttribute))
        if let value = sanitizedValue(of: element, role: role, labelParts: [title, label, identifier]) {
            values.append(value)
        } else if let title {
            values.append(sanitizeText(title))
        }
    }

    for child in copyArray(element, attribute: kAXChildrenAttribute) ?? [] {
        values.append(contentsOf: descendantTexts(of: child, depth: depth + 1))
    }
    return values
}

private func visibleRows(in rows: [AXUIElement], parent: AXUIElement) -> [AXUIElement] {
    guard let parentFrame = resolveLocalFrame(of: parent, windowBounds: nil) else {
        return Array(rows.prefix(20))
    }

    let visible = rows.filter { row in
        guard let rowFrame = resolveLocalFrame(of: row, windowBounds: nil) else { return false }
        return rowFrame.intersects(parentFrame)
    }

    if visible.isEmpty {
        return Array(rows.prefix(20))
    }
    return Array(visible.prefix(20))
}

private func displayIdentifier(_ value: String?) -> String? {
    guard let value, !value.isEmpty, !value.hasPrefix("_NS:") else { return nil }
    return value
}

private func displayWindowTitle(_ value: String?, appName: String) -> String {
    guard let value, !value.isEmpty else { return appName }
    if value.hasPrefix("\(appName) –") { return appName }
    return value
}

private func quoted(_ value: String) -> String {
    "\"\(value)\""
}

private extension CGRect {
    var renderedLocalFrame: String {
        "x=\(Int(origin.x)), y=\(Int(origin.y)), w=\(Int(width)), h=\(Int(height))"
    }
}

private func urlValue(of element: AXUIElement, attribute: String) -> String? {
    guard let value = attributeValue(of: element, attribute: attribute) else { return nil }

    if CFGetTypeID(value) == CFStringGetTypeID(), let string = value as? String {
        let sanitized = sanitizeText(string)
        return sanitized.isEmpty ? nil : sanitized
    }

    if CFGetTypeID(value) == CFURLGetTypeID(), let url = value as? URL {
        let sanitized = sanitizeText(url.absoluteString)
        return sanitized.isEmpty ? nil : sanitized
    }
    return nil
}
