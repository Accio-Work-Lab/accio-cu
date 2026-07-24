import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - Scroll dispatch

extension ComputerUseService {
    func scrollableGlobalPoint(for record: ElementRecord, snapshot: AppSnapshot) throws -> CGPoint? {
        guard let localFrame = record.localFrame,
              let windowBounds = snapshot.windowBounds else {
            return nil
        }

        let visibleRect = CGRect(x: 0, y: 0, width: windowBounds.width, height: windowBounds.height)
        let clampedFrame = localFrame.intersection(visibleRect)

        let local: CGPoint
        if !clampedFrame.isNull, clampedFrame.width > 1, clampedFrame.height > 1 {
            local = CGPoint(x: clampedFrame.midX, y: clampedFrame.midY)
        } else if let firstChildPoint = firstVisibleChildCenter(of: record.element, windowBounds: windowBounds) {
            local = firstChildPoint
        } else {
            local = CGPoint(x: min(localFrame.midX, visibleRect.maxX - 10), y: min(localFrame.midY, visibleRect.maxY - 10))
        }

        return CGPoint(x: windowBounds.minX + local.x, y: windowBounds.minY + local.y)
    }

    func firstVisibleChildCenter(of element: AXUIElement?, windowBounds: CGRect) -> CGPoint? {
        guard let element else { return nil }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        let visibleRect = CGRect(x: windowBounds.minX, y: windowBounds.minY,
                                 width: windowBounds.width, height: windowBounds.height)
        for child in children.prefix(5) {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success else { continue }
            var pos = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
                  AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { continue }
            let childFrame = CGRect(origin: pos, size: size)
            if visibleRect.intersects(childFrame) {
                let localX = childFrame.midX - windowBounds.minX
                let localY = childFrame.midY - windowBounds.minY
                return CGPoint(x: localX, y: localY)
            }
        }
        return nil
    }

    func integralScrollPageCount(_ pages: Double) -> Int? {
        let rounded = pages.rounded(.toNearestOrAwayFromZero)
        guard abs(pages - rounded) < 0.000001 else {
            return nil
        }
        return max(Int(rounded), 1)
    }

    func scrollPageAction(for record: ElementRecord, direction: String) -> String? {
        record.rawActions.first {
            $0.caseInsensitiveCompare("AXScroll\(direction.capitalized)ByPage") == .orderedSame
        }
    }

    func scrollLineAction(for record: ElementRecord, direction: String) -> String? {
        record.rawActions.first {
            $0.caseInsensitiveCompare("AXScroll\(direction.capitalized)") == .orderedSame
        }
    }

    @discardableResult
    func performBackgroundScroll(
        at point: CGPoint?,
        direction: String,
        pages: Double,
        pageAction: String?,
        lineAction: String?,
        pageActionRepeatCount: Int?,
        scrollAnchor: AXUIElement?,
        snapshot: AppSnapshot
    ) throws -> Bool {
        let pid = snapshot.app.pid
        let positionBefore = scrollAnchor.flatMap { deepDescendantPosition(of: $0) }
        let canVerifyMovement = positionBefore != nil && scrollAnchor != nil
        let requiresActivation = needsActivationForInput(snapshot.app)

        // --- Hybrid strategy for Qt/Electron/Flutter ---
        if requiresActivation {
            if let pageAction, let repeatCount = pageActionRepeatCount, let scrollAnchor {
                if try performAction(named: pageAction, on: scrollAnchor, availableActions: [pageAction], repeatCount: repeatCount) {
                    return true
                }
            }
            if let lineAction, let scrollAnchor {
                let repeatCount = max(1, Int((pages * 5).rounded()))
                if try performAction(named: lineAction, on: scrollAnchor, availableActions: [lineAction], repeatCount: repeatCount) {
                    return true
                }
            }

            if let point {
                let eventPoint = inputEventPoint(fromScreenStatePoint: point)
                let alreadyActive = (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)

                if !alreadyActive {
                    try InputSimulation.prepareAppForGlobalPointerInput(snapshot.app, reason: .scrollFallback)
                }

                try InputSimulation.scrollGlobally(at: eventPoint, direction: direction, pages: pages)
                skipFocusRestore = true
                return true
            }
            return false
        }

        // --- Native macOS apps & element-based Electron detection ---
        let isElectron = scrollAnchor.map { isElectronElement($0) } ?? false

        if isElectron, let point {
            let eventPoint = inputEventPoint(fromScreenStatePoint: point)

            if let windowNumber = snapshot.targetWindowID.map({ Int($0) }) {
                try InputSimulation.scrollTargeted(
                    at: eventPoint, direction: direction, pages: pages,
                    pid: pid, windowNumber: windowNumber
                )
                if canVerifyMovement {
                    if scrollDidMove(before: positionBefore, anchor: scrollAnchor) { return true }
                } else {
                    return true
                }
            }

            try InputSimulation.scrollViaKeyboard(direction: direction, pages: pages, pid: pid)
            return true
        }

        let steps = BackgroundScrollPolicy.steps(
            hasScrollablePoint: point != nil,
            hasPageAction: pageAction != nil,
            pagesAreIntegral: pageActionRepeatCount != nil,
            canVerifyMovement: canVerifyMovement
        )

        var attempted = false

        for step in steps {
            switch step {
            case .accessibilityPageAction:
                guard let pageAction, let repeatCount = pageActionRepeatCount, let scrollAnchor else {
                    continue
                }
                if try performAction(named: pageAction, on: scrollAnchor, availableActions: [pageAction], repeatCount: repeatCount) {
                    return true
                }

            case .targetedWheel:
                guard let point else { continue }
                let windowNumber = snapshot.targetWindowID.map { Int($0) }
                // Only raise when no windowNumber — BackgroundScrollTransport already
                // prepares the window via WindowServer records when windowNumber is known.
                if windowNumber == nil {
                    InputSimulation.raiseTargetWindow(pid: pid)
                }
                try InputSimulation.scrollTargeted(at: point, direction: direction, pages: pages, pid: pid, windowNumber: windowNumber)
                attempted = true
                if canVerifyMovement {
                    if scrollDidMove(before: positionBefore, anchor: scrollAnchor) {
                        return true
                    }
                } else {
                    return true
                }

            case .targetedKeyboard:
                try InputSimulation.scrollViaKeyboard(direction: direction, pages: pages, pid: pid)
                attempted = true
                if canVerifyMovement && scrollDidMove(before: positionBefore, anchor: scrollAnchor) {
                    return true
                }
                return attempted
            }
        }

        return attempted
    }

    func scrollDidMove(before: CGPoint?, anchor: AXUIElement?) -> Bool {
        guard let before, let anchor else { return false }
        Thread.sleep(forTimeInterval: 0.15)
        guard let after = deepDescendantPosition(of: anchor) else { return false }
        return after != before
    }

    func deepDescendantPosition(of element: AXUIElement) -> CGPoint? {
        var current = element
        for _ in 0..<3 {
            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement],
                  let firstChild = children.first else { break }
            current = firstChild
        }

        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(current, kAXPositionAttribute as CFString, &posRef) == .success else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    func defaultScrollTarget(in snapshot: AppSnapshot) throws -> ElementRecord {
        let scrollAreas = snapshot.elements.values.filter { $0.role == kAXScrollAreaRole as String }
        if let best = scrollAreas.max(by: { areaOf($0) < areaOf($1) }) {
            return best
        }

        if let scrollable = snapshot.elements.values
            .filter({ $0.rawActions.contains(where: { $0.hasPrefix("AXScroll") }) })
            .max(by: { areaOf($0) < areaOf($1) }) {
            return scrollable
        }

        // Prefer the largest AXWebArea, and skip popup/overlay web areas
        // (e.g., Chrome's "Omnibox Popup") which are not the main content.
        let webAreas = snapshot.elements.values
            .filter { $0.role == "AXWebArea" }
            .filter { record in
                let title = record.displayText ?? ""
                return !title.lowercased().contains("omnibox") &&
                       !title.lowercased().contains("popup")
            }
        if let best = webAreas.max(by: { areaOf($0) < areaOf($1) }) {
            return best
        }
        // Fall back to any AXWebArea if all were filtered out
        if let webArea = snapshot.elements.values
            .max(by: { r1, r2 in
                (r1.role == "AXWebArea" ? areaOf(r1) : 0) < (r2.role == "AXWebArea" ? areaOf(r2) : 0)
            }),
            webArea.role == "AXWebArea" {
            return webArea
        }

        if let root = snapshot.elements[0] {
            return root
        }

        throw ComputerUseError.stateUnavailable(
            "No scrollable element found. Specify element_index or element_text to target a specific element."
        )
    }

    func areaOf(_ record: ElementRecord) -> CGFloat {
        guard let frame = record.localFrame else { return 0 }
        return frame.width * frame.height
    }

    /// Walk up the AX tree from `element` to find its nearest AXScrollArea ancestor.
    func ancestorScrollArea(of element: AXUIElement?, in snapshot: AppSnapshot) -> ElementRecord? {
        guard let element else { return nil }
        var current = element
        for _ in 0..<30 {
            guard let parent = copyParent(of: current) else {
                return nil
            }
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(parent, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == kAXScrollAreaRole as String {
                for record in snapshot.elements.values {
                    if let recordElement = record.element, CFEqual(recordElement, parent) {
                        return record
                    }
                }
            }
            current = parent
        }
        return nil
    }

    /// Auto-scroll an off-screen element into view.
    func autoScrollIntoView(
        element: AXUIElement?,
        elementText: String?,
        localFrame: CGRect,
        visibleRect: CGRect,
        app: String,
        snapshot: AppSnapshot
    ) throws -> ElementRecord? {
        let direction: String
        if localFrame.midY > visibleRect.maxY {
            direction = "down"
        } else if localFrame.midY < visibleRect.minY {
            direction = "up"
        } else if localFrame.midX > visibleRect.maxX {
            direction = "right"
        } else if localFrame.midX < visibleRect.minX {
            direction = "left"
        } else {
            return nil
        }

        let distance: CGFloat
        let windowDimension: CGFloat
        if direction == "down" || direction == "up" {
            distance = direction == "down"
                ? localFrame.midY - visibleRect.maxY
                : visibleRect.minY - localFrame.midY
            windowDimension = visibleRect.height
        } else {
            distance = direction == "right"
                ? localFrame.midX - visibleRect.maxX
                : visibleRect.minX - localFrame.midX
            windowDimension = visibleRect.width
        }
        let pages = max(ceil(distance / max(windowDimension, 1)), 1)

        let scrollTarget: ElementRecord
        if let ancestorRecord = ancestorScrollArea(of: element, in: snapshot) {
            scrollTarget = ancestorRecord
        } else {
            scrollTarget = try defaultScrollTarget(in: snapshot)
        }
        let point = try scrollableGlobalPoint(for: scrollTarget, snapshot: snapshot)
        try performBackgroundScroll(
            at: point,
            direction: direction,
            pages: pages,
            pageAction: scrollPageAction(for: scrollTarget, direction: direction),
            lineAction: scrollLineAction(for: scrollTarget, direction: direction),
            pageActionRepeatCount: integralScrollPageCount(pages),
            scrollAnchor: scrollTarget.element,
            snapshot: snapshot
        )

        Thread.sleep(forTimeInterval: 0.2)

        let freshSnapshot = try refreshSnapshot(for: app)
        guard let searchText = elementText else { return nil }
        guard let resolved = try? lookupElementByText(snapshot: freshSnapshot, text: searchText) else {
            return nil
        }

        if let newFrame = resolved.localFrame, let wb = freshSnapshot.windowBounds {
            let newVisibleRect = CGRect(x: 0, y: 0, width: wb.width, height: wb.height)
            if newVisibleRect.intersects(newFrame) {
                return resolved
            }
        }

        return nil
    }
}
