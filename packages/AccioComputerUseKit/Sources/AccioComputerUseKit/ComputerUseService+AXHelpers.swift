import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO

let nonSettableSetValueErrorMessage = "Cannot set a value for an element that is not settable. Use type_text to input text into fields, or click to toggle checkboxes/radio buttons."

func setValueAttributeIsSettable(result: AXError, settable: Bool, attribute: String) throws -> Bool {
    guard result == .success else {
        throw ComputerUseError.message("AXUIElementIsAttributeSettable(\(attribute)) failed with \(result.rawValue)")
    }

    return settable
}

func invalidSecondaryActionErrorMessage(action: String, elementIndex: Int) -> String {
    "\(action) is not a valid secondary action for element \(elementIndex). Re-call get_app_state for fresh state and check the element's actions list. For right-click context menus, use click with mouse_button=right instead."
}

// MARK: - AX Helpers

extension ComputerUseService {
    func isSettable(element: AXUIElement, attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    func isSettableForSetValue(element: AXUIElement, attribute: String) throws -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return try setValueAttributeIsSettable(
            result: result,
            settable: settable.boolValue,
            attribute: attribute
        )
    }

    func focusElementBeforeSetValue(_ element: AXUIElement) -> String {
        guard !AutomationPauseStore.shared.isPaused else { return "paused" }
        guard isSettable(element: element, attribute: kAXFocusedAttribute as String) else {
            return "not_settable"
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard result == .success else {
            return "failed(\(result.rawValue))"
        }

        Thread.sleep(forTimeInterval: 0.05)
        return "focused"
    }

    func focusedSummaryMatches(record: ElementRecord, snapshot: AppSnapshot) -> Bool {
        guard let focusedSummary = snapshot.focusedSummary else {
            return false
        }
        let indexPrefix = "[\(record.index)] "
        guard focusedSummary.hasPrefix(indexPrefix) else {
            return false
        }
        if let role = record.role {
            return focusedSummary.contains(role)
        }
        return true
    }

    func isEditableTextRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || role == kAXComboBoxRole as String
            || role == "AXSearchField"
    }

    func stringValue(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        return value as? String
    }

    func boolValue(of element: AXUIElement, attribute: String) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    func copyParent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    func copyChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let value else {
            return []
        }

        return value as? [AXUIElement] ?? []
    }

    func copyActions(for element: AXUIElement) -> [String]? {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success else {
            return nil
        }

        return actions as? [String]
    }

    func performAction(named action: String, on element: AXUIElement, availableActions: [String], repeatCount: Int = 1) throws -> Bool {
        guard availableActions.contains(where: { $0.caseInsensitiveCompare(action) == .orderedSame }) else {
            return false
        }

        let attempts = max(repeatCount, 1)
        for index in 0..<attempts {
            try AutomationPolicy().authorizeToolCall(named: "ax_action")
            let result = AXUIElementPerformAction(element, action as CFString)
            switch result {
            case .success:
                if index < attempts - 1 {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            case .attributeUnsupported where action.caseInsensitiveCompare("AXOpen") == .orderedSame:
                return true
            case .failure, .actionUnsupported, .attributeUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
                return false
            default:
                throw ComputerUseError.message("AXUIElementPerformAction(\(action)) failed with \(result.rawValue)")
            }
        }

        return true
    }

    func hasDisabledParent(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<4 {
            guard let parent = copyParent(of: current) else {
                return false
            }
            if boolValue(of: parent, attribute: kAXEnabledAttribute as String) == false {
                return true
            }
            current = parent
        }
        return false
    }

    /// Check if an element contains disabled children — the Electron/Chromium
    /// signature where the scroll area's children (AXList/AXGroup) are marked
    /// disabled even though the scroll area itself is enabled.
    func hasDisabledChild(_ element: AXUIElement) -> Bool {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return false }
        for child in children.prefix(3) {
            if boolValue(of: child, attribute: kAXEnabledAttribute as String) == false {
                return true
            }
            var grandRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &grandRef) == .success,
               let grandChildren = grandRef as? [AXUIElement] {
                for grandChild in grandChildren.prefix(3) {
                    if boolValue(of: grandChild, attribute: kAXEnabledAttribute as String) == false {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Detect Electron/Chromium app: element has disabled parent OR contains
    /// disabled children (scroll areas in Electron have enabled parents but
    /// disabled child lists/groups).
    func isElectronElement(_ element: AXUIElement) -> Bool {
        hasDisabledParent(element) || hasDisabledChild(element)
    }

    func hasAncestorRole(_ role: String, of element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<12 {
            guard let parent = copyParent(of: current) else {
                return false
            }
            if stringValue(of: parent, attribute: kAXRoleAttribute) == role {
                return true
            }
            current = parent
        }
        return false
    }

    func localFrame(of element: AXUIElement, windowBounds: CGRect?) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        guard
            positionResult == .success,
            sizeResult == .success,
            let positionValue,
            let sizeValue
        else {
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

    // MARK: - Element resolution

    func lookupElement(snapshot: AppSnapshot, index: String) throws -> ElementRecord {
        guard let parsedIndex = Int(index), let record = snapshot.elements[parsedIndex] else {
            let maxIndex = snapshot.elements.keys.max() ?? 0
            throw ComputerUseError.invalidArguments(
                "unknown element_index '\(index)'. Valid range: 0–\(maxIndex). " +
                "Indices change on every snapshot — re-call get_app_state to get fresh indices."
            )
        }

        return record
    }

    func lookupElementByStableRef(snapshot: AppSnapshot, stableRef: String) throws -> ElementRecord {
        let normalized = stableRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ComputerUseError.invalidArguments("stable_ref must not be empty.")
        }
        if let record = AXSnapshotDiff.stableRefMap(snapshot: snapshot)[normalized] {
            return record
        }
        throw ComputerUseError.invalidArguments(
            "stable_ref \(normalized) is stale or unknown in the latest snapshot. " +
            "Use a current ref, element_text, or call get_app_state."
        )
    }

    func lookupElementByText(snapshot: AppSnapshot, text: String) throws -> ElementRecord {
        let lowered = text.lowercased()
        let candidates = snapshot.elements.values
            .filter { record in
                if let dt = record.displayText, dt.localizedCaseInsensitiveContains(lowered) {
                    return true
                }
                if let id = record.identifier, id.localizedCaseInsensitiveContains(lowered) {
                    return true
                }
                return false
            }
            .sorted { $0.index < $1.index }

        let visibleRect: CGRect? = snapshot.windowBounds.map {
            CGRect(x: 0, y: 0, width: $0.width, height: $0.height)
        }

        func isVisible(_ record: ElementRecord) -> Bool {
            guard let visibleRect, let frame = record.localFrame else { return false }
            return visibleRect.intersects(frame)
        }

        let exactDisplayText = candidates.filter { $0.displayText?.caseInsensitiveCompare(text) == .orderedSame }
        if !exactDisplayText.isEmpty {
            return exactDisplayText.first(where: { isVisible($0) }) ?? exactDisplayText[0]
        }

        let exactID = candidates.filter { $0.identifier?.caseInsensitiveCompare(text) == .orderedSame }
        if !exactID.isEmpty {
            return exactID.first(where: { isVisible($0) }) ?? exactID[0]
        }

        if !candidates.isEmpty {
            return candidates.first(where: { isVisible($0) }) ?? candidates[0]
        }

        let totalCount = snapshot.elements.count
        let available = snapshot.elements.values
            .sorted { $0.index < $1.index }
            .compactMap { $0.displayText ?? $0.identifier }
            .prefix(30)
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        throw ComputerUseError.invalidArguments(
            "No element matching text '\(text)' (\(totalCount) elements total). " +
            "Available labels: [\(available)]. " +
            "Try a shorter substring match, or use element_index, or use --filter \"\(text)\" with get_app_state."
        )
    }

    func resolveElement(snapshot: AppSnapshot, stableRef: String? = nil, elementIndex: String?, elementText: String?) throws -> ElementRecord {
        if let stableRef {
            let record = try lookupElementByStableRef(snapshot: snapshot, stableRef: stableRef)
            if let elementText, !elementMatchesText(record, text: elementText) {
                throw ComputerUseError.invalidArguments(
                    "stable_ref \(stableRef) resolved to \(elementSummary(for: record)), " +
                    "which does not match element_text '\(elementText)'. " +
                    "Use a current ref from the latest snapshot or call get_app_state."
                )
            }
            return record
        }

        // Case 1: Both provided → use index as fast path, cross-validate against text
        if let elementIndex, let elementText {
            if let record = try? lookupElement(snapshot: snapshot, index: elementIndex) {
                if elementMatchesText(record, text: elementText) {
                    return record
                }
                // Index resolved but text doesn't match → index is likely stale.
                // Fall back to text-based search.
            }
            return try lookupElementByText(snapshot: snapshot, text: elementText)
        }

        // Case 2: Only index
        if let elementIndex {
            return try lookupElement(snapshot: snapshot, index: elementIndex)
        }

        // Case 3: Only text
        if let elementText {
            return try lookupElementByText(snapshot: snapshot, text: elementText)
        }

        throw ComputerUseError.invalidArguments("Provide stable_ref, element_index, or element_text (or element_label) to identify the target element.")
    }

    /// Checks whether a resolved element's displayText or identifier matches the expected text.
    private func elementMatchesText(_ record: ElementRecord, text: String) -> Bool {
        let lowered = text.lowercased()
        if let displayText = record.displayText,
           displayText.localizedCaseInsensitiveContains(lowered) {
            return true
        }
        if let identifier = record.identifier,
           identifier.localizedCaseInsensitiveContains(lowered) {
            return true
        }
        return false
    }

    // MARK: - Coordinate helpers

    func globalPoint(for record: ElementRecord, snapshot: AppSnapshot) throws -> CGPoint? {
        guard let frame = record.localFrame else {
            return nil
        }

        let clickTarget: CGPoint
        if let element = record.element,
           record.role == kAXStaticTextRole as String,
           let rowFrame = containingRowFrame(for: element, textFrame: frame, windowBounds: snapshot.windowBounds) {
            clickTarget = CGPoint(x: rowFrame.midX, y: rowFrame.midY)
        } else {
            clickTarget = CGPoint(x: frame.midX, y: frame.midY)
        }

        return try windowPointToGlobalPoint(snapshot: snapshot, point: clickTarget)
    }

    func containingRowFrame(for element: AXUIElement, textFrame: CGRect, windowBounds: CGRect?) -> CGRect? {
        let textCenter = CGPoint(x: textFrame.midX, y: textFrame.midY)
        var current = element

        for _ in 0..<4 {
            guard let parent = copyParent(of: current) else {
                return nil
            }

            if let frame = localFrame(of: parent, windowBounds: windowBounds),
               frame.insetBy(dx: -2, dy: -2).contains(textCenter),
               frame.width >= textFrame.width + 40,
               frame.height >= textFrame.height,
               frame.height <= max(textFrame.height * 4, 96) {
                return frame
            }

            current = parent
        }

        return nil
    }

    func screenshotToGlobalPoint(snapshot: AppSnapshot, x: Double, y: Double) throws -> CGPoint {
        try windowPointToGlobalPoint(
            snapshot: snapshot,
            point: screenshotPixelToWindowPointInSnapshot(
                snapshot: snapshot,
                point: CGPoint(x: x, y: y)
            )
        )
    }

    func screenshotPixelToWindowPointInSnapshot(snapshot: AppSnapshot, point: CGPoint) -> CGPoint {
        screenshotPixelToWindowPoint(
            point,
            screenshotPixelSize: screenshotPixelSize(snapshot: snapshot),
            windowBounds: snapshot.windowBounds
        )
    }

    func screenshotPixelSize(snapshot: AppSnapshot) -> CGSize? {
        guard
            let screenshotPNGData = snapshot.screenshotPNGData,
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

    func screenPixelToGlobalPoint(screen: ScreenSnapshot, point: CGPoint) -> CGPoint {
        guard let pixelSize = screen.screenshotPixelSize,
              pixelSize.width > 0, pixelSize.height > 0 else {
            return point
        }
        let scaleX = screen.displayBounds.width / pixelSize.width
        let scaleY = screen.displayBounds.height / pixelSize.height
        return CGPoint(
            x: screen.displayBounds.minX + point.x * scaleX,
            y: screen.displayBounds.minY + point.y * scaleY
        )
    }

    func windowPointToGlobalPoint(snapshot: AppSnapshot, point: CGPoint) throws -> CGPoint {
        guard let windowBounds = snapshot.windowBounds else {
            let appReference = snapshot.app.bundleIdentifier ?? snapshot.app.name
            throw ComputerUseError.stateUnavailable("No window bounds are available for \(appReference). Run get_app_state after bringing the app on screen.")
        }

        return CGPoint(x: windowBounds.minX + point.x, y: windowBounds.minY + point.y)
    }

    // MARK: - Visual cursor helpers

    func visualCursorTarget(for record: ElementRecord, snapshot: AppSnapshot) -> VisualCursorTarget? {
        makeVisualCursorTarget(
            localFrame: record.localFrame,
            windowBounds: snapshot.windowBounds,
            targetWindowID: snapshot.targetWindowID,
            targetWindowLayer: snapshot.targetWindowLayer
        )
    }

    func moveVisualCursor(to target: VisualCursorTarget?) {
        guard VisualCursorSupport.isEnabled else { return }
        guard let target else { return }

        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.moveCursor(to: target.point, in: target.window)
        }
    }

    func settleVisualCursor(at target: VisualCursorTarget?) {
        guard VisualCursorSupport.isEnabled else { return }
        guard let target else { return }

        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.settle(at: target.point, in: target.window)
        }
    }

    func pulseVisualCursor(at target: VisualCursorTarget?, clickCount: Int, mouseButton: MouseButtonKind) {
        guard VisualCursorSupport.isEnabled else { return }
        guard let target else { return }

        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.pulseClick(
                at: target.point,
                clickCount: clickCount,
                mouseButton: mouseButton,
                in: target.window
            )
        }
    }

    // MARK: - Result formatting

    func snapshotResult(
        for snapshot: AppSnapshot,
        style: SnapshotTextStyle,
        actionSummary: String? = nil,
        actionMetadata: [String: String]? = nil
    ) -> ToolCallResult {
        var text = snapshot.renderedText(style: style)
        if let actionSummary {
            text = actionSummary + "\n\n" + text
        }
        if snapshot.screenRecordingDenied {
            text += "\n\n[Warning: Screen Recording permission not granted — no screenshot available. Open System Settings → Privacy & Security → Screen Recording to enable.]"
        }
        var content = [ToolResultContentItem.text(text)]
        if let screenshotPNGData = snapshot.screenshotPNGData {
            content.append(.pngImage(screenshotPNGData))
        }
        return ToolCallResult(
            content: content,
            structuredContent: snapshotStructuredContent(snapshot, actionMetadata: actionMetadata)
        )
    }

    func actionObservationResult(
        before beforeSnapshot: AppSnapshot,
        after afterSnapshot: AppSnapshot,
        actionSummary: String,
        actionMetadata: [String: String]? = nil
    ) -> ToolCallResult {
        guard actionDiffEnabled else {
            return snapshotResult(
                for: afterSnapshot,
                style: .actionResult,
                actionSummary: actionSummary,
                actionMetadata: actionMetadata
            )
        }
        let fullText = afterSnapshot.renderedText(style: .actionResult)
        let diff = AXSnapshotDiff.makeDiff(
            before: beforeSnapshot,
            after: afterSnapshot,
            actionSummary: actionSummary,
            fullText: fullText
        )
        if diff.shouldUseDiff, let diffText = diff.text {
            var text = actionSummary + "\n\n" + diffText
            if afterSnapshot.screenRecordingDenied {
                text += "\n\n[Warning: Screen Recording permission not granted — no screenshot available. Open System Settings → Privacy & Security → Screen Recording to enable.]"
            }
            var content = [ToolResultContentItem.text(text)]
            if let screenshotPNGData = afterSnapshot.screenshotPNGData {
                content.append(.pngImage(screenshotPNGData))
            }
            return ToolCallResult(
                content: content,
                structuredContent: snapshotStructuredContent(afterSnapshot, actionMetadata: actionMetadata)
            )
        }
        return snapshotResult(
            for: afterSnapshot,
            style: .actionResult,
            actionSummary: actionSummary,
            actionMetadata: actionMetadata
        )
    }

    private func snapshotStructuredContent(
        _ snapshot: AppSnapshot,
        actionMetadata: [String: String]? = nil
    ) -> [String: Any] {
        let optionalValues: [(String, Any?)] = [
            ("bundle_id", snapshot.app.bundleIdentifier),
            ("window_id", snapshot.targetWindowID),
            ("window_title", snapshot.windowTitle),
        ]
        let optionalState = Dictionary(
            uniqueKeysWithValues: optionalValues.compactMap { key, value in
                value.map { (key, $0) }
            }
        )
        let state: [String: Any] = [
            "snapshot_id": snapshot.snapshotID,
            "app": snapshot.app.name,
            "pid": snapshot.app.pid,
        ].merging(optionalState) { current, _ in current }
        let actionContent: [String: Any] = actionMetadata.map { ["action": $0] } ?? [:]
        return ["state": state].merging(actionContent) { current, _ in current }
    }

    func elementSummary(for record: ElementRecord) -> String {
        var parts = "[\(record.index)] \(record.role ?? "AXUnknown")"
        if let text = record.displayText, !text.isEmpty {
            let truncated = text.count > 60 ? String(text.prefix(57)) + "..." : text
            parts += " \"\(truncated)\""
        }
        return parts
    }

    func matchingAction(requested: String, record: ElementRecord) -> String? {
        if let exact = record.rawActions.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
            return exact
        }

        if let pretty = zip(record.rawActions, record.prettyActions).first(where: { $0.1.caseInsensitiveCompare(requested) == .orderedSame }) {
            return pretty.0
        }

        return nil
    }

    func invalidSecondaryActionMessage(action: String, record: ElementRecord) -> String {
        invalidSecondaryActionErrorMessage(action: action, elementIndex: record.index)
    }

    func debugInputFallback(tool: String, targetDescription: String, snapshot: AppSnapshot) {
        guard inputFallbackDebugEnabled(environment: ProcessInfo.processInfo.environment) else { return }
        let appReference = snapshot.app.bundleIdentifier ?? snapshot.app.name
        fputs(
            "[accio-computer-use] global pointer fallback tool=\(tool) app=\(appReference) target=\(targetDescription)\n",
            stderr
        )
    }
}
