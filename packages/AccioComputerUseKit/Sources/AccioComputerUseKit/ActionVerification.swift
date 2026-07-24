import ApplicationServices
import Foundation

// MARK: - Change level

public enum ChangeLevel: String {
    case confirmed       // value-level or structural change confirmed
    case structureOnly   // AX tree structure changed but can't confirm semantic change
    case unverifiable    // action delivered but AX can't confirm (e.g. WebKit contenteditable)
    case none            // no detectable change
}

// MARK: - Action verification

struct ActionPreState {
    let focusedElementRole: String?
    let focusedElementValue: String?
    let focusedElementIdentifier: String?
    let focusedElementIndex: Int?
    let targetElementValue: String?
    let structuralFingerprint: Int
    let timestamp: Date

    var focusedDescription: String {
        var parts: [String] = []
        if let focusedElementIndex {
            parts.append("[\(focusedElementIndex)]")
        }
        if let focusedElementRole {
            parts.append(focusedElementRole)
        }
        if let focusedElementIdentifier, !focusedElementIdentifier.isEmpty {
            parts.append("#\(focusedElementIdentifier)")
        }
        return parts.isEmpty ? "none" : parts.joined()
    }

    init(pid: pid_t, fingerprint: Int, snapshot: AppSnapshot? = nil, targetElement: AXUIElement? = nil) {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focusedRef {
            let focused = focusedRef as! AXUIElement
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleRef) == .success {
                focusedElementRole = roleRef as? String
            } else {
                focusedElementRole = nil
            }
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success {
                focusedElementValue = valueRef as? String
            } else {
                focusedElementValue = nil
            }
            var idRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXIdentifierAttribute as CFString, &idRef) == .success {
                focusedElementIdentifier = idRef as? String
            } else {
                focusedElementIdentifier = nil
            }
            focusedElementIndex = snapshot?.elements.values.first(where: { record in
                guard let element = record.element else { return false }
                return CFEqual(element, focused)
            })?.index
        } else {
            focusedElementRole = nil
            focusedElementValue = nil
            focusedElementIdentifier = nil
            focusedElementIndex = nil
        }

        if let targetElement {
            var targetValueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(targetElement, kAXValueAttribute as CFString, &targetValueRef) == .success {
                targetElementValue = targetValueRef as? String
            } else {
                targetElementValue = nil
            }
        } else {
            targetElementValue = nil
        }

        structuralFingerprint = fingerprint
        timestamp = Date()
    }
}

struct ActionResultSummary {
    let tool: String
    let target: String?
    let route: String
    let changeLevel: ChangeLevel
    let focusedBefore: String
    let focusedAfter: String
    let consecutiveNoChange: Int?

    var renderedLine: String {
        var fields = [
            "tool=\(tool)",
            "route=\(route)",
            "changed=\(changeLevel.rawValue)",
            "focused_before=\(focusedBefore)",
            "focused_after=\(focusedAfter)",
        ]
        if let target, !target.isEmpty {
            fields.insert("target=\(target)", at: 1)
        }
        if let consecutiveNoChange, consecutiveNoChange >= 2 {
            fields.append("consecutive_no_change=\(consecutiveNoChange)")
        }
        return "[Result] " + fields.joined(separator: " ")
    }

    var structuredMetadata: [String: String] {
        [
            "tool": tool,
            "route": route,
            "changed": changeLevel.rawValue,
        ]
    }

    static func make(
        tool: String,
        target: String? = nil,
        route: String,
        preState: ActionPreState,
        postSnapshot: AppSnapshot,
        consecutiveNoChange: Int? = nil,
        changeLevelOverride: ChangeLevel? = nil
    ) -> ActionResultSummary {
        let postState = ActionPreState(
            pid: postSnapshot.app.pid,
            fingerprint: 0,
            snapshot: postSnapshot
        )
        let postFingerprint = structuralFingerprint(of: postSnapshot)
        let detectedLevel = determineChangeLevel(
            preState: preState,
            postFingerprint: postFingerprint,
            postState: postState,
            tool: tool
        )
        return ActionResultSummary(
            tool: tool,
            target: target,
            route: route,
            changeLevel: changeLevelOverride ?? detectedLevel,
            focusedBefore: preState.focusedDescription,
            focusedAfter: postState.focusedDescription,
            consecutiveNoChange: consecutiveNoChange
        )
    }

    static func line(
        tool: String,
        target: String? = nil,
        route: String,
        preState: ActionPreState,
        postSnapshot: AppSnapshot,
        consecutiveNoChange: Int? = nil
    ) -> String {
        make(
            tool: tool,
            target: target,
            route: route,
            preState: preState,
            postSnapshot: postSnapshot,
            consecutiveNoChange: consecutiveNoChange
        ).renderedLine
    }

    private static func determineChangeLevel(
        preState: ActionPreState,
        postFingerprint: Int,
        postState: ActionPreState,
        tool: String
    ) -> ChangeLevel {
        // Structural change is strong signal
        if preState.structuralFingerprint != postFingerprint {
            // Check if value also changed for confirmed
            if preState.targetElementValue != nil,
               postState.focusedElementValue != preState.targetElementValue {
                return .confirmed
            }
            if preState.focusedElementValue != postState.focusedElementValue {
                return .confirmed
            }
            return .structureOnly
        }

        // No structural change — check value-level changes
        if let preTargetValue = preState.targetElementValue,
           let postFocusedValue = postState.focusedElementValue,
           preTargetValue != postFocusedValue {
            return .confirmed
        }

        if preState.focusedElementValue != postState.focusedElementValue {
            return .confirmed
        }

        // Focus changed (different element identity)
        if preState.focusedElementRole != postState.focusedElementRole
            || preState.focusedElementIdentifier != postState.focusedElementIdentifier {
            return .confirmed
        }

        // For type_text and set_value in web content, AX may not reflect changes
        if tool == "type_text" || tool == "set_value" {
            if preState.focusedElementRole == "AXTextArea"
                || preState.focusedElementRole == "AXWebArea" {
                return .unverifiable
            }
        }

        return .none
    }

    private static func structuralFingerprint(of snapshot: AppSnapshot) -> Int {
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
}

enum ActionVerification {

    /// Verify a click action took effect by checking if focus or structure changed.
    static func verifyClick(
        preState: ActionPreState,
        pid: pid_t,
        postFingerprint: Int
    ) -> String? {
        if preState.structuralFingerprint != postFingerprint {
            return nil
        }

        let postState = ActionPreState(pid: pid, fingerprint: postFingerprint)

        // Value-level change detected
        if preState.focusedElementValue != postState.focusedElementValue {
            return nil
        }

        if preState.focusedElementRole != postState.focusedElementRole
            || preState.focusedElementIdentifier != postState.focusedElementIdentifier {
            return nil
        }

        return "⚠ Click may not have taken effect — no UI change detected. " +
            "The element might not be interactive, or the click may need a different approach."
    }

    /// Verify a type_text action by checking the focused element's value.
    static func verifyTypeText(
        preState: ActionPreState,
        expectedText: String,
        pid: pid_t
    ) -> String? {
        Thread.sleep(forTimeInterval: 0.08)

        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else {
            return nil
        }
        let focused = focusedRef as! AXUIElement

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
              let currentValue = valueRef as? String else {
            return nil
        }

        if currentValue.contains(expectedText) {
            return nil
        }

        for delay in [0.18, 0.32] {
            Thread.sleep(forTimeInterval: delay)
            var retryRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &retryRef) == .success,
               let retryValue = retryRef as? String,
               retryValue.contains(expectedText) {
                return nil
            }
        }

        let expectedSummary = redactedActionInputSummary(expectedText)
        return "⚠ Typed text may not have been entered — '\(expectedSummary)' not found in field value."
    }

    /// Verify a scroll action by checking if any descendant positions changed.
    static func verifyScroll(
        preState: ActionPreState,
        postFingerprint: Int
    ) -> String? {
        if preState.structuralFingerprint != postFingerprint {
            return nil
        }
        return "⚠ Scroll may not have taken effect — no visible content change detected."
    }
}
