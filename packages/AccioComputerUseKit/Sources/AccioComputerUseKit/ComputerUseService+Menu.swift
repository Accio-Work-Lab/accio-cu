import ApplicationServices
import Foundation

extension ComputerUseService {
    public func menuSelect(app: String, path: [String]) throws -> ToolCallResult {
        try AutomationPolicy().authorizeToolCall(named: "menu_select")
        guard !path.isEmpty else {
            throw ComputerUseError.invalidArguments("path must contain at least one menu title.")
        }

        return try preservingFrontmostApp {
            let snapshot = try refreshSnapshot(for: app, readOnly: true)
            let preState = ActionPreState(pid: snapshot.app.pid, fingerprint: structuralFingerprint(snapshot), snapshot: snapshot)
            let appElement = AXUIElementCreateApplication(snapshot.app.pid)
            guard let menuBar = copyMenuElement(appElement, attribute: kAXMenuBarAttribute as String) else {
                throw ComputerUseError.stateUnavailable("No menu bar available for \(snapshot.app.name).")
            }

            var currentContainer = menuBar
            var trace: [String] = []

            for (depth, component) in path.enumerated() {
                let children = copyChildren(of: currentContainer)
                guard let match = bestMenuMatch(component, in: children) else {
                    let available = children.compactMap(menuTitle(of:)).prefix(40).joined(separator: ", ")
                    throw ComputerUseError.invalidArguments(
                        "Menu path component '\(component)' not found at level \(depth). Available items: [\(available)]."
                    )
                }

                let title = menuTitle(of: match) ?? component
                trace.append(title)
                try AutomationPolicy().authorizeToolCall(named: "menu_select")
                let result = AXUIElementPerformAction(match, kAXPressAction as CFString)
                guard result == .success else {
                    throw ComputerUseError.message("AXPress failed for menu item '\(title)' with code \(result.rawValue).")
                }
                Thread.sleep(forTimeInterval: depth == path.count - 1 ? 0.2 : 0.12)

                if depth < path.count - 1 {
                    guard let submenu = waitForSubmenu(of: match) else {
                        throw ComputerUseError.stateUnavailable("Menu item '\(title)' did not expose a submenu.")
                    }
                    currentContainer = submenu
                }
            }

            waitUntilSettled(pid: snapshot.app.pid, maxWait: 2.0)
            let afterSnapshot = try refreshSnapshot(for: app, readOnly: true)
            let actionResult = ActionResultSummary.make(
                tool: "menu_select",
                target: path.joined(separator: " > "),
                route: "ax_menu_press",
                preState: preState,
                postSnapshot: afterSnapshot
            )
            let summary = actionResult.renderedLine
                + "\nSelected menu path: \(trace.joined(separator: " > "))."
            return actionObservationResult(
                before: snapshot,
                after: afterSnapshot,
                actionSummary: summary,
                actionMetadata: actionResult.structuredMetadata
            )
        }
    }

    private func waitForSubmenu(of item: AXUIElement) -> AXUIElement? {
        for _ in 0..<10 {
            if let children = copyChildren(of: item).first(where: {
                stringValue(of: $0, attribute: kAXRoleAttribute as String) == kAXMenuRole as String
            }) {
                return children
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func bestMenuMatch(_ requested: String, in items: [AXUIElement]) -> AXUIElement? {
        let normalizedRequest = normalizedMenuTitle(requested)
        return items.first { item in
            guard let title = menuTitle(of: item) else { return false }
            return normalizedMenuTitle(title) == normalizedRequest
        } ?? items.first { item in
            guard let title = menuTitle(of: item) else { return false }
            let normalizedTitle = normalizedMenuTitle(title)
            return normalizedTitle.contains(normalizedRequest) || normalizedRequest.contains(normalizedTitle)
        }
    }

    private func menuTitle(of item: AXUIElement) -> String? {
        stringValue(of: item, attribute: kAXTitleAttribute as String)
            ?? stringValue(of: item, attribute: kAXDescriptionAttribute as String)
    }

    private func normalizedMenuTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "…", with: "...")
            .replacingOccurrences(of: "⌘", with: "")
            .replacingOccurrences(of: "⇧", with: "")
            .replacingOccurrences(of: "⌥", with: "")
            .replacingOccurrences(of: "⌃", with: "")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func copyMenuElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        return (value as! AXUIElement)
    }
}
