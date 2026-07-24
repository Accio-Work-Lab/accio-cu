import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// MARK: - SkyLight Private Framework Symbols

/// Dynamically loads symbols from SkyLight.framework for background event dispatch.
/// SkyLight provides lower-level WindowServer access than the public CGEvent API,
/// enabling true background click/scroll without stealing foreground focus.
enum SkyLightSymbols {
    static let isAvailable: Bool = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) != nil
    }()

    // Event posting — replaces CGEvent.postToPid with WindowServer-native routing
    static let slEventPostToPid: SLEventPostToPidFn? = loadOptional("SLEventPostToPid")
    static let slEventSetIntegerValueField: SLEventSetIntegerValueFieldFn? = loadOptional("SLEventSetIntegerValueField")
    static let cgEventSetWindowLocation: CGEventSetWindowLocationFn? = loadOptional("CGEventSetWindowLocation")

    // WindowServer connection and routing resolution
    static let cgsMainConnectionID: CGSMainConnectionIDFn? = loadOptional("CGSMainConnectionID")
    static let cgsGetWindowOwner: CGSGetWindowOwnerFn? = loadOptional("CGSGetWindowOwner")
    static let cgsGetConnectionPSN: CGSGetConnectionPSNFn? = loadOptional("CGSGetConnectionPSN")

    // Focus preparation — sends binary event records to WindowServer
    static let getProcessForPID: GetProcessForPIDFn? = loadOptional("GetProcessForPID")
    static let slpsPostEventRecordTo: SLPSPostEventRecordToFn? = loadOptional("SLPSPostEventRecordTo")

    private static func loadOptional<T>(_ name: String) -> T? {
        guard isAvailable else { return nil }
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

// MARK: - Function type aliases

typealias SLEventPostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
typealias SLEventSetIntegerValueFieldFn = @convention(c) (CGEvent, UInt32, Int64) -> Void
typealias CGEventSetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
typealias CGSGetWindowOwnerFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>?) -> Int32
typealias CGSGetConnectionPSNFn = @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>?) -> Int32
typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
typealias SLPSPostEventRecordToFn = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32

// MARK: - WindowServer Routing Info

struct WindowServerRouting {
    let ownerConnection: Int32
    let processSerialNumberHigh: UInt32
    let processSerialNumberLow: UInt32
    let packedPSN: Int64
    let cgBoundsTopLeft: CGRect?
}

enum WindowServerRoutingResolver {
    static func resolve(windowNumber: Int) -> WindowServerRouting? {
        guard let cgsMainConnectionID = SkyLightSymbols.cgsMainConnectionID,
              let cgsGetWindowOwner = SkyLightSymbols.cgsGetWindowOwner,
              let cgsGetConnectionPSN = SkyLightSymbols.cgsGetConnectionPSN else {
            return nil
        }

        var ownerConnection: Int32 = 0
        let ownerStatus = cgsGetWindowOwner(
            cgsMainConnectionID(),
            UInt32(windowNumber),
            &ownerConnection
        )
        guard ownerStatus == 0 else { return nil }

        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        let psnStatus = cgsGetConnectionPSN(ownerConnection, &psn)
        guard psnStatus == 0 else { return nil }

        let packed = (Int64(psn.highLongOfPSN) << 32) | Int64(psn.lowLongOfPSN)
        let cgBounds = cgBoundsTopLeft(windowNumber: windowNumber)

        return WindowServerRouting(
            ownerConnection: ownerConnection,
            processSerialNumberHigh: psn.highLongOfPSN,
            processSerialNumberLow: psn.lowLongOfPSN,
            packedPSN: packed,
            cgBoundsTopLeft: cgBounds
        )
    }

    private static func cgBoundsTopLeft(windowNumber: Int) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]],
              let entry = list.first,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        return CGRect(
            x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
            y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
            width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
            height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
        )
    }
}

// MARK: - WindowServer Focus Preparation

/// Sends a target-only focus record to the WindowServer so the target window
/// accepts input events without being raised to front or activating its app.
enum WindowServerPreparation {
    struct Result {
        let success: Bool
        let psnStatus: Int32
        let focusStatus: Int32
        let keyWindowStatuses: [Int32]

        var keyWindowReady: Bool {
            keyWindowStatuses.count == 2 && keyWindowStatuses.allSatisfy { $0 == 0 }
        }
    }

    /// Prepares a window for mouse input (target-only focus, no key-window records).
    static func prepareTargetForInput(pid: pid_t, windowNumber: Int) -> Result {
        prepare(pid: pid, windowNumber: windowNumber, includeKeyWindowRecords: false)
    }

    /// Prepares a window for keyboard input (target-only focus + key-window records).
    /// Key-window records tell the WindowServer to route keyboard events to the
    /// specified window without raising or activating its app.
    static func prepareTargetForKeyboardInput(pid: pid_t, windowNumber: Int) -> Result {
        prepare(pid: pid, windowNumber: windowNumber, includeKeyWindowRecords: true)
    }

    private static func prepare(
        pid: pid_t,
        windowNumber: Int,
        includeKeyWindowRecords: Bool
    ) -> Result {
        guard let getProcessForPID = SkyLightSymbols.getProcessForPID,
              let slpsPostEventRecordTo = SkyLightSymbols.slpsPostEventRecordTo else {
            return Result(success: false, psnStatus: -1, focusStatus: -1, keyWindowStatuses: [])
        }

        var targetPSN = [UInt32](repeating: 0, count: 2)
        let psnStatus = targetPSN.withUnsafeMutableBytes { raw in
            getProcessForPID(pid, raw.baseAddress!)
        }
        guard psnStatus == 0 else {
            return Result(success: false, psnStatus: psnStatus, focusStatus: -1, keyWindowStatuses: [])
        }

        let focusStatus = targetPSN.withUnsafeBytes { psnRaw in
            targetOnlyFocusRecord(windowNumber: windowNumber).withUnsafeBufferPointer { bytes in
                slpsPostEventRecordTo(psnRaw.baseAddress!, bytes.baseAddress!)
            }
        }

        let keyWindowStatuses: [Int32]
        if includeKeyWindowRecords {
            keyWindowStatuses = targetPSN.withUnsafeBytes { psnRaw in
                keyWindowRecords(windowNumber: windowNumber).map { record in
                    record.withUnsafeBufferPointer { bytes in
                        slpsPostEventRecordTo(psnRaw.baseAddress!, bytes.baseAddress!)
                    }
                }
            }
        } else {
            keyWindowStatuses = []
        }

        let focusOK = focusStatus == 0
        let keyOK = !includeKeyWindowRecords || (keyWindowStatuses.count == 2 && keyWindowStatuses.allSatisfy { $0 == 0 })
        return Result(success: focusOK && keyOK, psnStatus: psnStatus, focusStatus: focusStatus, keyWindowStatuses: keyWindowStatuses)
    }

    /// Builds a 248-byte binary record that tells the WindowServer to direct
    /// input focus to a specific window without raising or activating the app.
    private static func targetOnlyFocusRecord(windowNumber: Int) -> [UInt8] {
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8
        record[0x08] = 0x0D
        stampWindowNumber(windowNumber, into: &record, offset: 0x3C)
        record[0x8A] = 0x01
        return record
    }

    /// Builds two 256-byte key-window records (phases 0x01 and 0x02) that tell the
    /// WindowServer to route keyboard events to the specified window.
    /// Required for PressKey delivery to background windows.
    private static func keyWindowRecords(windowNumber: Int) -> [[UInt8]] {
        var template = [UInt8](repeating: 0, count: 0x100)
        template[0x04] = 0xF8
        template[0x3A] = 0x10
        for index in 0x20..<0x30 {
            template[index] = 0xFF
        }
        stampWindowNumber(windowNumber, into: &template, offset: 0x3C)
        return [UInt8(0x01), UInt8(0x02)].map { phase in
            var record = template
            record[0x08] = phase
            return record
        }
    }

    private static func stampWindowNumber(_ windowNumber: Int, into record: inout [UInt8], offset: Int) {
        let windowID = UInt32(windowNumber)
        record[offset] = UInt8(windowID & 0xFF)
        record[offset + 1] = UInt8((windowID >> 8) & 0xFF)
        record[offset + 2] = UInt8((windowID >> 16) & 0xFF)
        record[offset + 3] = UInt8((windowID >> 24) & 0xFF)
    }
}

// MARK: - Background Key Transport

/// Posts keyboard events to a background window using SkyLight's native event pipeline.
/// Sends key-window records first so the WindowServer routes keyboard events to the
/// target window without raising or activating its app.
/// Falls back to CGEvent.postToPid when SkyLight is unavailable.
enum BackgroundKeyTransport {
    struct KeyTarget {
        let pid: pid_t
        let windowNumber: Int
    }

    /// Prepares the target window for keyboard input (once per key combo),
    /// then returns a `Sender` that can dispatch individual keyDown / keyUp events.
    static func prepareSender(for target: KeyTarget) -> KeySender {
        if SkyLightSymbols.isAvailable, let slEventPostToPid = SkyLightSymbols.slEventPostToPid {
            let preparation = WindowServerPreparation.prepareTargetForKeyboardInput(
                pid: target.pid,
                windowNumber: target.windowNumber
            )
            if preparation.success {
                usleep(50_000)
            }

            if let source = CGEventSource(stateID: .hidSystemState) {
                return KeySender(target: target, source: source, slEventPostToPid: slEventPostToPid)
            }
        }
        // Fallback: postToPid sender
        let source = CGEventSource(stateID: .hidSystemState)
        return KeySender(target: target, source: source, slEventPostToPid: nil)
    }

    /// A prepared sender that can post individual keyDown/keyUp events to
    /// the target window without re-preparing on each call.
    struct KeySender {
        let target: KeyTarget
        let source: CGEventSource?
        let slEventPostToPid: SLEventPostToPidFn?

        var usesSkyLight: Bool { slEventPostToPid != nil }

        func postKeyDown(keyCode: CGKeyCode, flags: CGEventFlags) throws {
            try postKeyEvent(keyCode: keyCode, flags: flags, keyDown: true)
        }

        func postKeyUp(keyCode: CGKeyCode, flags: CGEventFlags) throws {
            try postKeyEvent(keyCode: keyCode, flags: flags, keyDown: false)
        }

        private func postKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags, keyDown: Bool) throws {
            guard let source else {
                throw ComputerUseError.message("Failed to create event source for key press.")
            }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                throw ComputerUseError.message("Failed to create keyboard event.")
            }
            event.flags = flags

            if let slEventPostToPid {
                stampKeyRoutingFields(event, target: target)
                event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                slEventPostToPid(target.pid, event)
            } else {
                event.postToPid(target.pid)
            }
        }

        private func stampKeyRoutingFields(_ event: CGEvent, target: KeyTarget) {
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(target.pid))
            SkyLightSymbols.slEventSetIntegerValueField?(event, 40, Int64(target.pid))
            SkyLightSymbols.slEventSetIntegerValueField?(event, 51, Int64(target.windowNumber))
            SkyLightSymbols.slEventSetIntegerValueField?(event, 91, Int64(target.windowNumber))
            SkyLightSymbols.slEventSetIntegerValueField?(event, 92, Int64(target.windowNumber))
        }
    }
}

// MARK: - Background Click Transport

/// Posts click events to a background window using SkyLight's native event pipeline.
/// Falls back to CGEvent.postToPid when SkyLight is unavailable.
enum BackgroundClickTransport {
    struct ClickRequest {
        let point: CGPoint
        let button: MouseButtonKind
        let clickCount: Int
        let pid: pid_t
        let windowNumber: Int
    }

    static func dispatch(_ request: ClickRequest) throws {
        // Attempt SkyLight-based transport first
        if SkyLightSymbols.isAvailable,
           let routing = WindowServerRoutingResolver.resolve(windowNumber: request.windowNumber) {
            try dispatchViaSkyLight(request, routing: routing)
        } else {
            // Fallback: plain CGEvent.postToPid (existing behavior)
            try dispatchViaPostToPid(request)
        }
    }

    private static func dispatchViaSkyLight(_ request: ClickRequest, routing: WindowServerRouting) throws {
        guard let slEventPostToPid = SkyLightSymbols.slEventPostToPid else {
            try dispatchViaPostToPid(request)
            return
        }

        let eventNumbers = targetedClickEventNumberPlan(
            clickCount: request.clickCount,
            seed: syntheticMouseEventNumberSeed()
        )

        // Step 1: Prepare the window for input (target-only focus without raise)
        let preparation = WindowServerPreparation.prepareTargetForInput(
            pid: request.pid,
            windowNumber: request.windowNumber
        )
        if preparation.success {
            usleep(50_000)
        }

        // Step 2: Compute window-local coordinates
        let windowLocal = windowLocalPoint(global: request.point, routing: routing)

        // Step 3: Send mouse-moved to warm up routing
        if let moveEvent = makeNSEventBackedCGEvent(
            type: .mouseMoved, point: request.point,
            windowLocal: windowLocal, clickState: 0,
            eventNumber: eventNumbers.move,
            request: request, routing: routing
        ) {
            moveEvent.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            slEventPostToPid(request.pid, moveEvent)
            usleep(50_000)
        }

        // Step 4: Primer events — offscreen down/up at (-1,-1) to reset
        // WindowServer click state machine before actual clicks
        let primer = CGPoint(x: -1, y: -1)
        if let primerDown = makeNSEventBackedCGEvent(
            type: request.button.downEvent, point: primer,
            windowLocal: primer, clickState: 1,
            eventNumber: eventNumbers.primer,
            request: request, routing: routing
        ), let primerUp = makeNSEventBackedCGEvent(
            type: request.button.upEvent, point: primer,
            windowLocal: primer, clickState: 1,
            eventNumber: eventNumbers.primer,
            request: request, routing: routing
        ) {
            primerDown.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            slEventPostToPid(request.pid, primerDown)
            usleep(30_000)
            primerUp.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            slEventPostToPid(request.pid, primerUp)
            usleep(30_000)
        }

        // Step 5: Actual click(s) with routing fields stamped
        for (offset, clickState) in (1...max(request.clickCount, 1)).enumerated() {
            let eventNumber = eventNumbers.clicks[offset]
            guard let down = makeNSEventBackedCGEvent(
                type: request.button.downEvent, point: request.point,
                windowLocal: windowLocal, clickState: Int64(clickState),
                eventNumber: eventNumber,
                request: request, routing: routing
            ) else {
                throw ComputerUseError.message("Failed to create stamped mouse-down event.")
            }
            down.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            slEventPostToPid(request.pid, down)
            usleep(80_000)

            guard let up = makeNSEventBackedCGEvent(
                type: request.button.upEvent, point: request.point,
                windowLocal: windowLocal, clickState: Int64(clickState),
                eventNumber: eventNumber,
                request: request, routing: routing
            ) else {
                throw ComputerUseError.message("Failed to create stamped mouse-up event.")
            }
            up.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            slEventPostToPid(request.pid, up)
            usleep(30_000)
        }
    }

    private static func dispatchViaPostToPid(_ request: ClickRequest) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ComputerUseError.message("Failed to create targeted event source.")
        }
        let eventNumbers = targetedClickEventNumberPlan(
            clickCount: request.clickCount,
            seed: syntheticMouseEventNumberSeed()
        )
        try postMouseEventToPid(type: .mouseMoved, source: source, point: request.point, button: request.button.cgButton, clickState: 0, eventNumber: eventNumbers.move, pid: request.pid)
        Thread.sleep(forTimeInterval: 0.05)
        for (offset, clickIndex) in (1...max(request.clickCount, 1)).enumerated() {
            let clickEventNumber = eventNumbers.clicks[offset]
            try postMouseEventToPid(type: request.button.downEvent, source: source, point: request.point, button: request.button.cgButton, clickState: clickIndex, eventNumber: clickEventNumber, pid: request.pid)
            Thread.sleep(forTimeInterval: 0.08)
            try postMouseEventToPid(type: request.button.upEvent, source: source, point: request.point, button: request.button.cgButton, clickState: clickIndex, eventNumber: clickEventNumber, pid: request.pid)
        }
    }

    // MARK: - Event Construction

    /// Creates a CGEvent via NSEvent→CGEvent bridge for proper WindowServer field
    /// population, then stamps routing fields for background delivery.
    /// NSEvent.mouseEvent populates internal fields that CGEvent(mouseEventSource:)
    /// leaves empty, improving compatibility with apps that validate event metadata.
    private static func makeNSEventBackedCGEvent(
        type: CGEventType,
        point: CGPoint,
        windowLocal: CGPoint,
        clickState: Int64,
        eventNumber: Int,
        request: ClickRequest,
        routing: WindowServerRouting
    ) -> CGEvent? {
        let nsType: NSEvent.EventType
        switch type {
        case .mouseMoved:       nsType = .mouseMoved
        case .leftMouseDown:    nsType = .leftMouseDown
        case .leftMouseUp:      nsType = .leftMouseUp
        case .rightMouseDown:   nsType = .rightMouseDown
        case .rightMouseUp:     nsType = .rightMouseUp
        case .otherMouseDown:   nsType = .otherMouseDown
        case .otherMouseUp:     nsType = .otherMouseUp
        default:                return nil
        }

        let isDown = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown)

        guard let nsEvent = NSEvent.mouseEvent(
            with: nsType,
            location: windowLocal,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: request.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: type == .mouseMoved ? 0 : max(1, Int(clickState)),
            pressure: isDown ? 1.0 : 0.0
        ), let event = nsEvent.cgEvent else {
            return nil
        }

        stampRoutingFields(event, type: type, point: point, windowLocal: windowLocal, request: request, routing: routing, clickState: clickState)
        return event
    }

    private static func stampRoutingFields(
        _ event: CGEvent,
        type: CGEventType,
        point: CGPoint,
        windowLocal: CGPoint,
        request: ClickRequest,
        routing: WindowServerRouting,
        clickState: Int64
    ) {
        event.location = point
        event.flags = []
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(request.pid))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(request.button.cgButton.rawValue))
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(request.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(request.windowNumber))
        event.setIntegerValueField(.eventTargetProcessSerialNumber, value: routing.packedPSN)

        // Stamp window-local coordinates via SkyLight
        SkyLightSymbols.cgEventSetWindowLocation?(event, windowLocal)

        // SkyLight-specific extended fields for precise routing
        setSkyLightField(event, field: 40, value: Int64(request.pid))
        setSkyLightField(event, field: 51, value: Int64(request.windowNumber))
        setSkyLightField(event, field: 52, value: Int64(routing.ownerConnection))
        setSkyLightField(event, field: 85, value: Int64(routing.ownerConnection))
        setSkyLightField(event, field: 91, value: Int64(request.windowNumber))
        setSkyLightField(event, field: 92, value: Int64(request.windowNumber))

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            setRawDouble(event, 2, 1.0)
            setRawInteger(event, 108, 1)
        }
        event.flags = []
    }

    private static func setSkyLightField(_ event: CGEvent, field: UInt32, value: Int64) {
        SkyLightSymbols.slEventSetIntegerValueField?(event, field, value)
        if let cgField = CGEventField(rawValue: field) {
            event.setIntegerValueField(cgField, value: value)
        }
    }

    private static func setRawInteger(_ event: CGEvent, _ rawField: UInt32, _ value: Int64) {
        guard let field = CGEventField(rawValue: rawField) else { return }
        event.setIntegerValueField(field, value: value)
    }

    private static func setRawDouble(_ event: CGEvent, _ rawField: UInt32, _ value: Double) {
        guard let field = CGEventField(rawValue: rawField) else { return }
        event.setDoubleValueField(field, value: value)
    }

    private static func windowLocalPoint(global: CGPoint, routing: WindowServerRouting) -> CGPoint {
        if let bounds = routing.cgBoundsTopLeft {
            return CGPoint(x: global.x - bounds.minX, y: global.y - bounds.minY)
        }
        return global
    }

    private static func postMouseEventToPid(type: CGEventType, source: CGEventSource, point: CGPoint, button: CGMouseButton, clickState: Int, eventNumber: Int, pid: pid_t) throws {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ComputerUseError.message("Failed to create mouse event \(type.rawValue).")
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.setIntegerValueField(.mouseEventNumber, value: Int64(eventNumber))
        event.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.03)
    }
}

// MARK: - Background Drag Transport

/// SkyLight-based drag event posting with full routing fields.
/// Uses the same NSEvent-backed approach as BackgroundClickTransport
/// so that Electron/Chrome apps receive proper window-local coordinates.
enum BackgroundDragTransport {
    struct DragRequest {
        let from: CGPoint
        let to: CGPoint
        let pid: pid_t
        let windowNumber: Int
        let steps: Int
    }

    static func dispatch(_ request: DragRequest) throws {
        guard SkyLightSymbols.isAvailable,
              let slEventPostToPid = SkyLightSymbols.slEventPostToPid,
              let routing = WindowServerRoutingResolver.resolve(windowNumber: request.windowNumber) else {
            throw ComputerUseError.message("SkyLight transport unavailable for drag.")
        }

        let preparation = WindowServerPreparation.prepareTargetForInput(
            pid: request.pid, windowNumber: request.windowNumber
        )
        if preparation.success { usleep(50_000) }

        // Step 1: mouseMoved warmup
        if let moveEvent = makeDragEvent(
            type: .mouseMoved, point: request.from,
            clickState: 0, request: request, routing: routing
        ) {
            moveEvent.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            slEventPostToPid(request.pid, moveEvent)
            usleep(50_000)
        }

        // Step 2: mouseDown at start
        guard let downEvent = makeDragEvent(
            type: .leftMouseDown, point: request.from,
            clickState: 1, request: request, routing: routing
        ) else {
            throw ComputerUseError.message("Failed to create drag mouseDown event.")
        }
        downEvent.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        slEventPostToPid(request.pid, downEvent)
        usleep(50_000)

        // Step 3: intermediate drag events
        let steps = max(request.steps, 1)
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: request.from.x + ((request.to.x - request.from.x) * progress),
                y: request.from.y + ((request.to.y - request.from.y) * progress)
            )
            if let dragEvent = makeDragEvent(
                type: .leftMouseDragged, point: point,
                clickState: 1, request: request, routing: routing
            ) {
                dragEvent.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                slEventPostToPid(request.pid, dragEvent)
                usleep(30_000)
            }
        }

        // Step 4: mouseUp at end
        usleep(20_000)
        guard let upEvent = makeDragEvent(
            type: .leftMouseUp, point: request.to,
            clickState: 1, request: request, routing: routing
        ) else {
            throw ComputerUseError.message("Failed to create drag mouseUp event.")
        }
        upEvent.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        slEventPostToPid(request.pid, upEvent)
    }

    private static func makeDragEvent(
        type: CGEventType,
        point: CGPoint,
        clickState: Int64,
        request: DragRequest,
        routing: WindowServerRouting
    ) -> CGEvent? {
        let nsType: NSEvent.EventType
        switch type {
        case .mouseMoved:        nsType = .mouseMoved
        case .leftMouseDown:     nsType = .leftMouseDown
        case .leftMouseUp:       nsType = .leftMouseUp
        case .leftMouseDragged:  nsType = .leftMouseDragged
        default:                 return nil
        }

        let isDown = (type == .leftMouseDown)
        let isDrag = (type == .leftMouseDragged)
        let windowLocal = windowLocalPoint(global: point, routing: routing)

        guard let nsEvent = NSEvent.mouseEvent(
            with: nsType,
            location: windowLocal,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: request.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: type == .mouseMoved ? 0 : 1,
            pressure: (isDown || isDrag) ? 1.0 : 0.0
        ), let event = nsEvent.cgEvent else {
            return nil
        }

        // Stamp all routing fields
        event.location = point
        event.flags = []
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(request.pid))
        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(request.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(request.windowNumber))
        event.setIntegerValueField(.eventTargetProcessSerialNumber, value: routing.packedPSN)

        SkyLightSymbols.cgEventSetWindowLocation?(event, windowLocal)

        setSkyLightField(event, field: 40, value: Int64(request.pid))
        setSkyLightField(event, field: 51, value: Int64(request.windowNumber))
        setSkyLightField(event, field: 52, value: Int64(routing.ownerConnection))
        setSkyLightField(event, field: 85, value: Int64(routing.ownerConnection))
        setSkyLightField(event, field: 91, value: Int64(request.windowNumber))
        setSkyLightField(event, field: 92, value: Int64(request.windowNumber))

        if isDown {
            setRawDouble(event, 2, 1.0)
            setRawInteger(event, 108, 1)
        }
        event.flags = []
        return event
    }

    private static func windowLocalPoint(global: CGPoint, routing: WindowServerRouting) -> CGPoint {
        if let bounds = routing.cgBoundsTopLeft {
            return CGPoint(x: global.x - bounds.minX, y: global.y - bounds.minY)
        }
        return global
    }

    private static func setSkyLightField(_ event: CGEvent, field: UInt32, value: Int64) {
        SkyLightSymbols.slEventSetIntegerValueField?(event, field, value)
        if let cgField = CGEventField(rawValue: field) {
            event.setIntegerValueField(cgField, value: value)
        }
    }

    private static func setRawInteger(_ event: CGEvent, _ rawField: UInt32, _ value: Int64) {
        guard let field = CGEventField(rawValue: rawField) else { return }
        event.setIntegerValueField(field, value: value)
    }

    private static func setRawDouble(_ event: CGEvent, _ rawField: UInt32, _ value: Double) {
        guard let field = CGEventField(rawValue: rawField) else { return }
        event.setDoubleValueField(field, value: value)
    }
}

// MARK: - Background Scroll Transport

/// Enhanced scroll event posting with WindowServer routing fields.
/// Stamps pid, window number, and SkyLight-specific fields so the event
/// is routed correctly even when the window is not frontmost.
enum BackgroundScrollTransport {
    /// Call once before a batch of scroll events to prepare the window.
    static func prepareForScroll(pid: pid_t, windowNumber: Int) {
        let preparation = WindowServerPreparation.prepareTargetForInput(
            pid: pid, windowNumber: windowNumber
        )
        if preparation.success {
            usleep(30_000)
        }
    }

    static func postScrollWheel(
        at point: CGPoint,
        direction: String,
        lineDelta: Int32,
        pid: pid_t,
        windowNumber: Int
    ) throws {
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

        // Stamp routing fields for background delivery
        applyScrollRoutingFields(event, pid: pid, windowNumber: windowNumber)

        if let slEventPostToPid = SkyLightSymbols.slEventPostToPid {
            event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            slEventPostToPid(pid, event)
        } else {
            event.postToPid(pid)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    private static func applyScrollRoutingFields(_ event: CGEvent, pid: pid_t, windowNumber: Int) {
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowNumber))
        // SkyLight routing fields
        if let cgField51 = CGEventField(rawValue: 51) {
            event.setIntegerValueField(cgField51, value: Int64(windowNumber))
        }
        if let cgField91 = CGEventField(rawValue: 91) {
            event.setIntegerValueField(cgField91, value: Int64(windowNumber))
        }
        if let cgField92 = CGEventField(rawValue: 92) {
            event.setIntegerValueField(cgField92, value: Int64(windowNumber))
        }
        if let cgField58 = CGEventField(rawValue: 58) {
            event.setIntegerValueField(cgField58, value: 337_523)
        }
        event.flags = []
    }
}
