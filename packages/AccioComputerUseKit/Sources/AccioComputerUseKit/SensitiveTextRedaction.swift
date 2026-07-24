import Foundation

let redactedSensitiveValue = "[redacted]"

func shouldRedactSensitiveText(role: String?, labelParts: [String?]) -> Bool {
    if role == "AXSecureTextField" {
        return true
    }

    let haystack = labelParts
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

    guard !haystack.isEmpty else {
        return false
    }

    let sensitiveMarkers = [
        "password",
        "passcode",
        "passwd",
        "pwd",
        "token",
        "secret",
        "api key",
        "apikey",
        "access key",
        "private key",
        "credential",
        "auth code",
        "authorization",
    ]

    return sensitiveMarkers.contains { haystack.contains($0) }
}

func redactedActionInputSummary(_ value: String) -> String {
    guard !looksLikeSecretLiteral(value) else {
        return redactedSensitiveValue
    }
    return truncatedActionInputSummary(value)
}

func redactedAXValue(
    _ value: String,
    role: String?,
    labelParts: [String?]
) -> String {
    guard !shouldRedactSensitiveText(role: role, labelParts: labelParts) else {
        return redactedSensitiveValue
    }
    guard !looksLikeSecretLiteral(value) else {
        return redactedSensitiveValue
    }
    return value
}

private func truncatedActionInputSummary(_ value: String) -> String {
    value.count > 80 ? String(value.prefix(77)) + "..." : value
}

private func looksLikeSecretLiteral(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 20 else {
        return false
    }

    let lowered = trimmed.lowercased()
    if lowered.hasPrefix("sk-")
        || lowered.hasPrefix("sk_")
        || lowered.hasPrefix("xoxb-")
        || lowered.hasPrefix("ghp_")
        || lowered.hasPrefix("github_pat_") {
        return true
    }

    let compact = trimmed.filter { !$0.isWhitespace }
    let secretCharacterCount = compact.filter {
        $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/"
    }.count

    return compact.count >= 32 && secretCharacterCount == compact.count
}
