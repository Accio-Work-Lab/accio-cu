import Foundation
import Testing
@testable import AccioComputerUseKit

@Test("tool activity mapping distinguishes observation waiting and actions")
func toolActivityMappingDistinguishesPhases() throws {
    let appObservation = try #require(ToolActivityDescriptor(
        toolName: "get_app_state",
        arguments: ["app": "untrusted value"],
        resolvedTargetApp: "Safari"
    ))
    #expect(appObservation.phase == .observing)
    #expect(appObservation.actionKind == .readApp)
    #expect(appObservation.targetApp == "Safari")

    let screenObservation = try #require(ToolActivityDescriptor(
        toolName: "get_screen_state",
        arguments: [:]
    ))
    #expect(screenObservation.phase == .observing)
    #expect(screenObservation.actionKind == .readScreen)

    let waiting = try #require(ToolActivityDescriptor(
        toolName: "wait_for_element",
        arguments: ["app": "Safari", "element_text": "Private title"],
        resolvedTargetApp: "Safari"
    ))
    #expect(waiting.phase == .waiting)
    #expect(waiting.actionKind == .wait)

    let action = try #require(ToolActivityDescriptor(
        toolName: "click",
        arguments: ["app": "Safari", "element_text": "Private title"],
        resolvedTargetApp: "Safari"
    ))
    #expect(action.phase == .acting)
    #expect(action.actionKind == .click)
}

@Test("activity events never serialize tool arguments or typed values")
func activityEventsExcludeSensitiveArguments() throws {
    let descriptor = try #require(ToolActivityDescriptor(
        toolName: "type_text",
        arguments: [
            "app": "TextEdit",
            "text": "top-secret-value",
            "element_text": "Confidential field",
        ],
        resolvedTargetApp: "TextEdit"
    ))

    let event = descriptor.event()
    let payload = event.notificationUserInfo
    let serialized = String(describing: payload)

    #expect(event.actionKind == .typeText)
    #expect(event.targetApp == "TextEdit")
    #expect(!serialized.contains("top-secret-value"))
    #expect(!serialized.contains("Confidential field"))
    #expect(Set(payload.keys).isSubset(of: AutomationActivityEvent.allowedNotificationKeys))
}

@Test("activity event validation rejects stale unknown and oversized input")
func activityEventValidationRejectsUnsafeInput() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let descriptor = try #require(ToolActivityDescriptor(
        toolName: "get_app_state",
        arguments: ["app": "Safari"],
        resolvedTargetApp: "Safari"
    ))
    let valid = descriptor.event(timestamp: now)

    #expect(AutomationActivityEvent.validated(userInfo: valid.notificationUserInfo, now: now) == valid)

    var unknownSchema = valid.notificationUserInfo
    unknownSchema["schemaVersion"] = 99
    #expect(AutomationActivityEvent.validated(userInfo: unknownSchema, now: now) == nil)

    var stale = valid.notificationUserInfo
    stale["timestamp"] = now.addingTimeInterval(-120).timeIntervalSince1970
    #expect(AutomationActivityEvent.validated(userInfo: stale, now: now) == nil)

    var oversized = valid.notificationUserInfo
    oversized["targetApp"] = String(repeating: "a", count: 81)
    #expect(AutomationActivityEvent.validated(userInfo: oversized, now: now) == nil)
}

@Test("activity presentation is honest about snapshots and hides sensitive details")
func activityPresentationUsesHonestCaptureCopy() throws {
    let descriptor = try #require(ToolActivityDescriptor(
        toolName: "get_app_state",
        arguments: ["app": "/Users/alice/Private document", "element_text": "Private document"],
        resolvedTargetApp: "Safari"
    ))

    let axOnly = ActivityPresentation(event: descriptor.event(), isChinese: true)
    #expect(axOnly.message == "正在读取 Safari 界面")
    #expect(!axOnly.message.contains("录屏"))
    #expect(!axOnly.message.contains("Private document"))

    let snapshot = ActivityPresentation(
        event: descriptor.event(captureKind: .windowSnapshot),
        isChinese: true
    )
    #expect(snapshot.message == "正在读取 Safari 界面 · 按需截图")

    let action = ActivityPresentation(
        event: AutomationActivityEvent(
            phase: .acting,
            actionKind: .click,
            targetApp: "Safari",
            captureKind: .windowSnapshot
        ),
        isChinese: true
    )
    #expect(action.message == "正在操作 Safari · 按需截图")
}

@Test("activity disclosure describes an attempted snapshot before permission is known")
func activityDisclosureDoesNotDependOnPreflightPermission() throws {
    let windowRead = try #require(ToolActivityDescriptor(
        toolName: "get_app_state",
        arguments: ["app": "Safari"],
        resolvedTargetApp: "Safari"
    ))
    #expect(windowRead.anticipatedCaptureKind(arguments: ["app": "Safari"]) == .windowSnapshot)

    let screenRead = try #require(ToolActivityDescriptor(
        toolName: "get_screen_state",
        arguments: [:]
    ))
    #expect(screenRead.anticipatedCaptureKind(arguments: [:]) == .screenSnapshot)
}

@Test("Sensitive automation fails closed when the visible activity channel is unavailable")
func automationRequiresVisibleActivityChannel() {
    let dispatcher = ComputerUseToolDispatcher(
        activityPublisher: ActivitySocketClient(socketPath: "/tmp/accio-missing-activity.sock"),
        requiresVisibleActivity: true,
        activityListenerAvailable: { false }
    )

    let result = dispatcher.callToolAsResult(
        name: "get_screen_state",
        arguments: [:]
    )

    #expect(result.isError)
    #expect(result.primaryText?.contains("visible activity indicator") == true)
    #expect(result.primaryText?.contains("Open Accio Computer Use") == true)
}

@Test("Sensitive automation requires an activity delivery acknowledgement")
func automationRequiresActivityDeliveryAcknowledgement() {
    let socketPath = "/tmp/accio-missing-activity-\(UUID().uuidString).sock"
    let dispatcher = ComputerUseToolDispatcher(
        activityPublisher: ActivitySocketClient(socketPath: socketPath),
        requiresVisibleActivity: true,
        activityListenerAvailable: { true }
    )

    let result = dispatcher.callToolAsResult(
        name: "get_screen_state",
        arguments: [:]
    )

    #expect(result.isError)
    #expect(result.primaryText?.contains("visible activity indicator") == true)
}

@Test("activity descriptors never display an unresolved agent app query")
func activityDescriptorHidesUnresolvedAppQuery() throws {
    let descriptor = try #require(ToolActivityDescriptor(
        toolName: "get_app_state",
        arguments: ["app": "/Users/alice/Secret Project"]
    ))

    #expect(descriptor.targetApp == nil)
    #expect(!String(describing: descriptor.event().notificationUserInfo).contains("Secret Project"))
}

@Test("local pause state wins over delayed activity events")
func localPauseStateWinsOverActivityEvents() throws {
    let inFlight = AutomationActivityEvent(
        phase: .acting,
        actionKind: .click,
        targetApp: "Safari"
    )
    let reconciled = try #require(reconciledActivityEvent(inFlight, automationPaused: true))
    #expect(reconciled.phase == .paused)
    #expect(reconciled.targetApp == nil)

    let remotePause = AutomationActivityEvent(
        phase: .paused,
        actionKind: .readApp,
        targetApp: nil
    )
    #expect(reconciledActivityEvent(remotePause, automationPaused: false) == nil)
}

@Test("begin and completion events share one operation identity")
func activityEventsShareOperationIdentity() throws {
    let descriptor = try #require(ToolActivityDescriptor(
        toolName: "get_screen_state",
        arguments: [:]
    ))
    let begin = descriptor.event(captureKind: .screenSnapshot)
    let completed = descriptor.event(phase: .completed, captureKind: .screenSnapshot)

    #expect(begin.operationID == completed.operationID)
    #expect(begin.eventID != completed.eventID)
}
