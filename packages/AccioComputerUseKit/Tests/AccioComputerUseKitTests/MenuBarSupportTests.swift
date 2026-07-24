import Testing
@testable import AccioComputerUseKit
import AppKit

@Test("Companion status reports ready only when permissions and daemon socket are available")
func companionStatusHealthRequiresPermissionsAndDaemonSocket() {
    let granted = PermissionDiagnostics(accessibilityTrusted: true, screenCaptureGranted: true)
    let missingPermission = PermissionDiagnostics(accessibilityTrusted: false, screenCaptureGranted: true)

    #expect(CompanionStatus(permissions: granted, daemonSocketExists: true).health == .ready)
    #expect(CompanionStatus(permissions: granted, daemonSocketExists: false).health == .daemonUnavailable)
    #expect(CompanionStatus(permissions: missingPermission, daemonSocketExists: true).health == .needsPermission)
    #expect(CompanionStatus(
        permissions: missingPermission,
        daemonSocketExists: true,
        automationPaused: true
    ).health == .needsPermission)
    #expect(CompanionStatus(
        permissions: granted,
        daemonSocketExists: true,
        activityChannelAvailable: false
    ).health == .activityUnavailable)
}

@MainActor
@Test("Initial app launch and Finder reopen always request a visible status window")
func appPresentationPolicyKeepsFinderLaunchVisible() {
    #expect(AppPresentationPolicy.shouldShowStatusWindow(for: .initialLaunch))
    #expect(AppPresentationPolicy.shouldShowStatusWindow(for: .reopen))

    var reopenCount = 0
    let delegate = AccioApplicationDelegate {
        reopenCount += 1
    }
    #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    #expect(reopenCount == 1)
}

@MainActor
@Test("Permission actions from the transient popover preserve a persistent control window")
func transientPermissionFlowPromotesPersistentControls() {
    var events: [String] = []
    let presenter = PermissionFlowPresenter(
        showPersistentControls: { events.append("show") },
        requestAuthorization: { events.append("request:\($0.rawValue)") },
        openSettings: { events.append("settings:\($0.rawValue)") }
    )

    presenter.request(.accessibility, from: .transientPopover)
    #expect(events == ["show", "request:accessibility"])

    events.removeAll()
    presenter.openSettings(.screenRecording, from: .transientPopover)
    #expect(events == ["show", "settings:screenRecording"])

    events.removeAll()
    presenter.request(.accessibility, from: .persistentWindow)
    #expect(events == ["request:accessibility"])
}

@Test("A newly granted permission restores only a hidden Accio control window")
func permissionGrantTransitionRestoresControlWindow() {
    let missingBoth = PermissionDiagnostics(accessibilityTrusted: false, screenCaptureGranted: false)
    let accessibilityGranted = PermissionDiagnostics(accessibilityTrusted: true, screenCaptureGranted: false)
    let allGranted = PermissionDiagnostics(accessibilityTrusted: true, screenCaptureGranted: true)

    #expect(!PermissionFlowPresentationPolicy.shouldRestoreWindow(
        previous: nil,
        current: missingBoth,
        windowIsVisible: false,
        windowIsMiniaturized: false
    ))
    #expect(PermissionFlowPresentationPolicy.shouldRestoreWindow(
        previous: missingBoth,
        current: accessibilityGranted,
        windowIsVisible: false,
        windowIsMiniaturized: false
    ))
    #expect(PermissionFlowPresentationPolicy.shouldRestoreWindow(
        previous: accessibilityGranted,
        current: allGranted,
        windowIsVisible: true,
        windowIsMiniaturized: true
    ))
    #expect(!PermissionFlowPresentationPolicy.shouldRestoreWindow(
        previous: accessibilityGranted,
        current: allGranted,
        windowIsVisible: true,
        windowIsMiniaturized: false
    ))
    #expect(!PermissionFlowPresentationPolicy.shouldRestoreWindow(
        previous: allGranted,
        current: allGranted,
        windowIsVisible: false,
        windowIsMiniaturized: false
    ))
}

@MainActor
@Test("Screen Recording grant schedules exactly one helper relaunch")
func screenRecordingGrantSchedulesOneRelaunch() {
    var permissions = PermissionDiagnostics(
        accessibilityTrusted: true,
        screenCaptureGranted: false
    )
    var relaunchCount = 0
    let controller = StatusWindowController(
        permissionProvider: { permissions },
        language: .english,
        relaunchAfterScreenRecordingGrant: {
            relaunchCount += 1
            return true
        }
    )
    _ = controller.makeWindow()

    permissions = PermissionDiagnostics(
        accessibilityTrusted: true,
        screenCaptureGranted: true
    )
    controller.refreshPermissionStatus()
    controller.refreshPermissionStatus()

    #expect(relaunchCount == 1)
}

@MainActor
@Test("Accessibility grant does not restart the helper")
func accessibilityGrantDoesNotRestartHelper() {
    var permissions = PermissionDiagnostics(
        accessibilityTrusted: false,
        screenCaptureGranted: true
    )
    var relaunchCount = 0
    let controller = StatusWindowController(
        permissionProvider: { permissions },
        language: .english,
        relaunchAfterScreenRecordingGrant: {
            relaunchCount += 1
            return true
        }
    )
    _ = controller.makeWindow()

    permissions = PermissionDiagnostics(
        accessibilityTrusted: true,
        screenCaptureGranted: true
    )
    controller.refreshPermissionStatus()

    #expect(relaunchCount == 0)
}

@MainActor
@Test("Status window is recentered only when effectively off screen")
func statusWindowPlacementRecoversDisconnectedDisplays() {
    let mainScreen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
    #expect(StatusWindowController.isWindowFrameVisible(
        NSRect(x: 100, y: 100, width: 480, height: 710),
        on: [mainScreen]
    ))
    #expect(!StatusWindowController.isWindowFrameVisible(
        NSRect(x: 2200, y: -900, width: 480, height: 710),
        on: [mainScreen]
    ))
    #expect(!StatusWindowController.isWindowFrameVisible(
        NSRect(x: 1700, y: 1100, width: 480, height: 710),
        on: [mainScreen]
    ))
}

@Test("A stale daemon socket file is not reported as a running daemon")
func staleDaemonSocketIsNotAvailable() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("accio-stale-daemon-\(UUID().uuidString)", isDirectory: true)
    let socketURL = directory.appendingPathComponent("daemon.sock")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("stale".utf8).write(to: socketURL)

    let status = CompanionStatus.current(socketPath: socketURL.path)
    #expect(!status.daemonSocketExists)
}

@Test("Companion status summaries guide menu bar setup")
func companionStatusSummariesGuideMenuBarSetup() {
    let granted = PermissionDiagnostics(accessibilityTrusted: true, screenCaptureGranted: true)
    let missingBoth = PermissionDiagnostics(accessibilityTrusted: false, screenCaptureGranted: false)

    let ready = CompanionStatus(permissions: granted, daemonSocketExists: true)
    #expect(ready.permissionSummary == "All permissions granted")
    #expect(ready.daemonSummary == "Daemon socket available")
    #expect(ready.setupSummary == "Ready for CLI and MCP clients.")

    let needsPermission = CompanionStatus(permissions: missingBoth, daemonSocketExists: true)
    #expect(needsPermission.permissionSummary == "Missing Accessibility, Screen Recording")
    #expect(needsPermission.setupSummary == "Grant the missing permissions to enable desktop automation.")

    let daemonUnavailable = CompanionStatus(permissions: granted, daemonSocketExists: false)
    #expect(daemonUnavailable.daemonSummary == "Daemon not running")
    #expect(daemonUnavailable.setupSummary == "Start a session daemon or use stdio MCP directly.")

    let paused = CompanionStatus(
        permissions: granted,
        daemonSocketExists: true,
        automationPaused: true
    )
    #expect(paused.shortLabel == "Paused")
    #expect(paused.setupSummary.contains("paused by the user"))
}

@Test("MCP configuration snippet uses the stdio server command")
func mcpConfigurationSnippetUsesStdioServerCommand() {
    #expect(MCPConfigurationSnippet.text.contains("\"command\": \"accio-computer-use\""))
    #expect(MCPConfigurationSnippet.text.contains("\"args\": [\"mcp\"]"))
}

@Test("Quick command clipboard text includes common diagnostics and MCP commands")
func quickCommandClipboardTextIncludesCommonDiagnosticsAndMCPCommands() {
    #expect(CompanionClipboardText.quickCommands.contains("accio-computer-use setup"))
    #expect(CompanionClipboardText.quickCommands.contains("accio-computer-use doctor"))
    #expect(CompanionClipboardText.quickCommands.contains("accio-computer-use mcp"))
    #expect(CompanionClipboardText.quickCommands.contains("accio-computer-use call list_apps"))
}

@MainActor
@Test("Menu bar popover uses a vertical scroll view for overflowing content")
func menuBarPopoverUsesVerticalScrollViewForOverflowingContent() {
    let controller = MenuBarPopoverViewController(
        socketPath: "/tmp/accio-computer-use-test.sock",
        detailController: StatusWindowController()
    )

    controller.loadView()

    let scrollView = controller.view.subviews.compactMap { $0 as? NSScrollView }.first
    #expect(scrollView != nil)
    #expect(scrollView?.hasVerticalScroller == true)
    #expect(scrollView?.documentView is NSStackView)
}

@MainActor
@Test("Menu bar popover height is clamped to the visible screen frame")
func menuBarPopoverHeightIsClampedToVisibleScreenFrame() {
    let contentSize = MenuBarPopoverViewController.contentSize(
        forVisibleFrame: NSRect(x: 0, y: 0, width: 390, height: 360)
    )

    #expect(contentSize.width == MenuBarPopoverViewController.defaultContentSize.width)
    #expect(contentSize.height == 328)
}

@MainActor
@Test("Menu bar icon is a macOS template image")
func menuBarIconIsTemplateImage() {
    let icon = MenuBarIconProvider.icon(accessibilityDescription: "Ready")

    #expect(icon != nil)
    #expect(icon?.isTemplate == true)
    #expect(icon?.size == NSSize(width: 18, height: 18))
    #expect(icon?.accessibilityDescription == "Ready")
    #expect((MenuBarIconProvider.previewTemplateIconPNGData()?.count ?? 0) > 0)
}

@MainActor
@Test("Every state keeps the Accio brand icon in the menu bar")
func menuBarHealthStatesKeepProductIdentity() {
    let english = MenuBarCopy(language: .english)
    for health in CompanionHealth.allCases {
        #expect(MenuBarIconProvider.kind(for: health) == .brand)
        let accessibilityDescription = english.statusAccessibilityDescription(for: health)
        let icon = MenuBarIconProvider.icon(
            for: health,
            accessibilityDescription: accessibilityDescription
        )
        #expect(icon != nil)
        #expect(icon?.isTemplate == true)
        #expect(icon?.size == NSSize(width: 18, height: 18))
        #expect(icon?.accessibilityDescription == accessibilityDescription)
    }
}

@Test("Menu bar language selection is deterministic")
func menuBarLanguageSelectionIsDeterministic() {
    #expect(MenuBarLanguage(preferredLanguages: ["zh-Hans-CN"]) == .chinese)
    #expect(MenuBarLanguage(preferredLanguages: ["zh-Hant-TW"]) == .chinese)
    #expect(MenuBarLanguage(preferredLanguages: ["en-US"]) == .english)
    #expect(MenuBarLanguage(preferredLanguages: ["ja-JP", "zh-Hans-CN"]) == .chinese)
    #expect(MenuBarLanguage(preferredLanguages: ["ja-JP", "en-US"]) == .english)
    #expect(MenuBarLanguage(preferredLanguages: []) == .english)
}

@MainActor
@Test("Detail window and menu popover use the same language resolver")
func detailWindowUsesSharedLanguageResolver() {
    let language = MenuBarLanguage(preferredLanguages: ["ja-JP", "zh-Hans-CN"])
    let controller = StatusWindowController(
        permissionProvider: {
            PermissionDiagnostics(accessibilityTrusted: true, screenCaptureGranted: true)
        },
        language: language
    )
    let labels = textFields(in: controller.makeWindow().contentView).map(\.stringValue)
    #expect(labels.contains("权限状态"))
    #expect(!labels.contains("Permission Status"))
}

@Test("Menu bar copy covers every state in Chinese and English")
func menuBarCopyCoversEveryHealthState() {
    let english = MenuBarCopy(language: .english)
    let chinese = MenuBarCopy(language: .chinese)

    #expect(english.shortLabel(for: .ready) == "Ready")
    #expect(chinese.shortLabel(for: .ready) == "已就绪")
    #expect(english.shortLabel(for: .paused) == "Paused")
    #expect(chinese.shortLabel(for: .paused) == "已暂停")
    #expect(english.shortLabel(for: .needsPermission) == "Needs Permission")
    #expect(chinese.shortLabel(for: .needsPermission) == "需要授权")
    #expect(english.shortLabel(for: .activityUnavailable) == "Indicator Off")
    #expect(chinese.shortLabel(for: .activityUnavailable) == "状态指示不可用")
    #expect(english.shortLabel(for: .daemonUnavailable) == "Background Service Off")
    #expect(chinese.shortLabel(for: .daemonUnavailable) == "后台服务未运行")

    for health in CompanionHealth.allCases {
        #expect(!english.setupSummary(for: health).isEmpty)
        #expect(!chinese.setupSummary(for: health).isEmpty)
        #expect(english.shortLabel(for: health) != chinese.shortLabel(for: health))
        #expect(english.statusAccessibilityDescription(for: health).hasPrefix("Accio Computer Use — "))
        #expect(chinese.statusAccessibilityDescription(for: health).hasPrefix("Accio Computer Use — "))
    }
}

@MainActor
@Test("Chinese menu bar popover does not retain English control labels")
func chineseMenuBarPopoverUsesOneLanguage() {
    let controller = MenuBarPopoverViewController(
        socketPath: "/tmp/accio-localization-ui-test.sock",
        detailController: StatusWindowController(),
        language: .chinese
    )
    controller.loadView()
    controller.refresh(with: CompanionStatus(
        permissions: PermissionDiagnostics(
            accessibilityTrusted: false,
            screenCaptureGranted: false
        ),
        daemonSocketExists: false
    ))

    let buttonTitles = Set(buttons(in: controller.view).map(\.title))
    let labels = textFields(in: controller.view).map(\.stringValue)
    #expect(buttonTitles.contains("请求授权"))
    #expect(buttonTitles.contains("打开设置"))
    #expect(buttonTitles.contains("暂停后续操作"))
    #expect(buttonTitles.contains("需要辅助功能授权"))
    #expect(!buttonTitles.contains("Request"))
    #expect(!buttonTitles.contains("Open Settings"))
    #expect(!buttonTitles.contains("Pause Future Actions"))
    #expect(labels.contains("权限"))
    #expect(labels.contains("辅助功能未授权"))
    #expect(labels.contains("屏幕录制未授权"))
    #expect(labels.contains("后台服务"))
    #expect(labels.contains("工具"))
    #expect(labels.contains("设置"))

    let setup = textFields(in: controller.view).first {
        $0.stringValue == "请先完成缺失授权，再启用桌面自动化。"
    }
    #expect(setup?.cell?.wraps == true)
}

@MainActor
@Test("Both native UI surfaces expose all permission recovery controls")
func permissionControlsHaveStableAccessibilityIdentifiers() {
    let detailController = StatusWindowController()
    let statusWindow = detailController.makeWindow()
    let popover = MenuBarPopoverViewController(
        socketPath: "/tmp/accio-permission-ui-test.sock",
        detailController: detailController
    )
    popover.loadView()

    let expected = Set(PermissionControlIdentifier.allCases.map(\.rawValue))
    let statusIdentifiers = Set(buttonIdentifiers(in: statusWindow.contentView))
    let popoverIdentifiers = Set(buttonIdentifiers(in: popover.view))
    #expect(expected.isSubset(of: statusIdentifiers))
    #expect(expected.isSubset(of: popoverIdentifiers))
}

@MainActor
@Test("Permission controls cover fresh install denied and granted states")
func permissionControlsReflectEveryAuthorizationState() throws {
    let missing = PermissionDiagnostics(accessibilityTrusted: false, screenCaptureGranted: false)
    let granted = PermissionDiagnostics(accessibilityTrusted: true, screenCaptureGranted: true)

    let missingController = StatusWindowController(permissionProvider: { missing })
    let missingWindow = missingController.makeWindow()
    let missingButtons = buttons(in: missingWindow.contentView)
    for identifier in PermissionControlIdentifier.allCases {
        let button = try #require(missingButtons.first {
            $0.identifier?.rawValue == identifier.rawValue
        })
        #expect(!button.isHidden)
        #expect(button.isEnabled)
    }

    let grantedController = StatusWindowController(permissionProvider: { granted })
    let grantedWindow = grantedController.makeWindow()
    let grantedButtons = buttons(in: grantedWindow.contentView)
    for identifier in PermissionControlIdentifier.allCases {
        let button = try #require(grantedButtons.first {
            $0.identifier?.rawValue == identifier.rawValue
        })
        #expect(button.isHidden)
    }
}

@MainActor
@Test("Session daemon start is disabled until Accessibility is granted")
func sessionDaemonRequiresAccessibility() throws {
    let controller = MenuBarPopoverViewController(
        socketPath: "/tmp/accio-daemon-ui-test.sock",
        detailController: StatusWindowController(),
        language: .english
    )
    controller.loadView()
    controller.refresh(with: CompanionStatus(
        permissions: PermissionDiagnostics(
            accessibilityTrusted: false,
            screenCaptureGranted: true
        ),
        daemonSocketExists: false
    ))

    let button = try #require(buttons(in: controller.view).first {
        $0.identifier?.rawValue == "daemon.session.toggle"
    })
    #expect(!button.isEnabled)
    #expect(button.title == "Accessibility Required")
}

@Test("Session daemon failures produce bounded visible copy")
func sessionDaemonFailureCopyIsBounded() throws {
    #expect(SessionDaemonTerminationCopy.message(exitStatus: 0, language: .english) == nil)
    let english = try #require(SessionDaemonTerminationCopy.message(
        exitStatus: 1,
        language: .english
    ))
    let chinese = try #require(SessionDaemonTerminationCopy.message(
        exitStatus: 1,
        language: .chinese
    ))
    #expect(
        english
            == "The session service exited with status 1. Restart the helper or run accio-computer-use doctor."
    )
    #expect(
        chinese
            == "本次后台服务已退出（状态码 1）。请重启助手，或运行 accio-computer-use doctor。"
    )
}

@Test("Session service stderr cannot block on an unread pipe")
func sessionDaemonDoesNotUseAnUnreadErrorPipe() throws {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../Sources/AccioComputerUseKit/MenuBarController.swift")
        .standardizedFileURL
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    #expect(source.contains("process.standardError = FileHandle.nullDevice"))
    #expect(!source.contains("let errorPipe = Pipe()"))
}

@MainActor
private func buttonIdentifiers(in root: NSView?) -> [String] {
    guard let root else { return [] }
    let own: [String]
    if let identifier = (root as? NSButton)?.identifier?.rawValue {
        own = [identifier]
    } else {
        own = []
    }
    return own + root.subviews.flatMap { buttonIdentifiers(in: $0) }
}


@MainActor
private func buttons(in root: NSView?) -> [NSButton] {
    guard let root else { return [] }
    let own = (root as? NSButton).map { [$0] } ?? []
    return own + root.subviews.flatMap { buttons(in: $0) }
}

@MainActor
private func textFields(in root: NSView?) -> [NSTextField] {
    guard let root else { return [] }
    let own = (root as? NSTextField).map { [$0] } ?? []
    return own + root.subviews.flatMap { textFields(in: $0) }
}
