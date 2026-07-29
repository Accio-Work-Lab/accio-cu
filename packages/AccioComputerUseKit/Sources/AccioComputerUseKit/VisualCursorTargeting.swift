import AppKit
import CoreGraphics
import Foundation

struct VisualCursorTarget: Equatable {
    let point: CGPoint
    let window: CursorTargetWindow?
}

struct VisualCursorScreenMapping: Equatable {
    let screenStateFrame: CGRect
    let appKitFrame: CGRect
    let backingScaleFactor: CGFloat
}

func currentVisualCursorScreenMappings() -> [VisualCursorScreenMapping] {
    NSScreen.screens.compactMap { screen in
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return VisualCursorScreenMapping(
            screenStateFrame: CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value)),
            appKitFrame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor
        )
    }
}

func screenMapping(
    withLargestIntersection bounds: CGRect,
    mappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> VisualCursorScreenMapping? {
    mappings
        .map { ($0, $0.screenStateFrame.intersection(bounds)) }
        .filter { !$0.1.isNull && !$0.1.isEmpty }
        .max { lhs, rhs in lhs.1.width * lhs.1.height < rhs.1.width * rhs.1.height }?
        .0
}

func validatedScreenStateGlobalPoint(
    windowPoint: CGPoint,
    windowBounds: CGRect,
    mappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint? {
    let localBounds = CGRect(origin: .zero, size: windowBounds.size)
    guard localBounds.contains(windowPoint) else { return nil }

    let globalPoint = CGPoint(
        x: windowBounds.minX + windowPoint.x,
        y: windowBounds.minY + windowPoint.y
    )
    guard mappings.contains(where: { $0.screenStateFrame.contains(globalPoint) }) else {
        return nil
    }
    return globalPoint
}

func screenStatePointToAppKitGlobalPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    guard let mapping = screenMappings.first(where: { $0.screenStateFrame.contains(point) }) else {
        return point
    }

    let localX = point.x - mapping.screenStateFrame.minX
    let localY = point.y - mapping.screenStateFrame.minY

    return CGPoint(
        x: mapping.appKitFrame.minX + localX,
        y: mapping.appKitFrame.maxY - localY
    )
}

func inputEventPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings _: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    point
}

func makeVisualCursorTarget(
    at point: CGPoint,
    targetWindowID: CGWindowID?,
    targetWindowLayer: Int?,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> VisualCursorTarget {
    VisualCursorTarget(
        point: screenStatePointToAppKitGlobalPoint(
            fromScreenStatePoint: point,
            screenMappings: screenMappings
        ),
        window: targetWindowID.map { CursorTargetWindow(windowID: $0, layer: targetWindowLayer ?? 0) }
    )
}

func makeVisualCursorTarget(
    localFrame: CGRect?,
    windowBounds: CGRect?,
    targetWindowID: CGWindowID?,
    targetWindowLayer: Int?,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> VisualCursorTarget? {
    guard let localFrame, let windowBounds else {
        return nil
    }

    let point = CGPoint(
        x: windowBounds.minX + localFrame.midX,
        y: windowBounds.minY + localFrame.midY
    )
    return makeVisualCursorTarget(
        at: point,
        targetWindowID: targetWindowID,
        targetWindowLayer: targetWindowLayer,
        screenMappings: screenMappings
    )
}

func environmentFlagEnabled(_ names: [String], environment: [String: String]) -> Bool {
    for name in names {
        guard let rawValue = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            continue
        }
        return ["1", "true", "yes", "on"].contains(rawValue)
    }
    return false
}

func inputFallbackDebugEnabled(environment: [String: String]) -> Bool {
    environmentFlagEnabled(
        ["ACCIO_COMPUTER_USE_DEBUG_INPUT_FALLBACKS", "OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS"],
        environment: environment
    )
}

func globalPointerFallbacksEnabled(environment: [String: String]) -> Bool {
    if preferBackgroundOperations {
        return false
    }
    return environmentFlagEnabled(
        ["ACCIO_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS"],
        environment: environment
    )
}
