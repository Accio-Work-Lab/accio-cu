import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: - Key intent detection

enum PressKeyIntent {
    case selectAll
    case rawKey
}

func detectKeyIntent(_ parsed: ParsedKeyPress) -> PressKeyIntent {
    let hasCommand = parsed.modifiers.contains { $0.flag == .maskCommand }
    let onlyCommand = parsed.modifiers.count == 1 && hasCommand

    if onlyCommand && parsed.keyCode == CGKeyCode(kVK_ANSI_A) {
        return .selectAll
    }
    return .rawKey
}

// MARK: - Semantic AX routes

extension ComputerUseService {

    /// Attempt semantic Cmd+A: select all text in the focused element via AX
    /// by setting AXSelectedTextRange to cover the full value length.
    func attemptSemanticSelectAll(snapshot: AppSnapshot) -> Bool {
        let pid = snapshot.app.pid

        guard let focused = focusedElement(pid: pid) else {
            return false
        }

        let role = stringValue(of: focused, attribute: kAXRoleAttribute) ?? ""
        guard isTextEntryRole(role) else {
            return false
        }

        // Read the current value length
        guard let value = stringValue(of: focused, attribute: kAXValueAttribute as String) else {
            return false
        }

        let length = value.utf16.count

        // Check if AXSelectedTextRange is settable
        guard isSettable(element: focused, attribute: kAXSelectedTextRangeAttribute as String) else {
            return false
        }

        // Set selection to (0, length) to select all
        var range = CFRange(location: 0, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            return false
        }

        guard !AutomationPauseStore.shared.isPaused else { return false }
        let result = AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )

        return result == .success
    }

    // MARK: - Private helpers

    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return nil
        }
        return (focusedRef as! AXUIElement)
    }

    private func isTextEntryRole(_ role: String) -> Bool {
        role == kAXTextFieldRole as String
            || role == "AXTextArea"
            || role == "AXTextView"
            || role == kAXComboBoxRole as String
            || role == "AXSearchField"
    }

}
