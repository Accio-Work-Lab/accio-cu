import Foundation

enum BackgroundScrollStep: Equatable {
    case accessibilityPageAction
    case targetedWheel
    case targetedKeyboard
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

        return result
    }
}
