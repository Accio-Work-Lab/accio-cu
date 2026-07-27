import CoreGraphics
import Testing
@testable import AccioComputerUseKit

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
