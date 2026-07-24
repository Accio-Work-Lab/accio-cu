import Testing
@testable import AccioComputerUseKit

@Test("Action summaries redact common secret literals")
func actionSummariesRedactCommonSecretLiterals() {
    let summary = redactedActionInputSummary("sk-proj-abcdefghijklmnopqrstuvwxyz1234567890")

    #expect(summary == redactedSensitiveValue)
}

@Test("Action summaries keep ordinary short text")
func actionSummariesKeepOrdinaryShortText() {
    let summary = redactedActionInputSummary("hello from accio")

    #expect(summary == "hello from accio")
}

@Test("AX value redaction uses role and labels")
func axValueRedactionUsesRoleAndLabels() {
    #expect(redactedAXValue("hunter2", role: "AXSecureTextField", labelParts: ["Password"]) == redactedSensitiveValue)
    #expect(redactedAXValue("abc123", role: "AXTextField", labelParts: ["API Key"]) == redactedSensitiveValue)
    #expect(redactedAXValue("search query", role: "AXTextField", labelParts: ["Search"]) == "search query")
}
