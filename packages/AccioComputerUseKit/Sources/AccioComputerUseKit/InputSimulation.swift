import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum MouseButtonKind: String {
    case left, right, middle

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var downEvent: CGEventType {
        switch self {
        case .left: return .leftMouseDown
        case .right: return .rightMouseDown
        case .middle: return .otherMouseDown
        }
    }

    var upEvent: CGEventType {
        switch self {
        case .left: return .leftMouseUp
        case .right: return .rightMouseUp
        case .middle: return .otherMouseUp
        }
    }
}

enum InputSimulation {
    // MARK: - Background-safe targeted input (postToPid)

    static func clickTargeted(at point: CGPoint, button: MouseButtonKind, clickCount: Int, pid: pid_t, windowNumber: Int? = nil) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        // Use SkyLight-based transport when window number is known — this routes
        // events through WindowServer without stealing foreground focus.
        if let windowNumber {
            try BackgroundClickTransport.dispatch(BackgroundClickTransport.ClickRequest(
                point: point,
                button: button,
                clickCount: clickCount,
                pid: pid,
                windowNumber: windowNumber
            ))
            return
        }

        // Fallback: plain CGEvent.postToPid (no windowNumber available)
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ComputerUseError.message("Failed to create targeted event source.")
        }
        let eventNumbers = targetedClickEventNumberPlan(
            clickCount: clickCount,
            seed: syntheticMouseEventNumberSeed()
        )
        try postMouseEventToPid(type: .mouseMoved, source: source, point: point, button: button.cgButton, clickState: 0, eventNumber: eventNumbers.move, pid: pid)
        Thread.sleep(forTimeInterval: 0.05)
        for (offset, clickIndex) in (1...max(clickCount, 1)).enumerated() {
            let clickEventNumber = eventNumbers.clicks[offset]
            try postMouseEventToPid(type: button.downEvent, source: source, point: point, button: button.cgButton, clickState: clickIndex, eventNumber: clickEventNumber, pid: pid)
            Thread.sleep(forTimeInterval: 0.08)
            try postMouseEventToPid(type: button.upEvent, source: source, point: point, button: button.cgButton, clickState: clickIndex, eventNumber: clickEventNumber, pid: pid)
        }
    }

    static func clickGlobally(at point: CGPoint, button: MouseButtonKind, clickCount: Int) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create HID event source.")
        }
        let savedCursor = saveCursorPosition()
        // Warp cursor to target BEFORE dissociation — CEF/Chromium apps validate
        // that the system cursor position matches the event coordinates. Without
        // the warp, clicks are silently ignored by these apps.
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            CGAssociateMouseAndMouseCursorPosition(1)
            restoreCursorPosition(savedCursor)
        }
        for clickIndex in 1...max(clickCount, 1) {
            try postMouseEvent(type: .mouseMoved, source: source, point: point, button: button.cgButton, clickState: 0)
            Thread.sleep(forTimeInterval: 0.05)
            try postMouseEvent(type: button.downEvent, source: source, point: point, button: button.cgButton, clickState: clickIndex)
            try postMouseEvent(type: button.upEvent, source: source, point: point, button: button.cgButton, clickState: clickIndex)
        }
    }

    /// Click at a global screen coordinate without cursor dissociation or restore.
    /// Used for screen-level clicks where the cursor must stay at the target point
    /// long enough for the window server to process the event.
    static func clickAtScreenPoint(at point: CGPoint, button: MouseButtonKind, clickCount: Int) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create HID event source.")
        }
        CGWarpMouseCursorPosition(point)
        for clickIndex in 1...max(clickCount, 1) {
            try postMouseEvent(type: .mouseMoved, source: source, point: point, button: button.cgButton, clickState: 0)
            Thread.sleep(forTimeInterval: 0.05)
            try postMouseEvent(type: button.downEvent, source: source, point: point, button: button.cgButton, clickState: clickIndex)
            try postMouseEvent(type: button.upEvent, source: source, point: point, button: button.cgButton, clickState: clickIndex)
        }
    }

    static func hoverAtScreenPoint(at point: CGPoint) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create HID event source.")
        }
        CGWarpMouseCursorPosition(point)
        try postMouseEvent(
            type: .mouseMoved,
            source: source,
            point: point,
            button: .left,
            clickState: 0
        )
    }

    static func scrollTargeted(at point: CGPoint, direction: String, pages: Double, pid: pid_t, windowNumber: Int? = nil) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        // Prepare the window once before the scroll batch
        if let windowNumber {
            BackgroundScrollTransport.prepareForScroll(pid: pid, windowNumber: windowNumber)
        }

        // Send scroll in per-page increments for reliability — some apps cap
        // the delta they accept from a single wheel event.
        let fullPages = max(Int(pages), 0)
        let remainder = pages - Double(fullPages)

        for _ in 0..<max(fullPages, 0) {
            try postScrollWheel(at: point, direction: direction, lineDelta: 3, pid: pid, windowNumber: windowNumber)
        }

        if fullPages == 0 {
            let lines = max(Int((pages * 3).rounded()), 1)
            try postScrollWheel(at: point, direction: direction, lineDelta: Int32(lines), pid: pid, windowNumber: windowNumber)
        } else if remainder > 0.01 {
            let lines = Int((remainder * 3).rounded())
            if lines > 0 {
                try postScrollWheel(at: point, direction: direction, lineDelta: Int32(lines), pid: pid, windowNumber: windowNumber)
            }
        }
    }

    /// Scroll by posting to the global HID event tap. Required for Electron apps
    /// that ignore postToPid scroll events. The mouse cursor must be at the
    /// target position for macOS to route the scroll to the correct view.
    static func scrollGlobally(at point: CGPoint, direction: String, pages: Double) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        // Electron/Chromium apps cap per-event scroll delta, so we send
        // multiple small events instead of one large one.  Each "page" is
        // 3 events × 3 lines = 9~10 total lines, which produces ~80-100 px
        // of scroll in typical Electron list views.
        let linesPerPage: Double = 10
        let perEventDelta: Int32 = 3
        let totalLines = Int((pages * linesPerPage).rounded())
        let fullEvents = totalLines / Int(perEventDelta)
        let remainderLines = Int32(totalLines % Int(perEventDelta))

        let savedCursor = saveCursorPosition()
        // Warp cursor to target so WindowServer routes scroll to the correct window.
        // Must happen BEFORE dissociation — dissociation freezes cursor position.
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            CGAssociateMouseAndMouseCursorPosition(1)
            restoreCursorPosition(savedCursor)
        }

        for _ in 0..<fullEvents {
            try postScrollWheelGlobally(at: point, direction: direction, lineDelta: perEventDelta)
        }
        if remainderLines > 0 {
            try postScrollWheelGlobally(at: point, direction: direction, lineDelta: remainderLines)
        }

        // If nothing was sent (e.g. pages very small), send at least one event.
        if fullEvents == 0 && remainderLines == 0 {
            try postScrollWheelGlobally(at: point, direction: direction, lineDelta: 1)
        }
    }

    private static func postScrollWheelGlobally(at point: CGPoint, direction: String, lineDelta: Int32) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        let w1: Int32
        let w2: Int32
        switch direction {
        case "up":    w1 = lineDelta;  w2 = 0
        case "down":  w1 = -lineDelta; w2 = 0
        case "left":  w1 = 0; w2 = lineDelta
        case "right": w1 = 0; w2 = -lineDelta
        default:      w1 = 0; w2 = 0
        }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                                  wheel1: w1, wheel2: w2, wheel3: 0) else {
            throw ComputerUseError.message("Failed to create scroll event.")
        }
        event.location = point
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }

    private static func postScrollWheel(at point: CGPoint, direction: String, lineDelta: Int32, pid: pid_t, windowNumber: Int? = nil) throws {
        // Use enhanced transport with WindowServer routing when window is known
        if let windowNumber {
            try BackgroundScrollTransport.postScrollWheel(
                at: point,
                direction: direction,
                lineDelta: lineDelta,
                pid: pid,
                windowNumber: windowNumber
            )
            return
        }

        // Fallback: plain postToPid
        let source = CGEventSource(stateID: .combinedSessionState)
        let w1: Int32
        let w2: Int32
        switch direction {
        case "up":    w1 = lineDelta;  w2 = 0
        case "down":  w1 = -lineDelta; w2 = 0
        case "left":  w1 = 0; w2 = lineDelta
        case "right": w1 = 0; w2 = -lineDelta
        default:      w1 = 0; w2 = 0
        }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                                  wheel1: w1, wheel2: w2, wheel3: 0) else {
            throw ComputerUseError.message("Failed to create scroll event.")
        }
        event.location = point
        event.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.05)
    }

    /// Scroll via keyboard events (PageDown/PageUp/Arrow) posted to a specific
    /// pid. This fallback is background-safe because it never changes AX focus
    /// or posts to the global HID event tap.
    static func scrollViaKeyboard(direction: String, pages: Double, pid: pid_t) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        let fullPages = max(Int(pages), 0)
        let remainder = pages - Double(fullPages)

        let pageKeyCode: CGKeyCode
        let lineKeyCode: CGKeyCode

        switch direction {
        case "down":
            pageKeyCode = 0x79  // kVK_PageDown
            lineKeyCode = 0x7D  // kVK_DownArrow
        case "up":
            pageKeyCode = 0x74  // kVK_PageUp
            lineKeyCode = 0x7E  // kVK_UpArrow
        case "left":
            pageKeyCode = 0x7B  // kVK_LeftArrow (no PageLeft on macOS)
            lineKeyCode = 0x7B
        case "right":
            pageKeyCode = 0x7C  // kVK_RightArrow
            lineKeyCode = 0x7C
        default:
            return
        }

        for _ in 0..<fullPages {
            try postKeyToPid(keyCode: pageKeyCode, pid: pid)
        }

        let lineCount: Int
        if fullPages == 0 {
            // No full pages: convert the entire fractional amount to line presses.
            lineCount = max(Int((pages * 3).rounded()), 1)
        } else {
            lineCount = Int((remainder * 3).rounded())
        }
        for _ in 0..<lineCount {
            try postKeyToPid(keyCode: lineKeyCode, pid: pid)
        }
    }

    private static func postKeyToPid(keyCode: CGKeyCode, pid: pid_t) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw ComputerUseError.message("Failed to create keyboard event for scroll.")
        }
        down.postToPid(pid)
        up.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.04)
    }

    static func dragTargeted(from start: CGPoint, to end: CGPoint, pid: pid_t, windowNumber: Int? = nil) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        // Use BackgroundDragTransport for full SkyLight routing (NSEvent-backed,
        // window-local coordinates, all routing fields) — required for Electron/Chrome.
        if let windowNumber {
            do {
                try BackgroundDragTransport.dispatch(BackgroundDragTransport.DragRequest(
                    from: start, to: end, pid: pid, windowNumber: windowNumber, steps: 10
                ))
                return
            } catch {
                // Fall through to postToPid fallback
            }
        }

        // Fallback: plain postToPid (native apps without windowNumber)
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ComputerUseError.message("Failed to create targeted event source.")
        }
        try postMouseEventToPid(type: .mouseMoved, source: source, point: start, button: .left, clickState: 0, pid: pid)
        try postMouseEventToPid(type: .leftMouseDown, source: source, point: start, button: .left, clickState: 1, pid: pid)
        Thread.sleep(forTimeInterval: 0.05)
        for step in 1...10 {
            let progress = CGFloat(step) / 10
            let point = CGPoint(x: start.x + ((end.x - start.x) * progress), y: start.y + ((end.y - start.y) * progress))
            try postMouseEventToPid(type: .leftMouseDragged, source: source, point: point, button: .left, clickState: 1, pid: pid)
        }
        Thread.sleep(forTimeInterval: 0.02)
        try postMouseEventToPid(type: .leftMouseUp, source: source, point: end, button: .left, clickState: 1, pid: pid)
    }

    /// Drag at global screen coordinates without cursor dissociation or restore.
    /// Used for screen-level drags (no app parameter) where the cursor must stay
    /// at the target points long enough for the window server to process events.
    static func dragAtScreenPoint(from start: CGPoint, to end: CGPoint) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create HID event source.")
        }
        CGWarpMouseCursorPosition(start)
        try postMouseEvent(type: .mouseMoved, source: source, point: start, button: .left, clickState: 0)
        Thread.sleep(forTimeInterval: 0.05)
        try postMouseEvent(type: .leftMouseDown, source: source, point: start, button: .left, clickState: 1)
        Thread.sleep(forTimeInterval: 0.05)
        for step in 1...10 {
            let progress = CGFloat(step) / 10
            let point = CGPoint(x: start.x + ((end.x - start.x) * progress), y: start.y + ((end.y - start.y) * progress))
            CGWarpMouseCursorPosition(point)
            try postMouseEvent(type: .leftMouseDragged, source: source, point: point, button: .left, clickState: 1)
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.02)
        try postMouseEvent(type: .leftMouseUp, source: source, point: end, button: .left, clickState: 1)
    }

    static func dragGlobally(from start: CGPoint, to end: CGPoint) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create HID event source.")
        }
        let savedCursor = saveCursorPosition()
        CGAssociateMouseAndMouseCursorPosition(0)
        defer {
            CGAssociateMouseAndMouseCursorPosition(1)
            restoreCursorPosition(savedCursor)
        }
        try postMouseEvent(type: .mouseMoved, source: source, point: start, button: .left, clickState: 0)
        try postMouseEvent(type: .leftMouseDown, source: source, point: start, button: .left, clickState: 1)
        Thread.sleep(forTimeInterval: 0.05)
        for step in 1...10 {
            let progress = CGFloat(step) / 10
            let point = CGPoint(x: start.x + ((end.x - start.x) * progress), y: start.y + ((end.y - start.y) * progress))
            try postMouseEvent(type: .leftMouseDragged, source: source, point: point, button: .left, clickState: 1)
        }
        Thread.sleep(forTimeInterval: 0.02)
        try postMouseEvent(type: .leftMouseUp, source: source, point: end, button: .left, clickState: 1)
    }

    static func typeText(_ text: String, pid: pid_t) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ComputerUseError.message("Failed to create event source for typing.")
        }
        for character in text.utf16 {
            try AutomationPolicy().authorizeToolCall(named: "input")
            var mutableCharacter = character
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw ComputerUseError.message("Failed to create keyboard event.")
            }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &mutableCharacter)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &mutableCharacter)
            down.postToPid(pid)
            up.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Type text via HID event tap — posts to the system event stream.
    /// Required for Qt/Electron/Flutter apps that ignore postToPid when active.
    /// Uses .hidSystemState to avoid Chinese IME composing state contamination.
    static func typeTextGlobally(_ text: String, expectedPID: pid_t) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create event source for global typing.")
        }
        for character in text.utf16 {
            try AutomationPolicy().authorizeToolCall(named: "input")
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else {
                throw ComputerUseError.message(
                    "Global typing stopped because the target app lost focus."
                )
            }
            var mutableCharacter = character
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw ComputerUseError.message("Failed to create keyboard event.")
            }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &mutableCharacter)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &mutableCharacter)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    static func pressKey(_ specification: String, pid: pid_t, windowNumber: Int? = nil) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        let parsed = try KeyPressParser.parse(specification)

        // When we have a windowNumber, use SkyLight-based transport with key-window
        // records for reliable background delivery. This sends modifier down/up
        // events through the same SkyLight pipeline.
        if let windowNumber {
            try pressKeyViaSkyLight(parsed: parsed, pid: pid, windowNumber: windowNumber)
            return
        }

        // Fallback: plain CGEvent.postToPid
        // Use .hidSystemState to avoid Chinese IME composing state contamination.
        // .combinedSessionState carries leftover IME flags that can cause modifier
        // shortcuts (Cmd+V, Cmd+C, etc.) to be misinterpreted when an input method
        // is active.
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create event source for key press.")
        }
        var activeFlags: CGEventFlags = []

        for modifier in parsed.modifiers {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.keyCode, keyDown: true) else {
                throw ComputerUseError.message("Failed to create modifier key down event.")
            }
            activeFlags.insert(modifier.flag)
            event.flags = activeFlags
            event.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.02)
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: parsed.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: parsed.keyCode, keyDown: false) else {
            throw ComputerUseError.message("Failed to create key event.")
        }
        keyDown.flags = activeFlags
        keyUp.flags = activeFlags
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)

        for modifier in parsed.modifiers.reversed() {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.keyCode, keyDown: false) else {
                throw ComputerUseError.message("Failed to create modifier key up event.")
            }
            activeFlags.remove(modifier.flag)
            event.flags = activeFlags
            event.postToPid(pid)
        }

        Thread.sleep(forTimeInterval: 0.1)
    }

    private static func pressKeyViaSkyLight(parsed: ParsedKeyPress, pid: pid_t, windowNumber: Int) throws {
        let target = BackgroundKeyTransport.KeyTarget(pid: pid, windowNumber: windowNumber)
        let sender = BackgroundKeyTransport.prepareSender(for: target)

        // Send modifier key-down events with accumulated flags
        var activeFlags: CGEventFlags = []
        for modifier in parsed.modifiers {
            activeFlags.insert(modifier.flag)
            try sender.postKeyDown(keyCode: modifier.keyCode, flags: activeFlags)
            usleep(20_000)
        }

        // Send the main key down+up with all modifiers held
        try sender.postKeyDown(keyCode: parsed.keyCode, flags: activeFlags)
        usleep(30_000)
        try sender.postKeyUp(keyCode: parsed.keyCode, flags: activeFlags)

        // Release modifiers in reverse order with decreasing flags
        for modifier in parsed.modifiers.reversed() {
            activeFlags.remove(modifier.flag)
            try sender.postKeyUp(keyCode: modifier.keyCode, flags: activeFlags)
            usleep(10_000)
        }

        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Post a key press via the HID system event tap, targeted to a specific PID.
    /// Electron/Qt/Flutter apps require HID tap delivery (postToPid is silently
    /// ignored by their event loops). The caller MUST activate the app first.
    /// This method verifies the target is still frontmost before posting, and
    /// re-activates if another app stole focus during the operation.
    static func pressKeyGlobally(_ specification: String, pid: pid_t, appName: String? = nil) throws {
        try AutomationPolicy().authorizeToolCall(named: "input")
        let parsed = try KeyPressParser.parse(specification)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create event source for key press.")
        }

        // Verify target app is frontmost before posting. If not, re-activate.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            if let app = NSRunningApplication(processIdentifier: pid) {
                try ActivationToastBridge.confirmIfNeeded(
                    for: pid,
                    appName: appName ?? app.localizedName ?? "target app",
                    reason: .keyboard
                )
                app.activate()
                Thread.sleep(forTimeInterval: 0.15)
            }
        }

        var activeFlags: CGEventFlags = []

        for modifier in parsed.modifiers {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.keyCode, keyDown: true) else {
                throw ComputerUseError.message("Failed to create modifier key down event.")
            }
            activeFlags.insert(modifier.flag)
            event.flags = activeFlags
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: parsed.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: parsed.keyCode, keyDown: false) else {
            throw ComputerUseError.message("Failed to create key event.")
        }
        keyDown.flags = activeFlags
        keyUp.flags = activeFlags
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        keyUp.post(tap: .cghidEventTap)

        for modifier in parsed.modifiers.reversed() {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: modifier.keyCode, keyDown: false) else {
                throw ComputerUseError.message("Failed to create modifier key up event.")
            }
            activeFlags.remove(modifier.flag)
            event.flags = activeFlags
            event.post(tap: .cghidEventTap)
        }

        Thread.sleep(forTimeInterval: 0.1)
    }

    // MARK: - Window raising

    /// Lightweight window raise via AX — brings the target window to the front
    /// so that subsequent postToPid mouse events are processed by Electron/Chromium.
    @discardableResult
    static func raiseTargetWindow(pid: pid_t) -> Bool {
        let raised = raiseAppWindowViaAccessibility(pid: pid)
        if raised {
            // Electron/Chromium apps need extra settle time after AXRaise
            // before they reliably process postToPid mouse events.
            Thread.sleep(forTimeInterval: 0.25)
        }
        return raised
    }

    /// Unminimize and raise a window for the given PID.
    /// Electron apps (DingTalk) auto-minimize when deactivated. Call this after
    /// activating the user's original app to counter the minimize side-effect.
    static func unminimizeAndRaiseTargetWindow(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        guard let window = preferredWindow(for: appElement)
            ?? copyArray(appElement, attribute: kAXWindowsAttribute)?.first else {
            return
        }

        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           (minimizedRef as? Bool) == true
        {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            Thread.sleep(forTimeInterval: 0.15)
        }

        _ = performAction(named: kAXRaiseAction as String, on: window)
        Thread.sleep(forTimeInterval: 0.1)
    }

    static func prepareAppForGlobalPointerInput(
        _ app: RunningAppDescriptor,
        reason: ForegroundActivationReason
    ) throws {
        try ActivationToastBridge.confirmIfNeeded(for: app.pid, appName: app.name, reason: reason)

        // AXRaise reorders the window to the front but doesn't make the app
        // frontmost. HID-tap events route to the frontmost app, so we must
        // always activate. AXRaise first ensures the correct window is on top
        // before activation makes it the input target.
        _ = raiseAppWindowViaAccessibility(pid: app.pid)
        _ = app.runningApplication.activate()
        Thread.sleep(forTimeInterval: 0.25)
    }

    // MARK: - Cursor position save/restore

    static func saveCursorPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func restoreCursorPosition(_ position: CGPoint) {
        CGWarpMouseCursorPosition(position)
        // Re-sync cursor association so next physical mouse movement is smooth
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: - Private helpers

    private static func postMouseEvent(type: CGEventType, source: CGEventSource, point: CGPoint, button: CGMouseButton, clickState: Int) throws {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ComputerUseError.message("Failed to create mouse event \(type.rawValue).")
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }

    private static func postMouseEventToPid(type: CGEventType, source: CGEventSource, point: CGPoint, button: CGMouseButton, clickState: Int, eventNumber: Int? = nil, pid: pid_t) throws {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ComputerUseError.message("Failed to create mouse event \(type.rawValue).")
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        if let eventNumber {
            event.setIntegerValueField(.mouseEventNumber, value: Int64(eventNumber))
        }
        event.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)
    }

    private static func raiseAppWindowViaAccessibility(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        guard let window = preferredWindow(for: appElement) else { return false }

        // Only use AXRaise — it reorders windows without activating the app.
        // Setting kAXMainAttribute or kAXFocusedAttribute would activate the
        // app, stealing the foreground from the user's current workspace.
        return performAction(named: kAXRaiseAction as String, on: window)
    }

    private static func preferredWindow(for appElement: AXUIElement) -> AXUIElement? {
        copyElement(appElement, attribute: kAXFocusedWindowAttribute)
            ?? copyArray(appElement, attribute: kAXWindowsAttribute)?.first
    }

    private static func performAction(named action: String, on element: AXUIElement) -> Bool {
        guard availableActions(for: element).contains(where: { $0.caseInsensitiveCompare(action) == .orderedSame }) else { return false }
        return AXUIElementPerformAction(element, action as CFString) == .success
    }

    private static func setBoolAttribute(named attribute: String, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        guard result == .success, settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue) == .success
    }

    private static func availableActions(for element: AXUIElement) -> [String] {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success, let actions else { return [] }
        return actions as? [String] ?? []
    }

    private static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyArray(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        return value as? [AXUIElement]
    }

}
