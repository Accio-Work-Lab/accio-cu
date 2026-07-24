import Testing
@testable import AccioComputerUseKit

@Test func targetedDoubleClickUsesDistinctEventNumbersForEachClickPair() {
    let plan = targetedClickEventNumberPlan(clickCount: 2, seed: 40)

    #expect(plan.move == 40)
    #expect(plan.primer == 41)
    #expect(plan.clicks == [42, 43])
}

@Test func targetedSingleClickStillUsesOneClickPair() {
    let plan = targetedClickEventNumberPlan(clickCount: 1, seed: 90)

    #expect(plan.clicks == [92])
}

@Test func multiClickCannotBeReplacedByAccessibilityActions() {
    #expect(shouldUseAXClickActions(clickCount: 1))
    #expect(!shouldUseAXClickActions(clickCount: 2))
    #expect(!shouldUseAXClickActions(clickCount: 3))
}
