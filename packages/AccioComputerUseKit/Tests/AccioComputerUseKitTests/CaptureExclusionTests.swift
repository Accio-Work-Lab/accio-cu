import Testing
@testable import AccioComputerUseKit

@Test("capture exclusion uses exact authenticated process identities")
func captureExclusionUsesAuthenticatedPIDs() {
    #expect(shouldExcludeFromScreenCapture(ownerPID: 10, currentPID: 10, trustedActivityPID: 20))
    #expect(shouldExcludeFromScreenCapture(ownerPID: 20, currentPID: 10, trustedActivityPID: 20))
    #expect(!shouldExcludeFromScreenCapture(ownerPID: 30, currentPID: 10, trustedActivityPID: 20))
    #expect(!shouldExcludeFromScreenCapture(ownerPID: 20, currentPID: 10, trustedActivityPID: nil))
}

@Test("screen capture fails closed when a running HUD cannot be excluded")
func screenCaptureFailsClosedWithoutHUDExclusion() {
    #expect(!captureExclusionIsSafe(
        ownApplicationCount: 0,
        ownWindowCount: 0,
        activityHUDRunning: true
    ))
    #expect(captureExclusionIsSafe(
        ownApplicationCount: 1,
        ownWindowCount: 0,
        activityHUDRunning: true
    ))
    #expect(!captureExclusionIsSafe(
        ownApplicationCount: 0,
        ownWindowCount: 1,
        activityHUDRunning: true
    ))
    #expect(captureExclusionIsSafe(
        ownApplicationCount: 0,
        ownWindowCount: 0,
        activityHUDRunning: false
    ))
}

@Test("visual cursor hides shortly after the last interaction")
func visualCursorUsesShortIdleTimeout() {
    #expect(visualCursorPostInteractionIdleTimeout() == 2)
}
