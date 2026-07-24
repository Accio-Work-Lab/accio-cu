import Foundation
import Testing
@testable import AccioComputerUseKit

@Test("screen coordinate safety fails closed for self and unknown owners")
func screenCoordinateSafetyFailsClosed() {
    #expect(classifyScreenPointTarget(ownerPID: getpid(), bundleIdentifier: nil) == .blocked)
    #expect(classifyScreenPointTarget(ownerPID: 42, bundleIdentifier: nil) == .indeterminate)
    #expect(classifyScreenPointTarget(
        ownerPID: 42,
        bundleIdentifier: PermissionSupport.bundleIdentifier
    ) == .blocked)
    #expect(classifyScreenPointTarget(ownerPID: 42, bundleIdentifier: "com.apple.Safari") == .allowed)
}

@Test("raw screen input requires both window and AX targets to be allowed")
func rawScreenInputRequiresTwoIndependentAllowedTargets() {
    #expect(combinedScreenPointSafety(windowTarget: .allowed, accessibilityTarget: .allowed) == .allowed)
    #expect(combinedScreenPointSafety(windowTarget: .allowed, accessibilityTarget: .blocked) == .blocked)
    #expect(combinedScreenPointSafety(windowTarget: .allowed, accessibilityTarget: .indeterminate) == .indeterminate)
    #expect(combinedScreenPointSafety(windowTarget: .blocked, accessibilityTarget: .allowed) == .blocked)
    #expect(combinedScreenPointSafety(windowTarget: .indeterminate, accessibilityTarget: .allowed) == .indeterminate)
}
