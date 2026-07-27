import Foundation

enum BackgroundScrollStep: Equatable {
    case accessibilityPageAction
    case targetedWheel
    case targetedKeyboard
    case activationWheel
}

enum BackgroundScrollPolicy {
    static func steps(
        hasScrollablePoint: Bool,
        hasPageAction: Bool,
        pagesAreIntegral: Bool,
        canVerifyMovement: Bool
    ) -> [BackgroundScrollStep] {
        var result: [BackgroundScrollStep] = []

        if hasPageAction && pagesAreIntegral {
            result.append(.accessibilityPageAction)
        }

        if hasScrollablePoint {
            result.append(.targetedWheel)
        }

        // Keyboard scrolling is safe when posted to a pid. Include it whenever we
        // have a target — it acts as the final fallback for Electron and other apps
        // that silently ignore wheel events posted via CGEvent(postToPid:).
        if hasScrollablePoint {
            result.append(.targetedKeyboard)
        }

        // Escalate to a global HID scroll only after background delivery was
        // verifiably ineffective. This covers custom-rendered native apps that
        // do not match the Electron/Qt/Flutter bundle heuristics.
        if hasScrollablePoint && canVerifyMovement {
            result.append(.activationWheel)
        }

        return result
    }
}

enum ScrollContainerPolicy {
    private static let roles: Set<String> = [
        "AXScrollArea",
        "AXTable",
        "AXOutline",
        "AXList",
        "AXCollection",
    ]

    static func isContainerRole(_ role: String?) -> Bool {
        role.map(roles.contains) ?? false
    }
}

func scrollPositionChanged(before: CGPoint?, after: CGPoint?) -> Bool {
    guard let before, let after else { return false }
    return before != after
}
