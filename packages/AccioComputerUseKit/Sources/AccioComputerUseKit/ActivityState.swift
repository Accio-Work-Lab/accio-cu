import Foundation

public enum AutomationPhase: String, CaseIterable, Sendable {
    case observing
    case acting
    case waiting
    case completed
    case failed
    case paused
    case needsApproval
}

public enum AutomationActionKind: String, CaseIterable, Sendable {
    case listApps
    case readApp
    case readScreen
    case click
    case secondaryAction
    case scroll
    case drag
    case typeText
    case pressKey
    case setValue
    case wait
    case menuSelect
}

public enum AutomationCaptureKind: String, CaseIterable, Sendable {
    case none
    case windowSnapshot
    case screenSnapshot
}

public struct AutomationActivityEvent: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let allowedNotificationKeys: Set<String> = [
        "schemaVersion", "eventID", "phase", "actionKind", "targetApp",
        "captureKind", "operationID", "timestamp",
    ]

    public let eventID: UUID
    public let operationID: UUID
    public let phase: AutomationPhase
    public let actionKind: AutomationActionKind
    public let targetApp: String?
    public let captureKind: AutomationCaptureKind
    public let timestamp: Date

    public init(
        eventID: UUID = UUID(),
        operationID: UUID = UUID(),
        phase: AutomationPhase,
        actionKind: AutomationActionKind,
        targetApp: String?,
        captureKind: AutomationCaptureKind = .none,
        timestamp: Date = Date()
    ) {
        self.eventID = eventID
        self.operationID = operationID
        self.phase = phase
        self.actionKind = actionKind
        self.targetApp = targetApp.flatMap(sanitizedActivityLabel)
        self.captureKind = captureKind
        self.timestamp = timestamp
    }

    public var notificationUserInfo: [String: Any] {
        var values: [String: Any] = [
            "schemaVersion": Self.schemaVersion,
            "eventID": eventID.uuidString,
            "operationID": operationID.uuidString,
            "phase": phase.rawValue,
            "actionKind": actionKind.rawValue,
            "captureKind": captureKind.rawValue,
            "timestamp": timestamp.timeIntervalSince1970,
        ]
        if let targetApp { values["targetApp"] = targetApp }
        return values
    }

    public static func validated(userInfo: [String: Any], now: Date = Date()) -> Self? {
        guard Set(userInfo.keys).isSubset(of: allowedNotificationKeys),
              userInfo["schemaVersion"] as? Int == schemaVersion,
              let eventIDValue = userInfo["eventID"] as? String,
              let eventID = UUID(uuidString: eventIDValue),
              let operationIDValue = userInfo["operationID"] as? String,
              let operationID = UUID(uuidString: operationIDValue),
              let phaseValue = userInfo["phase"] as? String,
              let phase = AutomationPhase(rawValue: phaseValue),
              let actionValue = userInfo["actionKind"] as? String,
              let actionKind = AutomationActionKind(rawValue: actionValue),
              let captureValue = userInfo["captureKind"] as? String,
              let captureKind = AutomationCaptureKind(rawValue: captureValue),
              let timestampValue = userInfo["timestamp"] as? Double,
              timestampValue.isFinite else {
            return nil
        }

        let timestamp = Date(timeIntervalSince1970: timestampValue)
        guard now.timeIntervalSince(timestamp) <= 30,
              timestamp.timeIntervalSince(now) <= 5 else {
            return nil
        }

        let targetApp: String?
        if let rawTarget = userInfo["targetApp"] {
            guard let value = rawTarget as? String,
                  value.count <= 80,
                  sanitizedActivityLabel(value) == value else {
                return nil
            }
            targetApp = value
        } else {
            targetApp = nil
        }

        return Self(
            eventID: eventID,
            operationID: operationID,
            phase: phase,
            actionKind: actionKind,
            targetApp: targetApp,
            captureKind: captureKind,
            timestamp: timestamp
        )
    }
}

public struct ToolActivityDescriptor: Equatable, Sendable {
    public let phase: AutomationPhase
    public let actionKind: AutomationActionKind
    public let targetApp: String?
    public let operationID: UUID

    public init?(
        toolName: String,
        arguments _: [String: Any],
        resolvedTargetApp: String? = nil
    ) {
        let mapping: (AutomationPhase, AutomationActionKind)
        switch toolName {
        case "list_apps": mapping = (.observing, .listApps)
        case "get_app_state": mapping = (.observing, .readApp)
        case "get_screen_state": mapping = (.observing, .readScreen)
        case "click", "double_click", "hover": mapping = (.acting, .click)
        case "perform_secondary_action": mapping = (.acting, .secondaryAction)
        case "scroll": mapping = (.acting, .scroll)
        case "drag": mapping = (.acting, .drag)
        case "type_text": mapping = (.acting, .typeText)
        case "press_key": mapping = (.acting, .pressKey)
        case "set_value": mapping = (.acting, .setValue)
        case "wait_for_element": mapping = (.waiting, .wait)
        case "menu_select": mapping = (.acting, .menuSelect)
        default: return nil
        }

        phase = mapping.0
        actionKind = mapping.1
        targetApp = resolvedTargetApp.flatMap(sanitizedActivityLabel)
        operationID = UUID()
    }

    public func event(
        phase overridePhase: AutomationPhase? = nil,
        captureKind: AutomationCaptureKind = .none,
        timestamp: Date = Date()
    ) -> AutomationActivityEvent {
        AutomationActivityEvent(
            operationID: operationID,
            phase: overridePhase ?? phase,
            actionKind: actionKind,
            targetApp: targetApp,
            captureKind: captureKind,
            timestamp: timestamp
        )
    }

    public func anticipatedCaptureKind(arguments: [String: Any]) -> AutomationCaptureKind {
        // Disclose the intended on-demand snapshot before attempting it. A
        // permission preflight can be stale or differ from the eventual
        // capture path, and must never suppress the visible privacy signal.
        guard actionKind != .listApps else { return .none }
        if actionKind == .readScreen || ((actionKind == .click || actionKind == .drag) && arguments["app"] == nil) {
            return .screenSnapshot
        }
        return .windowSnapshot
    }
}

public struct ActivityPresentation: Equatable, Sendable {
    public let message: String
    public let symbolName: String

    public init(event: AutomationActivityEvent, isChinese: Bool) {
        let app = event.targetApp ?? (isChinese ? "屏幕" : "the screen")
        let screenshotSuffix: String
        if event.captureKind == .none {
            screenshotSuffix = ""
        } else if event.phase == .completed {
            screenshotSuffix = isChinese ? " · 已按需截图" : " · On-demand snapshot captured"
        } else {
            screenshotSuffix = isChinese ? " · 按需截图" : " · On-demand snapshot"
        }

        switch event.phase {
        case .observing:
            if event.actionKind == .readScreen {
                message = (isChinese ? "正在读取屏幕内容" : "Reading screen content") + screenshotSuffix
            } else {
                message = (isChinese ? "正在读取 \(app) 界面" : "Reading \(app)") + screenshotSuffix
            }
            symbolName = event.captureKind == .none ? "eye" : "viewfinder"
        case .acting:
            message = (isChinese ? "正在操作 \(app)" : "Controlling \(app)") + screenshotSuffix
            symbolName = "cursorarrow.click"
        case .waiting:
            message = (isChinese ? "正在等待 \(app) 响应" : "Waiting for \(app)") + screenshotSuffix
            symbolName = "ellipsis"
        case .completed:
            message = (isChinese ? "本次操作已完成" : "Operation completed") + screenshotSuffix
            symbolName = "checkmark.circle.fill"
        case .failed:
            message = isChinese ? "\(app) 操作失败" : "Action in \(app) failed"
            symbolName = "exclamationmark.triangle.fill"
        case .paused:
            message = isChinese ? "Accio 已暂停后续操作" : "Accio paused future actions"
            symbolName = "pause.fill"
        case .needsApproval:
            message = isChinese ? "Accio 需要你的确认" : "Accio needs your approval"
            symbolName = "hand.raised.fill"
        }
    }
}

func reconciledActivityEvent(
    _ event: AutomationActivityEvent,
    automationPaused: Bool
) -> AutomationActivityEvent? {
    if automationPaused {
        return AutomationActivityEvent(
            operationID: event.operationID,
            phase: .paused,
            actionKind: event.actionKind,
            targetApp: nil
        )
    }
    return event.phase == .paused ? nil : event
}

private func sanitizedActivityLabel(_ value: String) -> String? {
    let forbiddenScalars: Set<Unicode.Scalar> = [
        "\u{202A}", "\u{202B}", "\u{202D}", "\u{202E}", "\u{202C}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]
    let filteredScalars = value.unicodeScalars.filter { scalar in
        !CharacterSet.controlCharacters.contains(scalar) && !forbiddenScalars.contains(scalar)
    }
    let cleaned = String(String.UnicodeScalarView(filteredScalars))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return String(cleaned.prefix(80))
}
