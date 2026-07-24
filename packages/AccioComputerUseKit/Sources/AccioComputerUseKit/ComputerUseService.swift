import AppKit
import ApplicationServices
import Foundation
import ImageIO

enum TextMutationIntent {
    case typeText
    case setValue
}

enum TextMutationPlan: String {
    case keyboardPostToPID = "keyboard_post_to_pid"
    case keyboardHID = "keyboard_hid"
    case axValueWrite = "ax_value_write"
}

func textMutationPlan(intent: TextMutationIntent, useActivation: Bool) -> TextMutationPlan {
    switch intent {
    case .typeText:
        return useActivation ? .keyboardHID : .keyboardPostToPID
    case .setValue:
        return .axValueWrite
    }
}

// MARK: - Service

public final class ComputerUseService {
    private let maxScrollPages = 20.0
    let stableRefsEnabled: Bool
    let actionDiffEnabled: Bool
    var snapshotsByApp: [String: AppSnapshot] = [:]
    var snapshotTimestamps: [String: Date] = [:]
    var axDiffStatesByBucket: [String: AXDiffState] = [:]
    /// Monotonic across every window lineage served by this daemon instance.
    /// A ref retired in one bucket must never be reassigned in another bucket.
    var maxStableRefCounter = 0
    let snapshotMaxAge: TimeInterval = 10

    /// Tracks consecutive actions that produced no detectable change, per app.
    /// Reset to 0 whenever an action produces confirmed or structureOnly change.
    var consecutiveNoChange: [String: Int] = [:]

    public init(stableRefsEnabled: Bool = true, actionDiffEnabled: Bool = true) {
        self.stableRefsEnabled = stableRefsEnabled
        self.actionDiffEnabled = actionDiffEnabled
    }

    // MARK: - Public API

    public func listApps() -> ToolCallResult {
        guard !AutomationPauseStore.shared.isPaused else {
            return ToolCallResult.text(AutomationPolicy.pausedMessage, isError: true)
        }
        return ToolCallResult.text(
            AppDiscovery.listCatalog()
                .map(\.renderedLine)
                .joined(separator: "\n")
        )
    }

    public func getAppState(app: String) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "get_app_state")
        return try preservingFrontmostApp {
            snapshotResult(for: try refreshSnapshot(for: app, readOnly: true), style: .fullState)
        }
    }

    public func getScreenState() throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "get_screen_state")
        let screen = try ScreenCapture.captureMainScreen()
        var lines: [String] = []

        let dims = screen.screenshotPixelSize.map { "screenshot_size=\(Int($0.width))x\(Int($0.height))" } ?? ""
        lines.append(screenSummaryLine())
        lines.append("Screen: main display (\(Int(screen.displayBounds.width))x\(Int(screen.displayBounds.height)) pts), \(dims)")
        lines.append("")

        lines.append("Visible windows (front to back):")
        for w in screen.visibleWindows {
            let title = w.windowTitle.map { " \"\($0)\"" } ?? ""
            let bid = w.bundleIdentifier ?? ""
            let b = w.bounds
            lines.append("  \(w.appName) — \(bid)\(title) (\(Int(b.minX)), \(Int(b.minY)), \(Int(b.width)), \(Int(b.height)))")
        }

        if !screen.offscreenApps.isEmpty {
            lines.append("")
            lines.append("Hidden/minimized apps:")
            for a in screen.offscreenApps {
                lines.append("  \(a.appName) — \(a.bundleIdentifier ?? "") (\(a.state))")
            }
        }

        lines.append("")
        lines.append("Use get_app_state to inspect a specific app's UI elements.")

        var content: [ToolResultContentItem] = [.text(lines.joined(separator: "\n"))]
        if let png = screen.screenshotPNGData {
            content.append(.pngImage(png))
        }
        return ToolCallResult(content: content)
    }

    public func clickScreen(
        x: Double,
        y: Double,
        coordinateSpace: CoordinateSpace = .pixel,
        clickCount: Int,
        mouseButton: String
    ) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "click")
        let screen = try ScreenCapture.captureMainScreen()
        let inputPoint = CGPoint(x: x, y: y)
        let pixelPoint = convertToScreenPixels(inputPoint, coordinateSpace: coordinateSpace, screen: screen)
        let globalPoint = screenPixelToGlobalPoint(screen: screen, point: pixelPoint)
        let button = MouseButtonKind(rawValue: mouseButton.lowercased()) ?? .left
        let effectiveClickCount = max(clickCount, 1)

        guard screenPointTargetSafety(globalPoint) == .allowed else {
            throw ComputerUseError.permissionDenied("Accio could not verify that the screen coordinates target an allowed app.")
        }

        let cursorTarget = makeVisualCursorTarget(at: globalPoint, targetWindowID: nil, targetWindowLayer: nil)
        moveVisualCursor(to: cursorTarget)

        let snapInfo = try attemptSystemWideAXSnapClick(
            at: globalPoint,
            button: button,
            clickCount: effectiveClickCount
        )

        if snapInfo == nil {
            guard combinedScreenPointSafety(
                windowTarget: screenPointTargetSafety(globalPoint),
                accessibilityTarget: accessibilityScreenPointTargetSafety(globalPoint)
            ) == .allowed else {
                throw ComputerUseError.permissionDenied("The screen coordinate target changed before input delivery.")
            }
            try InputSimulation.clickAtScreenPoint(at: globalPoint, button: button, clickCount: effectiveClickCount)
        }

        pulseVisualCursor(at: cursorTarget, clickCount: effectiveClickCount, mouseButton: button)
        Thread.sleep(forTimeInterval: 0.15)

        let refreshed = try ScreenCapture.captureMainScreen()
        let clickVerb = effectiveClickCount > 1 ? "Double-clicked" : "Clicked"
        let buttonLabel = button == .left ? "" : " (\(button.rawValue) button)"
        let coordTag = coordinateSpaceTag(for: coordinateSpace, input: inputPoint, pixel: pixelPoint)
        var summary = "\(clickVerb) at screen coordinates (\(Int(pixelPoint.x)), \(Int(pixelPoint.y)))\(coordTag)\(buttonLabel)."
        if let snapInfo {
            summary += " AX-snapped to \(snapInfo)."
        }

        return screenStateResult(screen: refreshed, actionSummary: summary)
    }

    public func dragScreen(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        coordinateSpace: CoordinateSpace = .pixel
    ) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "drag")
        let screen = try ScreenCapture.captureMainScreen()
        let startPixel = convertToScreenPixels(CGPoint(x: fromX, y: fromY), coordinateSpace: coordinateSpace, screen: screen)
        let endPixel = convertToScreenPixels(CGPoint(x: toX, y: toY), coordinateSpace: coordinateSpace, screen: screen)
        let start = screenPixelToGlobalPoint(screen: screen, point: startPixel)
        let end = screenPixelToGlobalPoint(screen: screen, point: endPixel)

        guard screenPointTargetSafety(start) == .allowed,
              screenPointTargetSafety(end) == .allowed else {
            throw ComputerUseError.permissionDenied("Accio could not verify that the screen drag targets allowed apps.")
        }

        let startCursorTarget = makeVisualCursorTarget(at: start, targetWindowID: nil, targetWindowLayer: nil)
        moveVisualCursor(to: startCursorTarget)

        guard combinedScreenPointSafety(
            windowTarget: screenPointTargetSafety(start),
            accessibilityTarget: accessibilityScreenPointTargetSafety(start)
        ) == .allowed,
        combinedScreenPointSafety(
            windowTarget: screenPointTargetSafety(end),
            accessibilityTarget: accessibilityScreenPointTargetSafety(end)
        ) == .allowed else {
            throw ComputerUseError.permissionDenied("The screen drag target changed before input delivery.")
        }
        try InputSimulation.dragAtScreenPoint(from: start, to: end)

        let endCursorTarget = makeVisualCursorTarget(at: end, targetWindowID: nil, targetWindowLayer: nil)
        settleVisualCursor(at: endCursorTarget)
        Thread.sleep(forTimeInterval: 0.3)

        let refreshed = try ScreenCapture.captureMainScreen()
        let startTag = coordinateSpaceTag(for: coordinateSpace, input: CGPoint(x: fromX, y: fromY), pixel: startPixel)
        let summary = "Dragged from screen (\(Int(startPixel.x)), \(Int(startPixel.y)))\(startTag) to (\(Int(endPixel.x)), \(Int(endPixel.y)))."

        return screenStateResult(screen: refreshed, actionSummary: summary)
    }

    private func screenStateResult(screen: ScreenSnapshot, actionSummary: String? = nil) -> ToolCallResult {
        var lines: [String] = []

        if let actionSummary {
            lines.append(actionSummary)
            lines.append("")
        }

        let dims = screen.screenshotPixelSize.map { "screenshot_size=\(Int($0.width))x\(Int($0.height))" } ?? ""
        lines.append(screenSummaryLine())
        lines.append("Screen: main display (\(Int(screen.displayBounds.width))x\(Int(screen.displayBounds.height)) pts), \(dims)")
        lines.append("")

        lines.append("Visible windows (front to back):")
        for w in screen.visibleWindows {
            let title = w.windowTitle.map { " \"\($0)\"" } ?? ""
            let bid = w.bundleIdentifier ?? ""
            let b = w.bounds
            lines.append("  \(w.appName) — \(bid)\(title) (\(Int(b.minX)), \(Int(b.minY)), \(Int(b.width)), \(Int(b.height)))")
        }

        if !screen.offscreenApps.isEmpty {
            lines.append("")
            lines.append("Hidden/minimized apps:")
            for a in screen.offscreenApps {
                lines.append("  \(a.appName) — \(a.bundleIdentifier ?? "") (\(a.state))")
            }
        }

        var content: [ToolResultContentItem] = [.text(lines.joined(separator: "\n"))]
        if let png = screen.screenshotPNGData {
            content.append(.pngImage(png))
        }
        return ToolCallResult(content: content)
    }

    private func screenSummaryLine() -> String {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostReference = frontmost?.bundleIdentifier ?? frontmost?.localizedName ?? "unknown"
        let systemWide = AXUIElementCreateSystemWide()
        let focusedWindow = copyAXElement(systemWide, attribute: kAXFocusedWindowAttribute as String)
        let focusedRole = focusedWindow.flatMap { axStringValue(of: $0, attribute: kAXRoleAttribute as String) }
        let activeModal = focusedRole == "AXDialog" ? "focused" : "none"
        let activeSheet = focusedRole == kAXSheetRole as String ? "focused" : "none"
        let contextMenu = screenHasContextMenu(systemWide: systemWide) ? "present" : "none"
        return "[Screen] frontmost=\(frontmostReference) active_modal=\(activeModal) active_sheet=\(activeSheet) context_menu=\(contextMenu)"
    }

    private func screenHasContextMenu(systemWide: AXUIElement) -> Bool {
        guard let children = copyAXArray(systemWide, attribute: kAXChildrenAttribute as String) else {
            return false
        }
        return children.contains {
            axStringValue(of: $0, attribute: kAXRoleAttribute as String) == kAXMenuRole as String
        }
    }

    private func copyAXElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyAXArray(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private func axStringValue(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        return value as? String
    }

    public func click(
        app: String,
        stableRef: String? = nil,
        elementIndex: String?,
        elementText: String?,
        snapshotId: String? = nil,
        x: Double?,
        y: Double?,
        coordinateSpace: CoordinateSpace = .pixel,
        clickCount: Int,
        mouseButton: String
    ) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "click")
        return try preservingFrontmostApp {
            // Refresh before resolving the target so window geometry is live,
            // while still enforcing an explicit caller snapshot as a
            // fail-closed precondition.
            let snapshot = try snapshotAwareOfStaleness(for: app, snapshotId: snapshotId)
            try prepareForForegroundOperationIfNeeded(snapshot: snapshot, reason: .clickFallback)
            let button = MouseButtonKind(rawValue: mouseButton.lowercased()) ?? .left
            let effectiveClickCount = max(clickCount, 1)
            var actionSummary = ""
            var actionRoute = "unknown"
            let preState = ActionPreState(pid: snapshot.app.pid, fingerprint: structuralFingerprint(snapshot), snapshot: snapshot)

            if stableRef != nil || elementIndex != nil || elementText != nil {
                let record = try resolveElement(snapshot: snapshot, stableRef: stableRef, elementIndex: elementIndex, elementText: elementText)
                let elementRef = stableRef ?? elementIndex ?? elementText ?? "?"
                guard let localFrame = record.localFrame,
                      let targetPoint = try globalPoint(for: record, snapshot: snapshot) else {
                    throw ComputerUseError.stateUnavailable(
                        "Element '\(elementRef)' (index \(record.index)) has no clickable frame. " +
                        "It may be off-screen or hidden. Try scrolling it into view first."
                    )
                }

                let isMenuElement = [
                    kAXMenuBarRole as String,
                    kAXMenuBarItemRole as String,
                    kAXMenuRole as String,
                    kAXMenuItemRole as String,
                ].contains(record.role ?? "")

                if let wb = snapshot.windowBounds, !isMenuElement {
                    let visibleRect = CGRect(x: 0, y: 0, width: wb.width, height: wb.height)
                    if !visibleRect.intersects(localFrame) {
                        if let scrolledRecord = try autoScrollIntoView(
                            element: record.element,
                            elementText: record.displayText ?? record.identifier,
                            localFrame: localFrame,
                            visibleRect: visibleRect,
                            app: app,
                            snapshot: snapshot
                        ) {
                            guard let retryPoint = try globalPoint(for: scrolledRecord, snapshot: try currentSnapshot(for: app)) else {
                                throw ComputerUseError.stateUnavailable(
                                    "Element '\(elementRef)' was scrolled into view but still has no clickable frame."
                                )
                            }
                            let retrySnapshot = try currentSnapshot(for: app)
                            let retryCursorTarget = visualCursorTarget(for: scrolledRecord, snapshot: retrySnapshot)
                            moveVisualCursor(to: retryCursorTarget)

                            let handledAX = try performAXClickSequence(
                                on: scrolledRecord,
                                snapshot: retrySnapshot,
                                button: button,
                                clickCount: effectiveClickCount,
                                includeNearbyHitTesting: true,
                                allowActivationFallback: true
                            )
                            if !handledAX {
                                try performNonAXClickFallback(
                                    at: retryPoint,
                                    button: button,
                                    clickCount: effectiveClickCount,
                                    snapshot: retrySnapshot
                                )
                            }

                            let clickVerb = effectiveClickCount > 1 ? "Double-clicked" : "Clicked"
                            let buttonLabel = button == .left ? "" : " (\(button.rawValue) button)"
                            let afterSnapshot = try refreshSnapshot(for: app)
                            actionRoute = handledAX ? "ax_press" : "coordinate_fallback"
                            actionSummary = "\(clickVerb) \(elementSummary(for: scrolledRecord))\(buttonLabel) (auto-scrolled into view)."
                            actionSummary = ActionResultSummary.line(
                                tool: "click",
                                target: elementSummary(for: scrolledRecord),
                                route: actionRoute,
                                preState: preState,
                                postSnapshot: afterSnapshot
                            ) + "\n" + actionSummary
                            pulseVisualCursor(at: retryCursorTarget, clickCount: effectiveClickCount, mouseButton: button)
                            return actionObservationResult(before: snapshot, after: afterSnapshot, actionSummary: actionSummary)
                        }

                        throw ComputerUseError.stateUnavailable(
                            "Element '\(elementRef)' (index \(record.index)) is outside the visible window area " +
                            "(element at y=\(Int(localFrame.midY)), window height=\(Int(wb.height))). " +
                            "Auto-scroll failed. Scroll it into view manually, then retry the click."
                        )
                    }
                }

                let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
                moveVisualCursor(to: cursorTarget)

                let handledAX: Bool
                do {
                    handledAX = try performAXClickSequence(
                        on: record,
                        snapshot: snapshot,
                        button: button,
                        clickCount: effectiveClickCount,
                        includeNearbyHitTesting: true,
                        allowActivationFallback: true
                    )

                    if !handledAX {
                        try performNonAXClickFallback(
                            at: targetPoint,
                            button: button,
                            clickCount: effectiveClickCount,
                            snapshot: snapshot
                        )
                    }
                } catch {
                    settleVisualCursor(at: cursorTarget)
                    throw error
                }

                let clickVerb = effectiveClickCount > 1 ? "Double-clicked" : "Clicked"
                let buttonLabel = button == .left ? "" : " (\(button.rawValue) button)"
                if handledAX {
                    actionRoute = "ax_press"
                    actionSummary = "\(clickVerb) \(elementSummary(for: record))\(buttonLabel) via accessibility action."
                } else {
                    actionRoute = "coordinate_fallback"
                    actionSummary = "\(clickVerb) \(elementSummary(for: record))\(buttonLabel) at (\(Int(targetPoint.x)), \(Int(targetPoint.y))) via coordinate-based click."
                }
                pulseVisualCursor(at: cursorTarget, clickCount: effectiveClickCount, mouseButton: button)
            } else if let x, let y {
                let inputPoint = CGPoint(x: x, y: y)
                let pixelPoint = convertToSnapshotPixels(inputPoint, coordinateSpace: coordinateSpace, snapshot: snapshot)
                let windowPoint = screenshotPixelToWindowPointInSnapshot(snapshot: snapshot, point: pixelPoint)
                let targetPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: windowPoint)
                let cursorTarget = makeVisualCursorTarget(
                    at: targetPoint,
                    targetWindowID: snapshot.targetWindowID,
                    targetWindowLayer: snapshot.targetWindowLayer
                )
                moveVisualCursor(to: cursorTarget)

                do {
                    try performNonAXClickFallback(
                        at: targetPoint,
                        button: button,
                        clickCount: effectiveClickCount,
                        snapshot: snapshot
                    )
                } catch {
                    settleVisualCursor(at: cursorTarget)
                    throw error
                }

                let clickVerb = effectiveClickCount > 1 ? "Double-clicked" : "Clicked"
                let buttonLabel = button == .left ? "" : " (\(button.rawValue) button)"
                let coordTag = coordinateSpaceTag(for: coordinateSpace, input: inputPoint, pixel: pixelPoint)
                actionRoute = "coordinate_fallback"
                actionSummary = "\(clickVerb) at x=\(Int(pixelPoint.x)), y=\(Int(pixelPoint.y))\(coordTag)\(buttonLabel) via coordinate-based click."
                pulseVisualCursor(at: cursorTarget, clickCount: effectiveClickCount, mouseButton: button)
            } else {
                throw ComputerUseError.invalidArguments(
                    "click requires element_index, element_text (or element_label), or x/y coordinates. " +
                    "Example: {\"app\":\"...\",\"element_index\":\"3\"} or {\"app\":\"...\",\"element_text\":\"Save\"}"
                )
            }

            waitUntilSettled(pid: snapshot.app.pid, maxWait: 1.0)
            let afterSnapshot = try refreshSnapshot(for: app)
            let postFingerprint = structuralFingerprint(afterSnapshot)
            let appKey = app
            let resultLine = ActionResultSummary.line(
                tool: "click",
                target: stableRef ?? elementIndex ?? elementText,
                route: actionRoute,
                preState: preState,
                postSnapshot: afterSnapshot,
                consecutiveNoChange: consecutiveNoChangeCount(for: appKey)
            )
            // Determine change level for tracking
            let clickChanged = preState.structuralFingerprint != postFingerprint
                || preState.focusedElementValue != ActionPreState(pid: snapshot.app.pid, fingerprint: postFingerprint).focusedElementValue
                || preState.focusedElementRole != ActionPreState(pid: snapshot.app.pid, fingerprint: postFingerprint).focusedElementRole
            recordActionOutcome(app: appKey, changeLevel: clickChanged ? .confirmed : .none)
            actionSummary = resultLine + "\n" + actionSummary
            if let warning = ActionVerification.verifyClick(
                preState: preState, pid: snapshot.app.pid, postFingerprint: postFingerprint
            ) {
                actionSummary += "\n" + warning
            }
            if let failHint = consecutiveFailureHint(tool: "click", app: appKey) {
                actionSummary += "\n" + failHint
            }
            return actionObservationResult(before: snapshot, after: afterSnapshot, actionSummary: actionSummary)
        }
    }

    public func performSecondaryAction(app: String, stableRef: String? = nil, elementIndex: String?, elementText: String?, snapshotId: String? = nil, action: String) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "perform_secondary_action")
        return try preservingFrontmostApp {
            let snapshot = try snapshotAwareOfStaleness(for: app, snapshotId: snapshotId)
            if action.caseInsensitiveCompare("activate_app") == .orderedSame {
                snapshot.app.runningApplication.activate()
                InputSimulation.raiseTargetWindow(pid: snapshot.app.pid)
                skipFocusRestore = true
                Thread.sleep(forTimeInterval: 0.2)
                let afterSnapshot = try refreshSnapshot(for: app)
                let preState = ActionPreState(pid: snapshot.app.pid, fingerprint: structuralFingerprint(snapshot), snapshot: snapshot)
                let summary = ActionResultSummary.line(
                    tool: "perform_secondary_action",
                    route: "activate_app",
                    preState: preState,
                    postSnapshot: afterSnapshot
                ) + "\nActivated and raised \(afterSnapshot.app.name)."
                return actionObservationResult(before: snapshot, after: afterSnapshot, actionSummary: summary)
            }
            try prepareForForegroundOperationIfNeeded(snapshot: snapshot, reason: .clickFallback)
            let preState = ActionPreState(pid: snapshot.app.pid, fingerprint: structuralFingerprint(snapshot), snapshot: snapshot)
            let record = try resolveElement(snapshot: snapshot, stableRef: stableRef, elementIndex: elementIndex, elementText: elementText)

            guard let rawAction = matchingAction(requested: action, record: record) else {
                throw ComputerUseError.message(invalidSecondaryActionMessage(action: action, record: record))
            }

            guard let element = record.element else {
                throw ComputerUseError.stateUnavailable("element '\(elementIndex ?? elementText ?? "?")' has no backing accessibility object. Re-call get_app_state for fresh state.")
            }

            try AutomationPolicy().authorizeToolCall(named: "perform_secondary_action")
            let result = AXUIElementPerformAction(element, rawAction as CFString)
            guard result == .success else {
                throw ComputerUseError.message(
                    "AXUIElementPerformAction(\(rawAction)) failed with code \(result.rawValue). " +
                    "The element may have become stale — re-call get_app_state for fresh state. " +
                    "If you need a right-click context menu, use click with mouse_button=\"right\" instead."
                )
            }

            waitUntilSettled(pid: snapshot.app.pid, maxWait: 1.0)
            let afterSnapshot = try refreshSnapshot(for: app)
            let summary = ActionResultSummary.line(
                tool: "perform_secondary_action",
                target: elementSummary(for: record),
                route: rawAction,
                preState: preState,
                postSnapshot: afterSnapshot
            ) + "\nPerformed '\(action)' on \(elementSummary(for: record))."
            return actionObservationResult(before: snapshot, after: afterSnapshot, actionSummary: summary)
        }
    }

    public func scroll(app: String, direction: String, stableRef: String? = nil, elementIndex: String?, elementText: String?, snapshotId: String? = nil, pages: Double) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "scroll")
        let normalized = direction.lowercased()
        guard ["up", "down", "left", "right"].contains(normalized) else {
            throw ComputerUseError.message("Invalid scroll direction: \(direction). Use: up, down, left, right.")
        }
        guard pages.isFinite, pages > 0 else {
            throw ComputerUseError.message("pages must be > 0")
        }
        guard pages <= maxScrollPages else {
            throw ComputerUseError.message("pages must be <= \(maxScrollPages)")
        }

        return try preservingFrontmostApp {
            let snapshot = try snapshotAwareOfStaleness(for: app, snapshotId: snapshotId)
            try prepareForForegroundOperationIfNeeded(snapshot: snapshot, reason: .scrollFallback)
            let preFingerprint = structuralFingerprint(snapshot)
            let preState = ActionPreState(pid: snapshot.app.pid, fingerprint: preFingerprint, snapshot: snapshot)
            let record: ElementRecord
            if stableRef != nil || elementIndex != nil || elementText != nil {
                record = try resolveElement(snapshot: snapshot, stableRef: stableRef, elementIndex: elementIndex, elementText: elementText)
            } else {
                record = try defaultScrollTarget(in: snapshot)
            }

            let point = try scrollableGlobalPoint(for: record, snapshot: snapshot)
            let cursorTarget = point.map {
                makeVisualCursorTarget(
                    at: $0,
                    targetWindowID: snapshot.targetWindowID,
                    targetWindowLayer: snapshot.targetWindowLayer
                )
            }
            moveVisualCursor(to: cursorTarget)

            let repeatCount = integralScrollPageCount(pages)
            let pageAction = scrollPageAction(for: record, direction: normalized)
            let lineAction = scrollLineAction(for: record, direction: normalized)
            let didAttemptScroll: Bool
            do {
                didAttemptScroll = try performBackgroundScroll(
                    at: point,
                    direction: normalized,
                    pages: pages,
                    pageAction: pageAction,
                    lineAction: lineAction,
                    pageActionRepeatCount: repeatCount,
                    scrollAnchor: record.element,
                    snapshot: snapshot
                )
            } catch {
                settleVisualCursor(at: cursorTarget)
                throw error
            }

            if !didAttemptScroll {
                settleVisualCursor(at: cursorTarget)
                throw ComputerUseError.stateUnavailable(
                    "element \(elementIndex ?? elementText ?? "?") has no background-safe scroll method"
                )
            }
            settleVisualCursor(at: cursorTarget)

            let afterSnapshot = try refreshSnapshot(for: app)
            let pagesText = pages == 1 ? "1 page" : "\(pages) pages"
            var summary = "Scrolled \(normalized) \(pagesText) on \(elementSummary(for: record))."
            summary = ActionResultSummary.line(
                tool: "scroll",
                target: elementSummary(for: record),
                route: "background_scroll",
                preState: preState,
                postSnapshot: afterSnapshot
            ) + "\n" + summary
            let postFingerprint = structuralFingerprint(afterSnapshot)
            if preFingerprint == postFingerprint {
                summary += "\n⚠ Scroll may not have taken effect — no visible content change detected."
            }
            return actionObservationResult(before: snapshot, after: afterSnapshot, actionSummary: summary)
        }
    }

    public func drag(
        app: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        coordinateSpace: CoordinateSpace = .pixel
    ) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "drag")
        return try preservingFrontmostApp {
            // Always refresh for drag — stale windowBounds cause coordinate drift
            let snapshot = try refreshSnapshot(for: app)
            try prepareForForegroundOperationIfNeeded(snapshot: snapshot, reason: .dragFallback)
            let preState = ActionPreState(pid: snapshot.app.pid, fingerprint: structuralFingerprint(snapshot), snapshot: snapshot)
            let fromPixel = convertToSnapshotPixels(CGPoint(x: fromX, y: fromY), coordinateSpace: coordinateSpace, snapshot: snapshot)
            let toPixel = convertToSnapshotPixels(CGPoint(x: toX, y: toY), coordinateSpace: coordinateSpace, snapshot: snapshot)
            let start = try screenshotToGlobalPoint(snapshot: snapshot, x: fromPixel.x, y: fromPixel.y)
            let end = try screenshotToGlobalPoint(snapshot: snapshot, x: toPixel.x, y: toPixel.y)
            let startCursorTarget = makeVisualCursorTarget(
                at: start,
                targetWindowID: snapshot.targetWindowID,
                targetWindowLayer: snapshot.targetWindowLayer
            )
            let endCursorTarget = makeVisualCursorTarget(
                at: end,
                targetWindowID: snapshot.targetWindowID,
                targetWindowLayer: snapshot.targetWindowLayer
            )
            moveVisualCursor(to: startCursorTarget)
            do {
                try performDragEvent(from: start, to: end, snapshot: snapshot)
            } catch {
                settleVisualCursor(at: startCursorTarget)
                throw error
            }
            settleVisualCursor(at: endCursorTarget)
            let coordTag = coordinateSpaceTag(for: coordinateSpace, input: CGPoint(x: fromX, y: fromY), pixel: fromPixel)
            let afterSnapshot = try refreshSnapshot(for: app)
            let summary = ActionResultSummary.line(
                tool: "drag",
                route: "coordinate_drag",
                preState: preState,
                postSnapshot: afterSnapshot
            ) + "\nDragged from (\(Int(fromPixel.x)), \(Int(fromPixel.y)))\(coordTag) to (\(Int(toPixel.x)), \(Int(toPixel.y)))."
            return actionObservationResult(before: snapshot, after: afterSnapshot, actionSummary: summary)
        }
    }

    public func typeText(app: String, text: String, stableRef: String? = nil, elementIndex: String? = nil, elementText: String? = nil, snapshotId: String? = nil) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "type_text")
        return try preservingFrontmostApp {
            let snapshot = try snapshotAwareOfStaleness(for: app, snapshotId: snapshotId)
            try prepareForForegroundOperationIfNeeded(snapshot: snapshot, reason: .typing)
            let textSummary = redactedActionInputSummary(text)
            let useActivation = needsActivationForInput(snapshot.app)
            let preState = ActionPreState(pid: snapshot.app.pid, fingerprint: structuralFingerprint(snapshot), snapshot: snapshot)
            let appKey = app

            if stableRef != nil || elementIndex != nil || elementText != nil {
                let record = try resolveElement(snapshot: snapshot, stableRef: stableRef, elementIndex: elementIndex, elementText: elementText)
                guard let element = record.element else {
                    throw ComputerUseError.stateUnavailable(
                        "element '\(elementIndex ?? elementText ?? stableRef ?? "?")' has no backing accessibility object. Re-call get_app_state for fresh state."
                    )
                }
                try focusTargetForTypeText(record: record, element: element)
                let focusedSnapshot = try refreshSnapshot(for: app)
                let freshRecord = try resolveElement(
                    snapshot: focusedSnapshot,
                    stableRef: stableRef,
                    elementIndex: elementIndex,
                    elementText: elementText
                )
                guard let freshElement = freshRecord.element else {
                    throw ComputerUseError.stateUnavailable(
                        "element '\(elementIndex ?? elementText ?? stableRef ?? "?")' has no backing accessibility object after focus. Re-call get_app_state for fresh state."
                    )
                }
                guard focusedElementMatchesTarget(element: freshElement, pid: snapshot.app.pid) else {
                    throw ComputerUseError.message(
                        "type_text could not confirm keyboard focus on \(elementSummary(for: freshRecord)); no text was sent."
                    )
                }

                let route = try performTypeText(
                    text,
                    snapshot: focusedSnapshot,
                    useActivation: useActivation
                )
                waitUntilSettled(pid: snapshot.app.pid, maxWait: 1.0)
                let afterSnapshot = try refreshSnapshot(for: app)
                let warning = ActionVerification.verifyTypeText(
                    preState: preState,
                    expectedText: text,
                    pid: snapshot.app.pid
                )
                let actionResult = ActionResultSummary.make(
                    tool: "type_text",
                    target: elementSummary(for: freshRecord),
                    route: route.rawValue,
                    preState: preState,
                    postSnapshot: afterSnapshot,
                    consecutiveNoChange: consecutiveNoChangeCount(for: appKey),
                    changeLevelOverride: warning == nil ? nil : ChangeLevel.none
                )
                recordActionOutcome(app: appKey, changeLevel: actionResult.changeLevel)
                var summary = actionResult.renderedLine
                    + "\nTyped \"\(textSummary)\" into \(elementSummary(for: freshRecord))."
                if let warning {
                    summary += "\n" + warning
                }
                if let failHint = consecutiveFailureHint(tool: "type_text", app: appKey) {
                    summary += "\n" + failHint
                }
                return actionObservationResult(
                    before: snapshot,
                    after: afterSnapshot,
                    actionSummary: summary,
                    actionMetadata: actionResult.structuredMetadata
                )
            }

            let route = try performTypeText(
                text,
                snapshot: snapshot,
                useActivation: useActivation
            )
            waitUntilSettled(pid: snapshot.app.pid, maxWait: 1.0)
            let afterSnapshot = try refreshSnapshot(for: app)
            let warning = ActionVerification.verifyTypeText(
                preState: preState,
                expectedText: text,
                pid: snapshot.app.pid
            )
            let actionResult = ActionResultSummary.make(
                tool: "type_text",
                route: route.rawValue,
                preState: preState,
                postSnapshot: afterSnapshot,
                consecutiveNoChange: consecutiveNoChangeCount(for: appKey),
                changeLevelOverride: warning == nil ? nil : ChangeLevel.none
            )
            recordActionOutcome(app: appKey, changeLevel: actionResult.changeLevel)
            var summary = actionResult.renderedLine
                + "\nTyped \"\(textSummary)\" into \(snapshot.app.name)."
            if let warning {
                summary += "\n" + warning
            }
            if let failHint = consecutiveFailureHint(tool: "type_text", app: appKey) {
                summary += "\n" + failHint
            }
            return actionObservationResult(
                before: snapshot,
                after: afterSnapshot,
                actionSummary: summary,
                actionMetadata: actionResult.structuredMetadata
            )
        }
    }

    public func pressKey(app: String, key: String) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "press_key")
        return try preservingFrontmostApp {
            let beforeSnapshot = try currentSnapshot(for: app)
            try prepareForForegroundOperationIfNeeded(snapshot: beforeSnapshot, reason: .keyboard)
            let beforeFingerprint = structuralFingerprint(beforeSnapshot)
            let preState = ActionPreState(pid: beforeSnapshot.app.pid, fingerprint: beforeFingerprint, snapshot: beforeSnapshot)

            let parsed = try KeyPressParser.parse(key)
            let intent = detectKeyIntent(parsed)

            var usedSemanticRoute = false

            switch intent {
            case .selectAll:
                usedSemanticRoute = attemptSemanticSelectAll(snapshot: beforeSnapshot)
            case .rawKey:
                break
            }

            if !usedSemanticRoute {
                if needsActivationForInput(beforeSnapshot.app) {
                    let alreadyActive = (NSWorkspace.shared.frontmostApplication?.processIdentifier == beforeSnapshot.app.pid)
                    if !alreadyActive {
                        try InputSimulation.prepareAppForGlobalPointerInput(beforeSnapshot.app, reason: .keyboard)
                    }
                    try InputSimulation.pressKeyGlobally(key, pid: beforeSnapshot.app.pid, appName: beforeSnapshot.app.name)
                    skipFocusRestore = true
                } else {
                    let windowNumber = beforeSnapshot.targetWindowID.map { Int($0) }
                    try InputSimulation.pressKey(key, pid: beforeSnapshot.app.pid, windowNumber: windowNumber)
                }
            }

            waitUntilSettled(pid: beforeSnapshot.app.pid, maxWait: 1.0)
            let afterSnapshot = try refreshSnapshot(for: app)
            let afterFingerprint = structuralFingerprint(afterSnapshot)
            let appKey = app
            let keyRoute = usedSemanticRoute ? "semantic_ax"
                : (needsActivationForInput(beforeSnapshot.app) ? "hid_activation" : "targeted_key")
            let changed = beforeFingerprint != afterFingerprint
                || preState.focusedElementValue != ActionPreState(pid: beforeSnapshot.app.pid, fingerprint: afterFingerprint).focusedElementValue
            recordActionOutcome(app: appKey, changeLevel: changed ? .confirmed : .none)

            var summary = ActionResultSummary.line(
                tool: "press_key",
                route: keyRoute,
                preState: preState,
                postSnapshot: afterSnapshot,
                consecutiveNoChange: consecutiveNoChangeCount(for: appKey)
            ) + "\nPressed '\(key)' in \(afterSnapshot.app.name)."

            if usedSemanticRoute {
                summary += " (via semantic AX route)"
            }

            if !changed {
                summary += "\n⚠ press_key(\(key)) did not appear to change the UI. " +
                    "The app may not respond to keyboard shortcuts delivered in the background. " +
                    "Try clicking a UI element directly (e.g. a search icon) with element_text instead."
            }

            if let failHint = consecutiveFailureHint(tool: "press_key", app: appKey) {
                summary += "\n" + failHint
            }

            return actionObservationResult(before: beforeSnapshot, after: afterSnapshot, actionSummary: summary)
        }
    }

    public func setValue(app: String, stableRef: String? = nil, elementIndex: String?, elementText: String?, snapshotId: String? = nil, value: String) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "set_value")
        return try preservingFrontmostApp {
            let snapshot = try snapshotAwareOfStaleness(for: app, snapshotId: snapshotId)
            try prepareForForegroundOperationIfNeeded(snapshot: snapshot, reason: .typing)
            let preState = ActionPreState(pid: snapshot.app.pid, fingerprint: structuralFingerprint(snapshot), snapshot: snapshot)
            let record = try resolveElement(snapshot: snapshot, stableRef: stableRef, elementIndex: elementIndex, elementText: elementText)

            guard let element = record.element else {
                throw ComputerUseError.stateUnavailable("element '\(elementIndex ?? elementText ?? "?")' has no backing accessibility object. Re-call get_app_state for fresh state.")
            }

            guard try isSettableForSetValue(element: element, attribute: kAXValueAttribute as String) else {
                throw ComputerUseError.message(nonSettableSetValueErrorMessage)
            }

            let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
            moveVisualCursor(to: cursorTarget)
            let focusSummary = focusElementBeforeSetValue(element)
            Thread.sleep(forTimeInterval: 0.05)

            let focusedSnapshot = try refreshSnapshot(for: app)
            let freshRecord = try resolveElement(
                snapshot: focusedSnapshot,
                stableRef: stableRef,
                elementIndex: elementIndex,
                elementText: elementText
            )

            guard let freshElement = freshRecord.element else {
                settleVisualCursor(at: cursorTarget)
                throw ComputerUseError.stateUnavailable("element '\(elementIndex ?? elementText ?? stableRef ?? "?")' has no backing accessibility object after focus. Re-call get_app_state for fresh state.")
            }

            guard try isSettableForSetValue(element: freshElement, attribute: kAXValueAttribute as String) else {
                settleVisualCursor(at: cursorTarget)
                throw ComputerUseError.message(nonSettableSetValueErrorMessage)
            }

            do {
                try AutomationPolicy().authorizeToolCall(named: "set_value")
                let result = AXUIElementSetAttributeValue(freshElement, kAXValueAttribute as CFString, value as CFString)
                guard result == .success else {
                    throw ComputerUseError.message("AXUIElementSetAttributeValue failed with \(result.rawValue)")
                }
            } catch {
                settleVisualCursor(at: cursorTarget)
                throw error
            }

            Thread.sleep(forTimeInterval: 0.1)
            settleVisualCursor(at: cursorTarget)
            let valueSummary = redactedActionInputSummary(value)
            let afterSnapshot = try refreshSnapshot(for: app)
            let actionResult = ActionResultSummary.make(
                tool: "set_value",
                target: elementSummary(for: freshRecord),
                route: textMutationPlan(intent: .setValue, useActivation: false).rawValue,
                preState: preState,
                postSnapshot: afterSnapshot
            )
            var summary = actionResult.renderedLine
                + "\nSet value \"\(valueSummary)\" on \(elementSummary(for: freshRecord))."
                + "\nFocus target before setting: \(focusSummary)."
                + "\nRe-resolved target after focus: \(elementSummary(for: freshRecord))."
            if focusedSummaryMatches(record: freshRecord, snapshot: afterSnapshot),
               isEditableTextRole(freshRecord.role) {
                summary += "\n⚠ The edited text element is still focused. Some apps keep edits pending until you commit with Return, click another control, or otherwise move focus."
            }
            return actionObservationResult(
                before: snapshot,
                after: afterSnapshot,
                actionSummary: summary,
                actionMetadata: actionResult.structuredMetadata
            )
        }
    }

    public func waitForElement(
        app: String,
        elementText: String?,
        timeoutSeconds: Double,
        waitMode: String = "element_text",
        pollInterval: Double = 0.5
    ) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "wait_for_element")
        return try preservingFrontmostApp {
            let deadline = Date(timeIntervalSinceNow: min(max(timeoutSeconds, 1), 30))
            let interval: TimeInterval = min(max(pollInterval, 0.1), 2.0)
            let normalizedMode = waitMode.lowercased()
            let startedAt = Date()
            var lastSnapshot: AppSnapshot?
            let initialSnapshot = try refreshSnapshot(for: app, readOnly: normalizedMode != "element_text")
            let initialElementCount = initialSnapshot.elementCount
            lastSnapshot = initialSnapshot

            while Date() < deadline {
                // A local pause interrupts long waits instead of allowing
                // observation to continue until the original timeout.
                try AutomationPolicy().authorizeToolCall(named: "wait_for_element")
                let snapshot = try refreshSnapshot(for: app, readOnly: normalizedMode != "element_text")
                lastSnapshot = snapshot

                switch normalizedMode {
                case "element_text":
                    guard let elementText, !elementText.isEmpty else {
                        throw ComputerUseError.missingArgument("element_text")
                    }
                    let lowered = elementText.lowercased()
                    if let match = snapshot.elements.values.first(where: { record in
                        if let dt = record.displayText, dt.localizedCaseInsensitiveContains(lowered) {
                            return true
                        }
                        if let id = record.identifier, id.localizedCaseInsensitiveContains(lowered) {
                            return true
                        }
                        return false
                    }) {
                        return ToolCallResult.text(
                            "[Wait] matched=true mode=element_text elapsed_seconds=\(formattedElapsed(since: startedAt)) match_index=\(match.index)\n" +
                            "Found element matching '\(elementText)' at index \(match.index).\n" +
                            snapshot.renderedText(style: .fullState)
                        )
                    }

                case "window_title_contains":
                    guard let elementText, !elementText.isEmpty else {
                        throw ComputerUseError.missingArgument("element_text")
                    }
                    if snapshot.windowTitle?.localizedCaseInsensitiveContains(elementText) == true {
                        return ToolCallResult.text(
                            "[Wait] matched=true mode=window_title_contains elapsed_seconds=\(formattedElapsed(since: startedAt))\n" +
                            snapshot.renderedText(style: .fullState)
                        )
                    }

                case "element_count_changed":
                    if snapshot.elementCount != initialElementCount {
                        return ToolCallResult.text(
                            "[Wait] matched=true mode=element_count_changed elapsed_seconds=\(formattedElapsed(since: startedAt)) initial_count=\(initialElementCount) current_count=\(snapshot.elementCount)\n" +
                            snapshot.renderedText(style: .fullState)
                        )
                    }

                case "focused_value_contains":
                    guard let elementText, !elementText.isEmpty else {
                        throw ComputerUseError.missingArgument("element_text")
                    }
                    let appElement = AXUIElementCreateApplication(snapshot.app.pid)
                    var focusedRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                       let focusedRef {
                        let focused = focusedRef as! AXUIElement
                        if stringValue(of: focused, attribute: kAXValueAttribute as String)?.localizedCaseInsensitiveContains(elementText) == true {
                            return ToolCallResult.text(
                                "[Wait] matched=true mode=focused_value_contains elapsed_seconds=\(formattedElapsed(since: startedAt))\n" +
                                snapshot.renderedText(style: .fullState)
                            )
                        }
                    }

                default:
                    throw ComputerUseError.invalidArguments("wait_mode must be one of: element_text, window_title_contains, element_count_changed, focused_value_contains.")
                }

                try waitWhileAutomationAllowed(for: interval)
            }

            if let snapshot = lastSnapshot {
                return ToolCallResult.text(
                    "[Wait] matched=false mode=\(normalizedMode) elapsed_seconds=\(formattedElapsed(since: startedAt))\n" +
                    "Timeout after \(Int(timeoutSeconds))s.\n" +
                    snapshot.renderedText(style: .fullState),
                    isError: true
                )
            }
            throw ComputerUseError.stateUnavailable("Could not snapshot app '\(app)' during wait.")
        }
    }

    private func formattedElapsed(since start: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(start))
    }

    private func waitWhileAutomationAllowed(for interval: TimeInterval) throws {
        let deadline = Date(timeIntervalSinceNow: interval)
        while Date() < deadline {
            try AutomationPolicy().authorizeToolCall(named: "wait_for_element")
            Thread.sleep(forTimeInterval: max(0, min(0.1, deadline.timeIntervalSinceNow)))
        }
    }

    // MARK: - Snapshot cache

    func currentSnapshot(for query: String) throws -> AppSnapshot {
        let key = query.lowercased()
        if let snapshot = snapshotsByApp[key],
           let timestamp = snapshotTimestamps[key],
           Date().timeIntervalSince(timestamp) < snapshotMaxAge {
            return snapshot
        }

        return try refreshSnapshot(for: query)
    }

    /// Returns a fresh snapshot for a mutating action. When the caller provides
    /// a snapshot ID, it is an optimistic-concurrency precondition: an unknown
    /// or superseded ID fails before any side effect occurs.
    func snapshotAwareOfStaleness(for query: String, snapshotId: String?) throws -> AppSnapshot {
        let expected = try validateSnapshotPrecondition(for: query, snapshotId: snapshotId)

        // Always refresh mutations. Stable refs are reconciled by logical
        // identity; removed or replaced targets therefore fail resolution.
        let fresh = try refreshSnapshot(for: query)
        if let expected {
            try validateRefreshedSnapshot(fresh, against: expected, query: query)
        }
        return fresh
    }

    @discardableResult
    func validateSnapshotPrecondition(for query: String, snapshotId: String?) throws -> AppSnapshot? {
        guard let snapshotId else { return nil }
        let key = query.lowercased()
        guard let cached = snapshotsByApp[key],
              cached.snapshotID == snapshotId else {
            throw ComputerUseError.stateUnavailable(
                "stale snapshot_id '\(snapshotId)' for '\(query)'. " +
                "Use the latest action result or call get_app_state before retrying."
            )
        }
        return cached
    }

    func validateRefreshedSnapshot(
        _ fresh: AppSnapshot,
        against expected: AppSnapshot,
        query: String
    ) throws {
        guard snapshotPreconditionFingerprint(expected) == snapshotPreconditionFingerprint(fresh) else {
            throw ComputerUseError.stateUnavailable(
                "stale snapshot_id '\(expected.snapshotID)' for '\(query)': " +
                "the UI changed after that state was observed. Use the refreshed state before retrying."
            )
        }
    }

    /// Strict state version used only for an explicit snapshot precondition.
    /// Unlike action-change detection, this includes target geometry and
    /// identity so coordinates, duplicate labels, and reordered elements
    /// cannot be silently rebound after an out-of-band UI change.
    func snapshotPreconditionFingerprint(_ snapshot: AppSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(structuralFingerprint(snapshot))
        hasher.combine(snapshot.targetWindowID)
        hasher.combine(snapshot.windowBounds != nil)
        if let bounds = snapshot.windowBounds {
            hasher.combine(bounds.origin.x)
            hasher.combine(bounds.origin.y)
            hasher.combine(bounds.size.width)
            hasher.combine(bounds.size.height)
        }
        for index in snapshot.elements.keys.sorted() {
            guard let record = snapshot.elements[index] else { continue }
            hasher.combine(index)
            hasher.combine(record.identifier ?? "")
            hasher.combine(record.stableKey)
            hasher.combine(record.localFrame != nil)
            if let frame = record.localFrame {
                hasher.combine(frame.origin.x)
                hasher.combine(frame.origin.y)
                hasher.combine(frame.size.width)
                hasher.combine(frame.size.height)
            }
            hasher.combine(record.element != nil)
            if let element = record.element {
                hasher.combine(CFHash(element))
            }
        }
        return hasher.finalize()
    }

    @discardableResult
    func refreshSnapshot(for query: String, readOnly: Bool = false) throws -> AppSnapshot {
        let app = try AppDiscovery.resolve(query)
        let snapshot = try SnapshotBuilder.build(for: app, readOnly: readOnly)
        if stableRefsEnabled {
            let bucket = AXSnapshotDiff.bucketKey(for: snapshot)
            let diffState = AXSnapshotDiff.applyStableRefs(
                snapshot: snapshot,
                previous: axDiffStatesByBucket[bucket],
                minimumRefCounter: maxStableRefCounter
            )
            axDiffStatesByBucket[bucket] = diffState
            maxStableRefCounter = max(maxStableRefCounter, diffState.maxRefCounter)
        }

        let keys = Set([
            query.lowercased(),
            app.name.lowercased(),
            (app.bundleIdentifier ?? "").lowercased(),
        ].filter { !$0.isEmpty })

        let now = Date()
        for key in keys {
            snapshotsByApp[key] = snapshot
            snapshotTimestamps[key] = now
        }

        return snapshot
    }

    // MARK: - Internal helpers

    func structuralFingerprint(_ snapshot: AppSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.elementCount)
        hasher.combine(snapshot.windowTitle ?? "")
        hasher.combine(snapshot.focusedSummary ?? "")
        hasher.combine(snapshot.selectedText ?? "")
        for index in snapshot.elements.keys.sorted() {
            if let record = snapshot.elements[index] {
                hasher.combine(record.role ?? "")
                hasher.combine(record.displayText ?? "")
                hasher.combine(record.rawActions.count)
            }
        }
        return hasher.finalize()
    }

    // MARK: - Adaptive wait

    /// Poll AX state until it stabilizes (two consecutive reads return same
    /// fingerprint) or timeout is reached.
    @discardableResult
    func waitUntilSettled(
        pid: pid_t,
        maxWait: TimeInterval? = nil,
        pollInterval: TimeInterval = 0.12
    ) -> Bool {
        let envTimeout = ProcessInfo.processInfo.environment["ACCIO_COMPUTER_USE_SETTLE_TIMEOUT"]
            .flatMap(Double.init)
        let effectiveMaxWait = maxWait ?? envTimeout ?? 1.5
        let appElement = AXUIElementCreateApplication(pid)
        var lastFingerprint = quickFingerprint(appElement: appElement)
        let deadline = Date().addingTimeInterval(effectiveMaxWait)

        while Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
            let current = quickFingerprint(appElement: appElement)
            if current == lastFingerprint {
                return true
            }
            lastFingerprint = current
        }
        return false
    }

    /// Lightweight fingerprint: focused element role+value + window title.
    /// Cheaper than full tree walk — suitable for polling.
    private func quickFingerprint(appElement: AXUIElement) -> Int {
        var hasher = Hasher()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focusedRef {
            let focused = focusedRef as! AXUIElement
            hasher.combine(stringValue(of: focused, attribute: kAXRoleAttribute as String) ?? "")
            hasher.combine(stringValue(of: focused, attribute: kAXValueAttribute as String) ?? "")
        }
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let windowRef {
            let window = windowRef as! AXUIElement
            hasher.combine(stringValue(of: window, attribute: kAXTitleAttribute as String) ?? "")
        }
        return hasher.finalize()
    }

    // MARK: - Consecutive failure tracking

    func recordActionOutcome(app: String, changeLevel: ChangeLevel) {
        let key = app.lowercased()
        switch changeLevel {
        case .confirmed, .structureOnly:
            consecutiveNoChange[key] = 0
        case .none:
            consecutiveNoChange[key, default: 0] += 1
        case .unverifiable:
            break
        }
    }

    func consecutiveNoChangeCount(for app: String) -> Int {
        consecutiveNoChange[app.lowercased(), default: 0]
    }

    func consecutiveFailureHint(tool: String, app: String) -> String? {
        let count = consecutiveNoChangeCount(for: app)
        guard count >= 2 else { return nil }

        let toolHint: String
        switch tool {
        case "click":
            toolHint = "Element may not be interactive — try coordinates or different element_text."
        case "press_key":
            toolHint = "App may not be receiving keyboard input — try activate_app first, or use click/menu_select."
        case "type_text":
            toolHint = "Text field may not have focus — click the field first, or use set_value."
        case "drag":
            toolHint = "Drag may not have reached threshold — increase distance or try different coordinates."
        case "menu_select":
            toolHint = "Menu item may be disabled or path incorrect — use get_app_state to check menu state."
        default:
            toolHint = "Try a different approach."
        }

        return "  ⚠ \(count) consecutive actions with no detected effect on this app.\n" +
            "  \(toolHint)\n" +
            "  Recommendation: STOP current sequence and re-evaluate approach."
    }

    func prepareForForegroundOperationIfNeeded(
        snapshot: AppSnapshot,
        reason: ForegroundActivationReason
    ) throws {
        guard !preferBackgroundOperations else { return }

        let pid = snapshot.app.pid
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else {
            return
        }

        try InputSimulation.prepareAppForGlobalPointerInput(snapshot.app, reason: reason)
        skipFocusRestore = true
    }

    func performDragEvent(from start: CGPoint, to end: CGPoint, snapshot: AppSnapshot) throws {
        let eventStart = inputEventPoint(fromScreenStatePoint: start)
        let eventEnd = inputEventPoint(fromScreenStatePoint: end)

        if globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) {
            debugInputFallback(tool: "drag", targetDescription: "coordinate drag", snapshot: snapshot)
            try InputSimulation.prepareAppForGlobalPointerInput(snapshot.app, reason: .dragFallback)
            Thread.sleep(forTimeInterval: 0.10)
            try InputSimulation.dragGlobally(from: eventStart, to: eventEnd)
            return
        }

        if needsActivationForInput(snapshot.app) {
            let pid = snapshot.app.pid

            if let windowNumber = snapshot.targetWindowID.map({ Int($0) }) {
                try InputSimulation.dragTargeted(from: eventStart, to: eventEnd, pid: pid, windowNumber: windowNumber)
                return
            }

            let alreadyActive = (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
            if !alreadyActive {
                try InputSimulation.prepareAppForGlobalPointerInput(snapshot.app, reason: .dragFallback)
            }

            try InputSimulation.dragGlobally(from: eventStart, to: eventEnd)
            skipFocusRestore = true
            return
        }

        try InputSimulation.dragTargeted(from: eventStart, to: eventEnd, pid: snapshot.app.pid, windowNumber: snapshot.targetWindowID.map { Int($0) })
    }

    /// Activation-based typing for non-native frameworks (Electron, Qt, Flutter).
    func performActivationTypeText(_ text: String, snapshot: AppSnapshot) throws {
        let pid = snapshot.app.pid
        let alreadyActive = (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)

        if !alreadyActive {
            try InputSimulation.prepareAppForGlobalPointerInput(snapshot.app, reason: .typing)
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw ComputerUseError.message(
                "type_text stopped because \(snapshot.app.name) was no longer frontmost."
            )
        }
        try AutomationPolicy().authorizeToolCall(named: "type_text")
        try InputSimulation.typeTextGlobally(text, expectedPID: pid)

        skipFocusRestore = true
    }

    func performTypeText(
        _ text: String,
        snapshot: AppSnapshot,
        useActivation: Bool
    ) throws -> TextMutationPlan {
        let plan = textMutationPlan(intent: .typeText, useActivation: useActivation)
        try AutomationPolicy().authorizeToolCall(named: "type_text")
        switch plan {
        case .keyboardPostToPID:
            try InputSimulation.typeText(text, pid: snapshot.app.pid)
        case .keyboardHID:
            try performActivationTypeText(text, snapshot: snapshot)
        case .axValueWrite:
            throw ComputerUseError.message("type_text cannot use the AXValue write route")
        }
        return plan
    }

    func focusTargetForTypeText(
        record: ElementRecord,
        element: AXUIElement
    ) throws {
        try AutomationPolicy().authorizeToolCall(named: "type_text")
        _ = try performPreferredClick(on: record, button: .left, clickCount: 1)
        if isSettable(element: element, attribute: kAXFocusedAttribute as String) {
            try AutomationPolicy().authorizeToolCall(named: "type_text")
            _ = AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    func focusedElementMatchesTarget(element: AXUIElement, pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return false
        }

        var candidate: AXUIElement? = (focusedRef as! AXUIElement)
        for _ in 0..<16 {
            guard let current = candidate else { return false }
            if CFEqual(current, element) {
                return true
            }
            candidate = copyParent(of: current)
        }
        return false
    }
}
