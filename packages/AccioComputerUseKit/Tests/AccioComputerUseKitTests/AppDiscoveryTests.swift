import Testing
@testable import AccioComputerUseKit

@Test("App safety policy blocks Accio itself as an automation target")
func appSafetyPolicyBlocksAccioItself() {
    #expect(AppSafetyPolicy.isBlocked(bundleIdentifier: PermissionSupport.bundleIdentifier))
    #expect(AppSafetyPolicy.isBlocked(bundleIdentifier: PermissionSupport.bundleIdentifier.uppercased()))
}

@Test("App safety policy keeps existing sensitive app blocks")
func appSafetyPolicyKeepsSensitiveAppBlocks() {
    #expect(AppSafetyPolicy.isBlocked(bundleIdentifier: "com.1password.1password"))
    #expect(!AppSafetyPolicy.isBlocked(bundleIdentifier: "com.apple.TextEdit"))
}
