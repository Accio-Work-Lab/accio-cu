import Testing
@testable import AccioComputerUseKit

@Test("Command+F aliases use native key delivery", arguments: [
    "super+f", "cmd+f", "command+f", "meta+f",
])
func commandFUsesNativeKeyDelivery(specification: String) throws {
    let parsed = try KeyPressParser.parse(specification)
    let usesNativeDelivery: Bool
    if case .rawKey = detectKeyIntent(parsed) {
        usesNativeDelivery = true
    } else {
        usesNativeDelivery = false
    }

    #expect(usesNativeDelivery, "Command+F must preserve the current responder's native shortcut semantics")
}

@Test func commandAStillUsesSafeSemanticSelection() throws {
    let parsed = try KeyPressParser.parse("super+a")
    let usesSemanticSelection: Bool
    if case .selectAll = detectKeyIntent(parsed) {
        usesSemanticSelection = true
    } else {
        usesSemanticSelection = false
    }

    #expect(usesSemanticSelection)
}
