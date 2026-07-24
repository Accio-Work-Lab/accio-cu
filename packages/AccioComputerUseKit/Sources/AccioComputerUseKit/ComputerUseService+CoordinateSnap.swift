import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum ScreenPointTargetSafety: Equatable {
    case allowed
    case blocked
    case indeterminate
}

func classifyScreenPointTarget(ownerPID: pid_t?, bundleIdentifier: String?) -> ScreenPointTargetSafety {
    guard let ownerPID else { return .indeterminate }
    if ownerPID == getpid() || AppSafetyPolicy.isBlocked(bundleIdentifier: bundleIdentifier) {
        return .blocked
    }
    guard bundleIdentifier != nil else { return .indeterminate }
    return .allowed
}

func combinedScreenPointSafety(
    windowTarget: ScreenPointTargetSafety,
    accessibilityTarget: ScreenPointTargetSafety
) -> ScreenPointTargetSafety {
    if windowTarget == .blocked || accessibilityTarget == .blocked {
        return .blocked
    }
    if windowTarget == .allowed && accessibilityTarget == .allowed {
        return .allowed
    }
    return .indeterminate
}

// MARK: - Coordinate space + AX snap helpers

extension ComputerUseService {

    // MARK: Coordinate space conversion

    /// Converts an input point in the given coordinate space to screenshot
    /// pixels for the supplied app snapshot. If the snapshot lacks pixel size
    /// info (no screenshot) the input is returned as-is so callers can still
    /// fall back to legacy pixel behavior.
    func convertToSnapshotPixels(
        _ point: CGPoint,
        coordinateSpace: CoordinateSpace,
        snapshot: AppSnapshot
    ) -> CGPoint {
        if coordinateSpace == .pixel { return point }
        guard let size = snapshot.screenshotPixelSize else { return point }
        return coordinateSpace.toPixelPoint(point, pixelSize: size)
    }

    /// Same as above, for screen snapshots.
    func convertToScreenPixels(
        _ point: CGPoint,
        coordinateSpace: CoordinateSpace,
        screen: ScreenSnapshot
    ) -> CGPoint {
        if coordinateSpace == .pixel { return point }
        guard let size = screen.screenshotPixelSize else { return point }
        return coordinateSpace.toPixelPoint(point, pixelSize: size)
    }

    /// Short suffix used in action summaries to surface the input coordinate
    /// space when it isn't plain pixels — agents see both the original input
    /// and the resolved pixel coordinates.
    func coordinateSpaceTag(for space: CoordinateSpace, input: CGPoint, pixel: CGPoint) -> String {
        guard space != .pixel else { return "" }
        let inX = formatCoord(input.x)
        let inY = formatCoord(input.y)
        return " [from \(space.summaryLabel) input (\(inX), \(inY))]"
    }

    private func formatCoord(_ value: CGFloat) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(format: "%.2f", Double(value))
    }

    // MARK: AX snap — app-scoped

    /// Find an AX-actionable element at the given window-local point. Combines
    /// the snapshot's recorded elements (`bestElement(containing:)`) with a
    /// live AX hit-test (`AXUIElementCopyElementAtPosition`). Returns whichever
    /// candidate exposes an actionable AX verb suitable for `button`, or `nil`
    /// when no good snap target exists (caller should use raw CGEvent click).
    func axSnapCandidate(
        forWindowLocalPoint windowPoint: CGPoint,
        snapshot: AppSnapshot,
        button: MouseButtonKind
    ) -> ElementRecord? {
        // Order matters: prefer the snapshot record (already has displayText)
        // so action summaries surface meaningful labels.
        let candidates: [ElementRecord]
        do {
            candidates = try clickCandidates(at: windowPoint, in: snapshot)
        } catch {
            return nil
        }

        for candidate in candidates {
            guard let element = candidate.element else { continue }
            let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? ""
            if role == "AXWindow" || role == "AXUnknown" { continue }
            if hasDisabledParent(element) { continue }

            let actions: [String] = !candidate.rawActions.isEmpty
                ? candidate.rawActions
                : (copyActions(for: element) ?? [])

            if axActionableForButton(actions: actions, button: button) {
                if candidate.rawActions.isEmpty, !actions.isEmpty {
                    return ElementRecord(
                        index: candidate.index,
                        identifier: candidate.identifier,
                        element: element,
                        localFrame: candidate.localFrame,
                        rawActions: actions,
                        prettyActions: actions,
                        displayText: candidate.displayText,
                        role: candidate.role
                    )
                }
                return candidate
            }
        }

        return nil
    }

    /// Returns true if the actions array contains a verb that maps to the
    /// requested mouse button. Left/middle click → AXPress/AXConfirm/AXOpen;
    /// right click → AXShowMenu.
    private func axActionableForButton(actions: [String], button: MouseButtonKind) -> Bool {
        switch button {
        case .left, .middle:
            return actions.contains { name in
                name.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame
                    || name.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame
                    || name.caseInsensitiveCompare("AXOpen") == .orderedSame
            }
        case .right:
            return actions.contains {
                $0.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame
            }
        }
    }

    func snapCandidateLabel(for record: ElementRecord) -> String {
        if record.index >= 0 {
            return elementSummary(for: record)
        }
        let role = record.role
            ?? (record.element.flatMap { stringValue(of: $0, attribute: kAXRoleAttribute) })
            ?? "AXElement"
        if let text = record.displayText, !text.isEmpty {
            let truncated = text.count > 60 ? String(text.prefix(57)) + "..." : text
            return "\(role) \"\(truncated)\""
        }
        return role
    }

    // MARK: AX snap — system wide (screen-level clicks)

    func screenPointTargetSafety(_ point: CGPoint) -> ScreenPointTargetSafety {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return .indeterminate
        }

        for window in windows {
            guard let boundsValue = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsValue),
                  bounds.contains(point),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            let windowName = window[kCGWindowName as String] as? String
            if pid == getpid(), windowName == "Accio Software Cursor" {
                continue
            }
            let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return classifyScreenPointTarget(ownerPID: pid, bundleIdentifier: bundleIdentifier)
        }
        return .indeterminate
    }

    /// Resolves the element that would receive accessibility input at a screen
    /// point. Requiring this independent signal before raw HID delivery keeps
    /// click-through overlays from hiding a blocked app underneath them.
    func accessibilityScreenPointTargetSafety(_ point: CGPoint) -> ScreenPointTargetSafety {
        let systemWide = AXUIElementCreateSystemWide()
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &hitRef
        ) == .success,
        let hit = hitRef else {
            return .indeterminate
        }

        var hitPID = pid_t()
        guard AXUIElementGetPid(hit, &hitPID) == .success else {
            return .indeterminate
        }
        return classifyScreenPointTarget(
            ownerPID: hitPID,
            bundleIdentifier: NSRunningApplication(processIdentifier: hitPID)?.bundleIdentifier
        )
    }

    /// Attempt an AX-snap click at a global screen point with no app context.
    /// Walks the system-wide AX hierarchy to find an actionable element under
    /// the cursor and invokes its AX action directly. Returns a descriptive
    /// label on success, or nil to signal the caller should perform a raw
    /// CGEvent click instead.
    func attemptSystemWideAXSnapClick(
        at globalPoint: CGPoint,
        button: MouseButtonKind,
        clickCount: Int
    ) throws -> String? {
        guard shouldUseAXClickActions(clickCount: clickCount) else {
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        var hitRef: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(globalPoint.x),
            Float(globalPoint.y),
            &hitRef
        )
        guard status == .success, let hit = hitRef else { return nil }

        var hitPID = pid_t()
        guard AXUIElementGetPid(hit, &hitPID) == .success,
              classifyScreenPointTarget(
                ownerPID: hitPID,
                bundleIdentifier: NSRunningApplication(processIdentifier: hitPID)?.bundleIdentifier
              ) == .allowed else {
            throw ComputerUseError.permissionDenied("Accio could not verify the AX target under the screen coordinates.")
        }

        let role = stringValue(of: hit, attribute: kAXRoleAttribute) ?? ""
        if role == "AXWindow" || role == "AXUnknown" || role.isEmpty { return nil }
        if hasDisabledParent(hit) { return nil }

        let actions = copyActions(for: hit) ?? []
        guard axActionableForButton(actions: actions, button: button) else {
            return nil
        }

        let preferredAction: String
        switch button {
        case .left, .middle:
            preferredAction = actions.first { name in
                name.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame
                    || name.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame
                    || name.caseInsensitiveCompare("AXOpen") == .orderedSame
            } ?? (kAXPressAction as String)
        case .right:
            preferredAction = actions.first {
                $0.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame
            } ?? (kAXShowMenuAction as String)
        }

        let attempts = max(clickCount, 1)
        for _ in 0..<attempts {
            guard AXUIElementGetPid(hit, &hitPID) == .success,
                  classifyScreenPointTarget(
                    ownerPID: hitPID,
                    bundleIdentifier: NSRunningApplication(processIdentifier: hitPID)?.bundleIdentifier
                  ) == .allowed else {
                throw ComputerUseError.permissionDenied("The screen coordinate target changed to a blocked app.")
            }
            let result = AXUIElementPerformAction(hit, preferredAction as CFString)
            switch result {
            case .success:
                Thread.sleep(forTimeInterval: 0.05)
            default:
                return nil
            }
        }

        let title = stringValue(of: hit, attribute: kAXTitleAttribute as String)
            ?? stringValue(of: hit, attribute: kAXDescriptionAttribute as String)
            ?? stringValue(of: hit, attribute: kAXValueAttribute as String)
        if let title, !title.isEmpty {
            let truncated = title.count > 60 ? String(title.prefix(57)) + "..." : title
            return "\(role) \"\(truncated)\""
        }
        return role
    }
}
