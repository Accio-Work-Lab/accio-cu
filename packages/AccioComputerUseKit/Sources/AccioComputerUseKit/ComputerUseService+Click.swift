import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - Click dispatch

extension ComputerUseService {
    func performPreferredClick(on record: ElementRecord, button: MouseButtonKind, clickCount: Int) throws -> Bool {
        guard let element = record.element else {
            return false
        }

        let role = stringValue(of: element, attribute: kAXRoleAttribute) ?? ""
        if role == "AXUnknown" {
            return false
        }

        let isInsideDisabledContainer = hasDisabledParent(element)

        switch button {
        case .left:
            if !isInsideDisabledContainer {
                if try performAction(named: kAXPressAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                    return true
                }

                if try performAction(named: kAXConfirmAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                    return true
                }

                if try performAction(named: "AXOpen", on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                    return true
                }

                if !hasAncestorRole("AXWebArea", of: element),
                   try selectContainingListItem(for: element)
                {
                    return true
                }
            } else {
                return false
            }
        case .right:
            if try performAction(named: kAXShowMenuAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }
        case .middle:
            break
        }

        return false
    }

    func clickCandidates(at windowLocalPoint: CGPoint, in snapshot: AppSnapshot) throws -> [ElementRecord] {
        var candidates: [ElementRecord] = []

        if let bestRecord = bestElement(containing: windowLocalPoint, in: snapshot) {
            candidates.append(bestRecord)
        }

        if let hitRecord = try hitTestElement(atWindowLocalPoint: windowLocalPoint, in: snapshot) {
            candidates.append(hitRecord)
        }

        return candidates.reduce(into: []) { uniqueCandidates, candidate in
            if !uniqueCandidates.contains(where: { sameElement($0.element, candidate.element) }) {
                uniqueCandidates.append(candidate)
            }
        }
    }

    func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        return CFEqual(lhs, rhs)
    }

    func selectContainingListItem(for element: AXUIElement) throws -> Bool {
        guard let target = selectableListOrOutline(containing: element) else {
            return false
        }

        let selectionAttribute: String
        if target.role == "AXOutline" {
            selectionAttribute = kAXSelectedRowsAttribute as String
        } else {
            selectionAttribute = kAXSelectedChildrenAttribute as String
        }

        try AutomationPolicy().authorizeToolCall(named: "ax_action")
        let result = AXUIElementSetAttributeValue(
            target.container,
            selectionAttribute as CFString,
            [target.item] as CFArray
        )

        switch result {
        case .success:
            Thread.sleep(forTimeInterval: 0.15)
            return true
        case .failure, .attributeUnsupported, .actionUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
            return false
        default:
            throw ComputerUseError.message("AXUIElementSetAttributeValue(\(selectionAttribute)) failed with \(result.rawValue)")
        }
    }

    func selectableListOrOutline(containing element: AXUIElement) -> (container: AXUIElement, item: AXUIElement, role: String)? {
        var current = element
        var directChild = element

        for _ in 0..<8 {
            guard let parent = copyParent(of: current) else {
                return nil
            }

            let role = stringValue(of: parent, attribute: kAXRoleAttribute) ?? ""

            if role == kAXListRole as String,
               isSettable(element: parent, attribute: kAXSelectedChildrenAttribute as String),
               boolValue(of: parent, attribute: kAXEnabledAttribute as String) != false {
                return (parent, directChild, role)
            }

            if role == "AXOutline",
               isSettable(element: parent, attribute: kAXSelectedRowsAttribute as String),
               boolValue(of: parent, attribute: kAXEnabledAttribute as String) != false {
                return (parent, directChild, role)
            }

            directChild = parent
            current = parent
        }

        return nil
    }

    func performAXClickSequence(
        on record: ElementRecord,
        snapshot: AppSnapshot,
        button: MouseButtonKind,
        clickCount: Int,
        includeNearbyHitTesting: Bool,
        allowActivationFallback: Bool
    ) throws -> Bool {
        guard shouldUseAXClickActions(clickCount: clickCount) else {
            return false
        }

        if let element = record.element,
           stringValue(of: element, attribute: kAXRoleAttribute) == "AXWindow" {
            return false
        }

        if let element = record.element,
           stringValue(of: element, attribute: kAXRoleAttribute) == "AXUnknown" {
            return false
        }

        if try performPreferredClick(on: record, button: button, clickCount: clickCount) {
            return true
        }

        if let element = record.element, hasDisabledParent(element) {
            return false
        }

        for candidate in descendantClickCandidates(for: record, snapshot: snapshot) {
            if try performPreferredClick(on: candidate, button: button, clickCount: clickCount) {
                return true
            }
        }

        if includeNearbyHitTesting {
            for localPoint in clickActionPoints(for: record) {
                guard let hitRecord = try hitTestElement(atWindowLocalPoint: localPoint, in: snapshot) ?? bestElement(containing: localPoint, in: snapshot) else {
                    continue
                }

                if try performPreferredClick(on: hitRecord, button: button, clickCount: clickCount) {
                    return true
                }

                for candidate in descendantClickCandidates(for: hitRecord, snapshot: snapshot) {
                    if try performPreferredClick(on: candidate, button: button, clickCount: clickCount) {
                        return true
                    }
                }
            }
        }

        return false
    }

    func bestElement(containing point: CGPoint, in snapshot: AppSnapshot) -> ElementRecord? {
        snapshot.elements.values
            .filter { $0.localFrame?.contains(point) ?? false }
            .sorted { lhs, rhs in
                let lhsPriority = clickPriority(for: lhs)
                let rhsPriority = clickPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return frameArea(of: lhs) < frameArea(of: rhs)
            }
            .first
    }

    func hitTestElement(atWindowLocalPoint point: CGPoint, in snapshot: AppSnapshot) throws -> ElementRecord? {
        let appElement = AXUIElementCreateApplication(snapshot.app.pid)
        let globalPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: point)
        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(appElement, Float(globalPoint.x), Float(globalPoint.y), &hitElement)
        guard result == .success, let hitElement else {
            return nil
        }

        let rawActions = copyActions(for: hitElement) ?? []
        return ElementRecord(
            index: -1,
            identifier: nil,
            element: hitElement,
            localFrame: localFrame(of: hitElement, windowBounds: snapshot.windowBounds),
            rawActions: rawActions,
            prettyActions: rawActions
        )
    }

    func clickPriority(for record: ElementRecord) -> Int {
        if record.rawActions.contains(where: {
            $0.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame ||
                $0.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame ||
                $0.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame ||
                $0.caseInsensitiveCompare(kAXRaiseAction as String) == .orderedSame
        }) {
            return 0
        }

        if let element = record.element,
           isSettable(element: element, attribute: kAXMainAttribute as String) ||
           isSettable(element: element, attribute: kAXFocusedAttribute as String) {
            return 1
        }

        return 2
    }

    func frameArea(of record: ElementRecord) -> CGFloat {
        guard let frame = record.localFrame else {
            return .greatestFiniteMagnitude
        }

        return frame.width * frame.height
    }

    func clickActionPoints(for record: ElementRecord) -> [CGPoint] {
        guard let frame = record.localFrame else {
            return []
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let leading = CGPoint(
            x: frame.minX + min(max(frame.width * 0.3, 20), max(frame.width - 4, 20)),
            y: frame.midY
        )

        if abs(leading.x - center.x) < 1 {
            return [center]
        }

        return [center, leading]
    }

    func descendantClickCandidates(for record: ElementRecord, snapshot: AppSnapshot) -> [ElementRecord] {
        guard let element = record.element else {
            return []
        }

        return descendantClickCandidates(of: element, windowBounds: snapshot.windowBounds)
            .sorted { lhs, rhs in
                let lhsPriority = clickPriority(for: lhs)
                let rhsPriority = clickPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return frameArea(of: lhs) < frameArea(of: rhs)
            }
    }

    func descendantClickCandidates(of element: AXUIElement, windowBounds: CGRect?, depth: Int = 0) -> [ElementRecord] {
        guard depth < 3 else {
            return []
        }

        var results: [ElementRecord] = []
        for child in copyChildren(of: element) {
            let rawActions = copyActions(for: child) ?? []
            results.append(
                ElementRecord(
                    index: -1,
                    identifier: nil,
                    element: child,
                    localFrame: localFrame(of: child, windowBounds: windowBounds),
                    rawActions: rawActions,
                    prettyActions: rawActions
                )
            )
            results.append(contentsOf: descendantClickCandidates(of: child, windowBounds: windowBounds, depth: depth + 1))
        }

        return results
    }

    // MARK: - Click fallback (coordinate-based)

    func performNonAXClickFallback(
        at point: CGPoint,
        button: MouseButtonKind,
        clickCount: Int,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        if globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) {
            debugInputFallback(tool: "click", targetDescription: "coordinate click", snapshot: snapshot)
            try InputSimulation.prepareAppForGlobalPointerInput(snapshot.app, reason: .clickFallback)
            try InputSimulation.clickGlobally(at: eventPoint, button: button, clickCount: clickCount)
            Thread.sleep(forTimeInterval: 0.15)
            return
        }

        let pid = snapshot.app.pid
        let windowNumber = snapshot.targetWindowID.map { Int($0) }

        if needsActivationForInput(snapshot.app) {
            try performActivationClick(at: eventPoint, button: button, clickCount: clickCount, snapshot: snapshot)
            return
        }

        if let windowNumber {
            try InputSimulation.clickTargeted(
                at: eventPoint, button: button, clickCount: clickCount,
                pid: pid, windowNumber: windowNumber
            )
        } else {
            try InputSimulation.clickTargeted(
                at: eventPoint, button: button, clickCount: clickCount,
                pid: pid, windowNumber: nil
            )
        }
        Thread.sleep(forTimeInterval: 0.20)
    }

    /// Activation-based click for non-native frameworks (Electron, Qt, Flutter).
    func performActivationClick(
        at eventPoint: CGPoint,
        button: MouseButtonKind,
        clickCount: Int,
        snapshot: AppSnapshot
    ) throws {
        let pid = snapshot.app.pid
        let alreadyActive = (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)

        if !alreadyActive {
            try InputSimulation.prepareAppForGlobalPointerInput(snapshot.app, reason: .clickFallback)
        }

        try InputSimulation.clickGlobally(at: eventPoint, button: button, clickCount: clickCount)

        skipFocusRestore = true
    }
}
