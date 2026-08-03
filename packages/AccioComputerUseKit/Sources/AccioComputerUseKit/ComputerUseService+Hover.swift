import CoreGraphics
import Foundation

extension ComputerUseService {
    public func hover(
        app: String,
        stableRef: String? = nil,
        elementIndex: String?,
        elementText: String?,
        snapshotId: String? = nil,
        x: Double?,
        y: Double?,
        coordinateSpace: CoordinateSpace = .pixel
    ) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "hover")
        return try preservingFrontmostApp {
            let before = try snapshotAwareOfStaleness(for: app, snapshotId: snapshotId)
            let targetPoint: CGPoint
            let targetDescription: String

            if stableRef != nil || elementIndex != nil || elementText != nil {
                let record = try resolveElement(
                    snapshot: before,
                    stableRef: stableRef,
                    elementIndex: elementIndex,
                    elementText: elementText
                )
                guard let frame = record.localFrame,
                      let windowBounds = before.windowBounds,
                      CGRect(origin: .zero, size: windowBounds.size).intersects(frame),
                      let point = try globalPoint(for: record, snapshot: before) else {
                    throw ComputerUseError.stateUnavailable(
                        "Hover target is outside the visible window. Scroll it into view first."
                    )
                }
                targetPoint = point
                targetDescription = elementSummary(for: record)
            } else if let x, let y {
                let inputPoint = CGPoint(x: x, y: y)
                let pixelPoint = convertToSnapshotPixels(
                    inputPoint,
                    coordinateSpace: coordinateSpace,
                    snapshot: before
                )
                targetPoint = try screenshotToGlobalPoint(
                    snapshot: before,
                    x: pixelPoint.x,
                    y: pixelPoint.y
                )
                targetDescription = "x=\(Int(pixelPoint.x)), y=\(Int(pixelPoint.y))"
            } else {
                throw ComputerUseError.invalidArguments(
                    "hover requires stable_ref, element_text (or element_label), element_index, or x/y coordinates."
                )
            }

            try InputSimulation.prepareAppForGlobalPointerInput(before.app, reason: .hover)
            try InputSimulation.hoverAtScreenPoint(at: targetPoint)
            skipFocusRestore = true
            Thread.sleep(forTimeInterval: 0.25)

            let after = try refreshSnapshot(for: app)
            let preState = ActionPreState(
                pid: before.app.pid,
                fingerprint: structuralFingerprint(before),
                snapshot: before
            )
            let actionResult = ActionResultSummary.make(
                tool: "hover",
                target: targetDescription,
                route: "global_pointer",
                preState: preState,
                postSnapshot: after
            )
            let summary = actionResult.renderedLine + "\nHovered \(targetDescription)."
            return actionObservationResult(
                before: before,
                after: after,
                actionSummary: summary,
                actionMetadata: actionResult.structuredMetadata
            )
        }
    }
}
