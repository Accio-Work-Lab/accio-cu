import AppKit
import CoreGraphics
import Testing
@testable import AccioComputerUseKit

private func scrollTargetSnapshot(_ records: [ElementRecord]) -> AppSnapshot {
    AppSnapshot(
        snapshotID: "scroll-target",
        app: RunningAppDescriptor(
            name: "SyntheticApp",
            bundleIdentifier: "com.example.synthetic",
            pid: NSRunningApplication.current.processIdentifier,
            runningApplication: NSRunningApplication.current
        ),
        windowTitle: "Main",
        windowBounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
        targetWindowID: nil,
        targetWindowLayer: nil,
        screenshotPNGData: nil,
        screenRecordingDenied: false,
        treeLines: [],
        focusedSummary: nil,
        selectedText: nil,
        elements: Dictionary(uniqueKeysWithValues: records.map { ($0.index, $0) }),
        elementCount: records.count
    )
}

private func scrollTargetRecord(
    index: Int,
    role: String,
    frame: CGRect,
    actions: [String] = [],
    text: String? = nil
) -> ElementRecord {
    ElementRecord(
        index: index,
        identifier: nil,
        element: nil,
        localFrame: frame,
        rawActions: actions,
        prettyActions: actions,
        displayText: text,
        role: role
    )
}

@Test("verifiable background scrolls escalate to activation after targeted routes")
func verifiableScrollIncludesActivationFallback() {
    let steps = BackgroundScrollPolicy.steps(
        hasScrollablePoint: true,
        hasPageAction: false,
        pagesAreIntegral: false,
        canVerifyMovement: true
    )

    #expect(steps == [.targetedWheel, .targetedKeyboard, .activationWheel])
}

@Test("unverifiable scrolls avoid a potentially duplicate activation fallback")
func unverifiableScrollStopsAfterTargetedRoutes() {
    let steps = BackgroundScrollPolicy.steps(
        hasScrollablePoint: true,
        hasPageAction: false,
        pagesAreIntegral: false,
        canVerifyMovement: false
    )

    #expect(steps == [.targetedWheel, .targetedKeyboard])
}

@Test("list-like accessibility roles are eligible scroll containers")
func listRolesAreScrollContainers() {
    for role in ["AXScrollArea", "AXTable", "AXOutline", "AXList", "AXCollection"] {
        #expect(ScrollContainerPolicy.isContainerRole(role))
    }
    #expect(!ScrollContainerPolicy.isContainerRole("AXButton"))
    #expect(!ScrollContainerPolicy.isContainerRole(nil))
}

@Test("scroll actions distinguish actionable containers from semantic lists")
func scrollActionsIdentifyActionableContainers() {
    #expect(ScrollContainerPolicy.hasScrollAction(["AXPress", "AXScrollDownByPage"]))
    #expect(!ScrollContainerPolicy.hasScrollAction(["AXPress"]))
}

@Test("default target does not let a small scrollable control replace main content")
func defaultScrollTargetPrefersMainContent() throws {
    let mainContent = scrollTargetRecord(
        index: 1,
        role: "AXWebArea",
        frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
        text: "Main content"
    )
    let smallControl = scrollTargetRecord(
        index: 2,
        role: "AXSlider",
        frame: CGRect(x: 900, y: 20, width: 20, height: 100),
        actions: ["AXScrollDown"]
    )

    let target = try ComputerUseService().defaultScrollTarget(
        in: scrollTargetSnapshot([mainContent, smallControl])
    )

    #expect(target.index == mainContent.index)

    let actionableList = scrollTargetRecord(
        index: 3,
        role: "AXList",
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        actions: ["AXScrollDownByPage"]
    )
    let nestedTarget = try ComputerUseService().defaultScrollTarget(
        in: scrollTargetSnapshot([mainContent, actionableList])
    )

    #expect(nestedTarget.index == actionableList.index)
}

@Test("default target prefers a large semantic container over an unrelated scrollable control")
func defaultScrollTargetPrefersLargeContainerFallback() throws {
    let list = scrollTargetRecord(
        index: 1,
        role: "AXList",
        frame: CGRect(x: 0, y: 0, width: 900, height: 700)
    )
    let smallControl = scrollTargetRecord(
        index: 2,
        role: "AXSlider",
        frame: CGRect(x: 900, y: 20, width: 20, height: 100),
        actions: ["AXScrollDown"]
    )

    let target = try ComputerUseService().defaultScrollTarget(
        in: scrollTargetSnapshot([list, smallControl])
    )

    #expect(target.index == list.index)
}

@Test("scroll position verification distinguishes geometry changes")
func scrollPositionVerificationUsesGeometry() {
    let original = CGPoint(x: 10, y: 20)

    #expect(!scrollPositionChanged(before: original, after: original))
    #expect(scrollPositionChanged(before: original, after: CGPoint(x: 10, y: 21)))
    #expect(!scrollPositionChanged(before: nil, after: original))
}

@Test("scroll policy exposes opposite directions for transformed lists")
func scrollPolicyProvidesOppositeDirection() {
    #expect(oppositeScrollDirection(to: "up") == "down")
    #expect(oppositeScrollDirection(to: "down") == "up")
    #expect(oppositeScrollDirection(to: "left") == "right")
    #expect(oppositeScrollDirection(to: "right") == "left")
    #expect(oppositeScrollDirection(to: "unknown") == nil)
}

@Test("no-movement warning recommends one bounded opposite-direction retry")
func noMovementWarningProvidesRecoveryDirection() {
    #expect(noMovementScrollWarning(direction: "up").contains("direction=\"down\""))
}

@Test("stale scrolls with stable refs recommend safe re-resolution")
func staleScrollWarningUsesStableRef() {
    let stale = "stale snapshot_id 'abc'"

    #expect(scrollStalenessRecoveryMessage(stale, hasStableRef: true).contains("omit snapshot_id"))
    #expect(scrollStalenessRecoveryMessage(stale, hasStableRef: false) == stale)
}
