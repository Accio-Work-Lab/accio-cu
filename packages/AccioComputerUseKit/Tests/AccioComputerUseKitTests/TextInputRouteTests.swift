import Testing
@testable import AccioComputerUseKit

@Test func typeTextNeverUsesAXValueWrite() {
    #expect(textMutationPlan(intent: .typeText, useActivation: false) == .keyboardPostToPID)
    #expect(textMutationPlan(intent: .typeText, useActivation: true) == .keyboardHID)
}

@Test func setValueRemainsAXValueWrite() {
    #expect(textMutationPlan(intent: .setValue, useActivation: false) == .axValueWrite)
    #expect(textMutationPlan(intent: .setValue, useActivation: true) == .axValueWrite)
}
