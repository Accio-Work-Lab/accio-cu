import Testing
@testable import AccioComputerUseKit

@Test("runtime Accessibility capability is authoritative over stale TCC records")
func runtimeAccessibilityCapabilityIsAuthoritative() {
    #expect(PermissionDiagnostics.resolveAccessibility(runtimeTrusted: true) == .granted)
    #expect(PermissionDiagnostics.resolveAccessibility(runtimeTrusted: false) == .denied)
}

@Test("runtime screen-capture capability is authoritative over stale TCC records")
func runtimeScreenCaptureCapabilityIsAuthoritative() {
    #expect(PermissionDiagnostics.resolveScreenCapture(runtimeGranted: true) == .granted)
    #expect(PermissionDiagnostics.resolveScreenCapture(runtimeGranted: false) == .denied)
}

@Test("permission authorization chooses one native surface per user action")
func permissionAuthorizationChoosesOneSurface() {
    #expect(PermissionSupport.authorizationAction(
        for: .accessibility,
        isGranted: false,
        intent: .requestPrompt
    ) == .requestPrompt(.accessibility))
    #expect(PermissionSupport.authorizationAction(
        for: .accessibility,
        isGranted: false,
        intent: .openSettings
    ) == .openSettings(.accessibility))
    #expect(PermissionSupport.authorizationAction(
        for: .screenRecording,
        isGranted: true,
        intent: .requestPrompt
    ) == .alreadyGranted)
}
