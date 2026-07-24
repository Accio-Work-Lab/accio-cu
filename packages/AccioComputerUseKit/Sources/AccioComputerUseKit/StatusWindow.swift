import AppKit
import Foundation

/// A lightweight status window shown when the app is launched from Finder
/// (no CLI arguments). Displays permission status, settings, and usage instructions.
@MainActor
public final class StatusWindowController {
    private let permissionProvider: () -> PermissionDiagnostics
    private let language: MenuBarLanguage
    private let relaunchAfterScreenRecordingGrant: () -> Bool
    private var window: NSWindow?
    private var terminatesOnClose = false
    private var isChinese: Bool { language == .chinese }

    // References for live-updating permission UI
    private var accessibilityStatusLabel: NSTextField?
    private var accessibilityButtons: [NSButton] = []
    private var screenRecordingStatusLabel: NSTextField?
    private var screenRecordingButtons: [NSButton] = []
    private var automationStatusLabel: NSTextField?
    private var automationButton: NSButton?
    private var lastPermissions: PermissionDiagnostics?
    fileprivate var pollTimer: Timer?

    public convenience init() {
        self.init(permissionProvider: PermissionDiagnostics.current, language: .current)
    }

    init(
        permissionProvider: @escaping () -> PermissionDiagnostics,
        language: MenuBarLanguage = .current,
        relaunchAfterScreenRecordingGrant: @escaping () -> Bool = {
            HelperRelauncher.relaunchCurrentAppBundle()
        }
    ) {
        self.permissionProvider = permissionProvider
        self.language = language
        self.relaunchAfterScreenRecordingGrant = relaunchAfterScreenRecordingGrant
    }

    /// Shows the status window and runs the app event loop.
    /// This method does not return until the window is closed.
    public func runModal() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        terminatesOnClose = true
        showWindow()

        app.run()
    }

    public func showWindow() {
        let window = self.window ?? makeWindow()
        self.window = window

        present(window)

        startPermissionPolling()
        refreshPermissionStatus()
    }

    private func present(_ window: NSWindow) {
        if !window.isVisible || !Self.isWindowFrameVisible(window.frame, on: NSScreen.screens.map(\.visibleFrame)) {
            window.center()
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func isWindowFrameVisible(_ frame: NSRect, on screenFrames: [NSRect]) -> Bool {
        screenFrames.contains { screenFrame in
            let intersection = frame.intersection(screenFrame)
            return !intersection.isNull && intersection.width >= 120 && intersection.height >= 80
        }
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 710),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Accio Computer Use"
        window.isReleasedWhenClosed = false
        window.sharingType = .none
        let closeDelegate = WindowCloseDelegate.shared
        closeDelegate.controller = self
        window.delegate = closeDelegate
        PermissionButtonTarget.shared.controller = self
        AutomationControlTarget.shared.controller = self

        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let documentView = StatusDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -24),
        ])

        // Header
        stack.addArrangedSubview(makeHeader())

        // Separator
        stack.addArrangedSubview(makeSeparator())

        // Permission status
        stack.addArrangedSubview(makePermissionSection())

        // Separator
        stack.addArrangedSubview(makeSeparator())

        // Local kill switch
        stack.addArrangedSubview(makeAutomationSection())

        // Separator
        stack.addArrangedSubview(makeSeparator())

        // Settings
        stack.addArrangedSubview(makeSettingsSection())

        // Separator
        stack.addArrangedSubview(makeSeparator())

        // Usage instructions
        stack.addArrangedSubview(makeUsageSection())

        window.contentView = scrollView
        return window
    }

    private func makeHeader() -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 12

        if let appIcon = NSApp.applicationIconImage {
            let imageView = NSImageView(image: appIcon)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 48),
                imageView.heightAnchor.constraint(equalToConstant: 48),
            ])
            container.addArrangedSubview(imageView)
        }

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let titleLabel = NSTextField(labelWithString: "Accio Computer Use")
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleStack.addArrangedSubview(titleLabel)

        let versionLabel = NSTextField(labelWithString: "v\(resolvedVersion())")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        titleStack.addArrangedSubview(versionLabel)

        container.addArrangedSubview(titleStack)
        return container
    }

    private func makePermissionSection() -> NSView {
        let permissions = permissionProvider()
        lastPermissions = permissions
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8

        let sectionTitle = NSTextField(labelWithString: isChinese ? "权限状态" : "Permission Status")
        sectionTitle.font = .boldSystemFont(ofSize: 13)
        section.addArrangedSubview(sectionTitle)

        section.addArrangedSubview(
            makePermissionRow(
                name: isChinese ? "辅助功能" : "Accessibility",
                granted: permissions.accessibilityTrusted,
                permission: .accessibility
            )
        )
        section.addArrangedSubview(
            makePermissionRow(
                name: isChinese ? "屏幕录制" : "Screen Recording",
                granted: permissions.screenCaptureGranted,
                permission: .screenRecording
            )
        )

        let explanation = NSTextField(
            wrappingLabelWithString: PrivacyCopy.screenRecordingExplanation(isChinese: isChinese)
        )
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 400
        section.addArrangedSubview(explanation)

        return section
    }

    private func makeAutomationSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8

        let title = NSTextField(labelWithString: isChinese ? "自动化控制" : "Automation Control")
        title.font = .boldSystemFont(ofSize: 13)
        section.addArrangedSubview(title)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 13)
        row.addArrangedSubview(status)
        automationStatusLabel = status

        let button = NSButton(
            title: "",
            target: AutomationControlTarget.shared,
            action: #selector(AutomationControlTarget.toggleAutomation)
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        row.addArrangedSubview(button)
        automationButton = button
        section.addArrangedSubview(row)

        let explanation = NSTextField(wrappingLabelWithString: isChinese
            ? "暂停会立即阻止新的观察和操作请求；恢复只能由本机用户在 Accio 控制界面执行。"
            : "Pause blocks new observation and action requests. Only a local user can resume from an Accio control surface.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 400
        section.addArrangedSubview(explanation)

        refreshAutomationStatus()
        return section
    }

    private func makePermissionRow(name: String, granted: Bool, permission: SystemPermissionKind) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let state = permissionStateLabel(granted: granted)
        let indicator = granted ? "\u{2705}" : "\u{274C}"
        let statusLabel = NSTextField(labelWithString: "\(indicator)  \(name) — \(state)")
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.setAccessibilityLabel(name)
        statusLabel.setAccessibilityValue(state)
        row.addArrangedSubview(statusLabel)

        let requestButton = NSButton(
            title: isChinese ? "请求授权" : "Request",
            target: PermissionButtonTarget.shared,
            action: #selector(PermissionButtonTarget.requestPermission(_:))
        )
        requestButton.bezelStyle = .rounded
        requestButton.controlSize = .small
        requestButton.tag = permission == .accessibility ? 0 : 1
        requestButton.identifier = NSUserInterfaceItemIdentifier(
            PermissionControlIdentifier.request(for: permission).rawValue
        )
        requestButton.isHidden = granted
        row.addArrangedSubview(requestButton)

        let settingsButton = NSButton(
            title: isChinese ? "打开设置" : "Open Settings",
            target: PermissionButtonTarget.shared,
            action: #selector(PermissionButtonTarget.openPermissionSettings(_:))
        )
        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .small
        settingsButton.tag = permission == .accessibility ? 0 : 1
        settingsButton.identifier = NSUserInterfaceItemIdentifier(
            PermissionControlIdentifier.settings(for: permission).rawValue
        )
        settingsButton.isHidden = granted
        row.addArrangedSubview(settingsButton)

        // Save references for live updates
        switch permission {
        case .accessibility:
            accessibilityStatusLabel = statusLabel
            accessibilityButtons = [requestButton, settingsButton]
        case .screenRecording:
            screenRecordingStatusLabel = statusLabel
            screenRecordingButtons = [requestButton, settingsButton]
        }

        return row
    }

    private func startPermissionPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissionStatus()
            }
        }
    }

    func refreshPermissionStatus() {
        PermissionDiagnostics.invalidateCache()
        let permissions = permissionProvider()
        let screenRecordingWasJustGranted = lastPermissions?.screenCaptureGranted == false
            && permissions.screenCaptureGranted
        let shouldRestoreWindow = PermissionFlowPresentationPolicy.shouldRestoreWindow(
            previous: lastPermissions,
            current: permissions,
            windowIsVisible: window?.isVisible == true,
            windowIsMiniaturized: window?.isMiniaturized == true
        )
        lastPermissions = permissions
        updatePermissionRow(
            statusLabel: accessibilityStatusLabel,
            buttons: accessibilityButtons,
            name: isChinese ? "辅助功能" : "Accessibility",
            granted: permissions.accessibilityTrusted
        )
        updatePermissionRow(
            statusLabel: screenRecordingStatusLabel,
            buttons: screenRecordingButtons,
            name: isChinese ? "屏幕录制" : "Screen Recording",
            granted: permissions.screenCaptureGranted
        )
        refreshAutomationStatus()
        if screenRecordingWasJustGranted, relaunchAfterScreenRecordingGrant() {
            return
        }
        if shouldRestoreWindow, let window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            // Keep the control surface recoverable without stealing focus from
            // System Settings while the user grants the remaining permission.
            window.orderFront(nil)
        }
    }

    fileprivate func refreshAutomationStatus() {
        let paused = AutomationPauseStore.shared.isPaused
        automationStatusLabel?.stringValue = paused
            ? (isChinese ? "⏸ 已暂停" : "⏸ Paused")
            : (isChinese ? "● 运行中" : "● Running")
        automationButton?.title = paused
            ? (isChinese ? "恢复" : "Resume")
            : (isChinese ? "暂停后续操作" : "Pause Future Actions")
    }

    fileprivate func handleWindowClose() {
        pollTimer?.invalidate()
        pollTimer = nil
        if terminatesOnClose {
            NSApp.terminate(nil)
        }
    }

    private func updatePermissionRow(statusLabel: NSTextField?, buttons: [NSButton], name: String, granted: Bool) {
        let state = permissionStateLabel(granted: granted)
        let indicator = granted ? "\u{2705}" : "\u{274C}"
        statusLabel?.stringValue = "\(indicator)  \(name) — \(state)"
        statusLabel?.setAccessibilityValue(state)
        buttons.forEach { $0.isHidden = granted }
    }

    private func permissionStateLabel(granted: Bool) -> String {
        if isChinese {
            return granted ? "已授权" : "未授权"
        }
        return granted ? "Granted" : "Missing"
    }


    private func makeUsageSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6

        let sectionTitle = NSTextField(labelWithString: isChinese ? "使用方式" : "How to Use")
        sectionTitle.font = .boldSystemFont(ofSize: 13)
        section.addArrangedSubview(sectionTitle)

        let commands: [(String, String)] = [
            (isChinese ? "首次设置：" : "First-run setup:", "accio-computer-use setup"),
            (isChinese ? "MCP 服务：" : "MCP server:", "accio-computer-use mcp"),
            (isChinese ? "CLI 调用：" : "CLI call:", "accio-computer-use call <tool> '<json>'"),
            (isChinese ? "诊断：" : "Diagnose:", "accio-computer-use doctor"),
            (isChinese ? "列出应用：" : "List apps:", "accio-computer-use list-apps"),
        ]

        for (label, command) in commands {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6

            let labelField = NSTextField(labelWithString: label)
            labelField.font = .systemFont(ofSize: 12)
            labelField.textColor = .secondaryLabelColor
            labelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            row.addArrangedSubview(labelField)

            let commandField = NSTextField(labelWithString: command)
            commandField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            commandField.isSelectable = true
            row.addArrangedSubview(commandField)

            section.addArrangedSubview(row)
        }

        return section
    }

    private func makeSettingsSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8

        let sectionTitle = NSTextField(labelWithString: isChinese ? "设置" : "Settings")
        sectionTitle.font = .boldSystemFont(ofSize: 13)
        section.addArrangedSubview(sectionTitle)

        // Prefer background mode checkbox
        let bgMode = preferBackgroundOperations
        let bgCheckbox = NSButton(
            checkboxWithTitle: isChinese
                ? "优先后台操作"
                : "Prefer background mode",
            target: SettingsTarget.shared,
            action: #selector(SettingsTarget.toggleBackgroundMode(_:))
        )
        bgCheckbox.state = bgMode ? .on : .off
        section.addArrangedSubview(bgCheckbox)

        let bgDescription = NSTextField(wrappingLabelWithString: isChinese
            ? "尽量在后台完成操作，避免切换前台焦点。对于 Electron/CEF/Qt 等应用，必要时仍会短暂激活以确保操作成功。"
            : "Prefer background operations to avoid stealing foreground focus. For Electron/CEF/Qt apps, may briefly activate when necessary.")
        bgDescription.font = .systemFont(ofSize: 11)
        bgDescription.textColor = .secondaryLabelColor
        bgDescription.preferredMaxLayoutWidth = 400
        section.addArrangedSubview(bgDescription)

        // Toast notification checkbox
        let toastEnabled = !UserDefaults.standard.bool(forKey: "com.accio.computeruse.disableActivationToast")
        let toastCheckbox = NSButton(
            checkboxWithTitle: isChinese
                ? "切换前台操作前提醒（\(ActivationToast.countdownSeconds) 秒倒计时）"
                : "Notify before switching to foreground mode (\(ActivationToast.countdownSeconds)s)",
            target: SettingsTarget.shared,
            action: #selector(SettingsTarget.toggleToast(_:))
        )
        toastCheckbox.state = toastEnabled ? .on : .off
        section.addArrangedSubview(toastCheckbox)

        let toastDescription = NSTextField(wrappingLabelWithString: isChinese
            ? "Electron/CEF/Qt 应用有时需要短暂切换到前台。开启后会显示可取消的倒计时提示。"
            : "Electron/CEF/Qt apps sometimes need brief foreground activation. When enabled, a cancellable countdown appears before switching.")
        toastDescription.font = .systemFont(ofSize: 11)
        toastDescription.textColor = .secondaryLabelColor
        toastDescription.preferredMaxLayoutWidth = 400
        section.addArrangedSubview(toastDescription)

        let restartButton = NSButton(
            title: isChinese ? "重启菜单栏助手" : "Restart Menu Bar Helper",
            target: SettingsTarget.shared,
            action: #selector(SettingsTarget.restartHelper)
        )
        restartButton.bezelStyle = .rounded
        restartButton.controlSize = .regular
        section.addArrangedSubview(restartButton)

        let restartDescription = NSTextField(wrappingLabelWithString: isChinese
            ? "授权屏幕录制后，请重启助手，让 macOS 对当前进程应用新权限。"
            : "After granting Screen Recording, restart the helper so macOS applies the new permission to this process.")
        restartDescription.font = .systemFont(ofSize: 11)
        restartDescription.textColor = .secondaryLabelColor
        restartDescription.preferredMaxLayoutWidth = 400
        section.addArrangedSubview(restartDescription)

        return section
    }

    private func makeSeparator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 432),
        ])
        return separator
    }
}

// MARK: - Helpers

private final class StatusDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SettingsTarget: NSObject {
    static let shared = SettingsTarget()

    @objc func toggleBackgroundMode(_ sender: NSButton) {
        let enabled = (sender.state == .on)
        UserDefaults.standard.set(enabled, forKey: preferBackgroundModeDefaultsKey)
    }

    @objc func toggleToast(_ sender: NSButton) {
        let disabled = (sender.state == .off)
        UserDefaults.standard.set(disabled, forKey: "com.accio.computeruse.disableActivationToast")
    }

    @objc func restartHelper() {
        guard HelperRelauncher.relaunchCurrentAppBundle() else {
            let copy = MenuBarCopy(language: .current)
            let alert = NSAlert()
            alert.messageText = "Accio Computer Use"
            alert.informativeText = copy.relaunchFailed
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
    }
}

@MainActor
private final class AutomationControlTarget: NSObject {
    static let shared = AutomationControlTarget()
    weak var controller: StatusWindowController?

    @objc func toggleAutomation() {
        let store = AutomationPauseStore.shared
        do {
            try store.setPaused(!store.isPaused)
            if store.isPaused {
                ActivitySocketClient.shared.publish(
                    AutomationActivityEvent(phase: .paused, actionKind: .readApp, targetApp: nil)
                )
            }
            controller?.refreshAutomationStatus()
        } catch {
            let copy = MenuBarCopy(language: .current)
            let alert = NSAlert()
            alert.messageText = "Accio Computer Use"
            alert.informativeText = copy.pauseUpdateFailed
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

@MainActor
private final class PermissionButtonTarget: NSObject {
    static let shared = PermissionButtonTarget()
    weak var controller: StatusWindowController?

    @objc func requestPermission(_ sender: NSButton) {
        let permission: SystemPermissionKind = sender.tag == 0 ? .accessibility : .screenRecording
        PermissionSupport.startAuthorizationFlow(for: permission)
        controller?.refreshPermissionStatus()
    }

    @objc func openPermissionSettings(_ sender: NSButton) {
        let permission: SystemPermissionKind = sender.tag == 0 ? .accessibility : .screenRecording
        PermissionSupport.openSystemSettings(for: permission)
        controller?.refreshPermissionStatus()
    }
}

@MainActor
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowCloseDelegate()
    weak var controller: StatusWindowController?

    func windowWillClose(_ notification: Notification) {
        controller?.handleWindowClose()
    }
}
