@preconcurrency import AppKit
import Foundation

enum MenuBarIconKind: Hashable {
    case brand
}

@MainActor
enum MenuBarIconProvider {
    static func icon(accessibilityDescription: String) -> NSImage? {
        let icon = (accioTemplateIcon() ?? fallbackIcon())?.copy() as? NSImage
        icon?.size = NSSize(width: 18, height: 18)
        icon?.isTemplate = true
        icon?.accessibilityDescription = accessibilityDescription
        return icon
    }

    static func icon(for health: CompanionHealth, accessibilityDescription: String) -> NSImage? {
        let image: NSImage?
        switch kind(for: health) {
        case .brand:
            image = icon(accessibilityDescription: accessibilityDescription)
        }
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        image?.accessibilityDescription = accessibilityDescription
        return image
    }

    static func kind(for _: CompanionHealth) -> MenuBarIconKind {
        .brand
    }

    nonisolated(unsafe) private static var cachedTemplateIcon: NSImage?

    private static func fallbackIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "a.circle.fill", accessibilityDescription: "Accio Computer Use")
        image?.isTemplate = true
        return image
    }

    private static func accioTemplateIcon() -> NSImage? {
        if let cachedTemplateIcon {
            return cachedTemplateIcon
        }

        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        context.clear(CGRect(x: 0, y: 0, width: 18, height: 18))
        NSColor.black.setFill()
        NSColor.black.setStroke()

        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x, y: y)
        }

        let mark = NSBezierPath()
        mark.windingRule = .evenOdd
        mark.move(to: point(8.1, 15.4))
        mark.line(to: point(10.0, 15.4))
        mark.line(to: point(16.0, 2.8))
        mark.curve(to: point(14.0, 2.0), controlPoint1: point(15.8, 2.3), controlPoint2: point(15.1, 2.0))
        mark.line(to: point(12.3, 2.0))
        mark.line(to: point(9.0, 9.7))
        mark.line(to: point(5.7, 2.0))
        mark.line(to: point(3.9, 2.0))
        mark.curve(to: point(2.0, 2.8), controlPoint1: point(2.9, 2.0), controlPoint2: point(2.2, 2.3))
        mark.close()

        mark.move(to: point(9.0, 7.2))
        mark.line(to: point(10.6, 3.9))
        mark.line(to: point(7.4, 3.9))
        mark.close()
        mark.fill()

        let baseline = NSBezierPath()
        baseline.lineWidth = 1.4
        baseline.lineCapStyle = .round
        baseline.lineJoinStyle = .round
        baseline.move(to: point(3.0, 1.2))
        baseline.line(to: point(15.0, 1.2))
        baseline.stroke()

        let crossbar = NSBezierPath()
        crossbar.lineWidth = 1.2
        crossbar.lineCapStyle = .round
        crossbar.move(to: point(6.4, 5.3))
        crossbar.line(to: point(11.6, 5.3))
        crossbar.stroke()
        NSGraphicsContext.restoreGraphicsState()

        image.isTemplate = true
        cachedTemplateIcon = image
        return image
    }

    static func previewTemplateIconPNGData() -> Data? {
        guard let icon = accioTemplateIcon(),
              let tiff = icon.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor
enum AppPresentationEvent {
    case initialLaunch
    case reopen
}

@MainActor
enum AppPresentationPolicy {
    static func shouldShowStatusWindow(for event: AppPresentationEvent) -> Bool {
        switch event {
        case .initialLaunch, .reopen:
            return true
        }
    }
}

enum PermissionControlSurface {
    case persistentWindow
    case transientPopover
}

enum PermissionFlowPresentationPolicy {
    static func shouldPromoteToPersistentWindow(from surface: PermissionControlSurface) -> Bool {
        surface == .transientPopover
    }

    static func shouldRestoreWindow(
        previous: PermissionDiagnostics?,
        current: PermissionDiagnostics,
        windowIsVisible: Bool,
        windowIsMiniaturized: Bool
    ) -> Bool {
        guard let previous else { return false }
        let newlyGranted = (!previous.accessibilityTrusted && current.accessibilityTrusted)
            || (!previous.screenCaptureGranted && current.screenCaptureGranted)
        return newlyGranted && (!windowIsVisible || windowIsMiniaturized)
    }
}

@MainActor
final class PermissionFlowPresenter {
    private let showPersistentControls: () -> Void
    private let requestAuthorization: (SystemPermissionKind) -> Void
    private let openPermissionSettings: (SystemPermissionKind) -> Void

    init(
        showPersistentControls: @escaping () -> Void,
        requestAuthorization: @escaping (SystemPermissionKind) -> Void = {
            _ = PermissionSupport.startAuthorizationFlow(for: $0)
        },
        openSettings: @escaping (SystemPermissionKind) -> Void = {
            PermissionSupport.openSystemSettings(for: $0)
        }
    ) {
        self.showPersistentControls = showPersistentControls
        self.requestAuthorization = requestAuthorization
        self.openPermissionSettings = openSettings
    }

    func request(_ permission: SystemPermissionKind, from surface: PermissionControlSurface) {
        preserveControlSurfaceIfNeeded(from: surface)
        requestAuthorization(permission)
    }

    func openSettings(_ permission: SystemPermissionKind, from surface: PermissionControlSurface) {
        preserveControlSurfaceIfNeeded(from: surface)
        openPermissionSettings(permission)
    }

    private func preserveControlSurfaceIfNeeded(from surface: PermissionControlSurface) {
        guard PermissionFlowPresentationPolicy.shouldPromoteToPersistentWindow(from: surface) else { return }
        showPersistentControls()
    }
}

@MainActor
final class AccioApplicationDelegate: NSObject, NSApplicationDelegate {
    private let showStatusWindow: () -> Void

    init(showStatusWindow: @escaping () -> Void) {
        self.showStatusWindow = showStatusWindow
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showStatusWindow()
        return true
    }
}

@MainActor
public final class MenuBarController: NSObject {
    private let socketPath: String
    private let copy = MenuBarCopy(language: .current)
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let detailController = StatusWindowController()
    private var activityHUD: ActivityHUDController!
    private var activityServer: ActivitySocketServer?
    private var activityChannelAvailable = false
    private var activityChannelIssue: String?
    private var refreshTimer: Timer?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private lazy var applicationDelegate = AccioApplicationDelegate { [weak self] in
        self?.showStatusWindow(for: .reopen)
    }

    public init(socketPath: String = DaemonServer.defaultSocketPath) {
        self.socketPath = socketPath
        super.init()
        activityHUD = ActivityHUDController { [weak self] in
            self?.refresh()
        }
    }

    public func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = applicationDelegate

        configureStatusItem()
        configurePopover()
        startActivityChannel()
        refresh()
        startRefreshTimer()

        showStatusWindow(for: .initialLaunch)

        app.run()
    }

    private func configureStatusItem() {
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.length = NSStatusItem.squareLength
        statusItem = item

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        applyStatusIcon(
            to: button,
            accessibilityDescription: copy.statusAccessibilityDescription(for: .ready)
        )
        button.toolTip = "Accio Computer Use"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = MenuBarPopoverViewController.defaultContentSize
        popover.contentViewController = MenuBarPopoverViewController(
            socketPath: socketPath,
            detailController: detailController,
            language: copy.language
        )
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func startActivityChannel() {
        let server = ActivitySocketServer { [weak self] event in
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self?.activityHUD.handle(event)
                    self?.refresh()
                }
            }
        }
        do {
            try server.start()
            activityServer = server
            activityChannelAvailable = true
            activityChannelIssue = nil
        } catch {
            activityServer = nil
            activityChannelAvailable = false
            activityChannelIssue = Self.conciseActivityChannelIssue(error)
            FileHandle.standardError.write(Data(
                "Activity indicator unavailable: \(activityChannelIssue ?? "unknown error")\n".utf8
            ))
        }
    }

    private static func conciseActivityChannelIssue(_ error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let singleLine = raw.replacingOccurrences(of: "\n", with: " ")
        return String(singleLine.prefix(180))
    }

    private func refresh() {
        if activityChannelAvailable,
           !ActivitySocketClient.hasTrustedListener() {
            activityChannelAvailable = false
            activityChannelIssue = "The activity channel stopped responding. Restart the helper."
        }
        let status = CompanionStatus.current(
            socketPath: socketPath,
            activityChannelAvailable: activityChannelAvailable
        )
        activityHUD.synchronizePauseState()
        updateStatusItem(with: status)
        (popover.contentViewController as? MenuBarPopoverViewController)?.refresh(
            with: status,
            activityChannelAvailable: activityChannelAvailable,
            activityChannelIssue: activityChannelIssue
        )

    }

    private func updateStatusItem(with status: CompanionStatus) {
        guard let button = statusItem?.button else { return }
        let accessibilityDescription = copy.statusAccessibilityDescription(for: status.health)
        applyStatusIcon(
            to: button,
            accessibilityDescription: accessibilityDescription,
            health: status.health
        )
        button.toolTip = copy.statusToolTip(
            for: status.health,
            activityChannelAvailable: activityChannelAvailable
        )
    }

    private func applyStatusIcon(
        to button: NSStatusBarButton,
        accessibilityDescription: String,
        health: CompanionHealth? = nil
    ) {
        let icon = health.map {
            MenuBarIconProvider.icon(for: $0, accessibilityDescription: accessibilityDescription)
        } ?? MenuBarIconProvider.icon(accessibilityDescription: accessibilityDescription)
        if let icon {
            button.image = icon
            button.imagePosition = .imageOnly
            button.title = ""
            button.setAccessibilityLabel(accessibilityDescription)
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = "A"
            button.setAccessibilityLabel(accessibilityDescription)
        }
    }

    private func showStatusWindow(for event: AppPresentationEvent) {
        guard AppPresentationPolicy.shouldShowStatusWindow(for: event) else { return }
        detailController.showWindow()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover(sender)
        } else {
            refresh()
            popover.contentSize = MenuBarPopoverViewController.contentSize(
                forVisibleFrame: button.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startPopoverDismissMonitoring()
        }
    }

    private func closePopover(_ sender: Any?) {
        stopPopoverDismissMonitoring()
        popover.performClose(sender)
    }

    private func startPopoverDismissMonitoring() {
        stopPopoverDismissMonitoring()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            self?.handleLocalDismissEvent(event) ?? event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover(nil)
            }
        }
    }

    private func stopPopoverDismissMonitoring() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func handleLocalDismissEvent(_ event: NSEvent) -> NSEvent? {
        guard popover.isShown else {
            stopPopoverDismissMonitoring()
            return event
        }

        if event.type == .keyDown, event.keyCode == 53 {
            closePopover(nil)
            return nil
        }

        if isEventInsidePopover(event) || isEventInsideStatusButton(event) {
            return event
        }

        closePopover(nil)
        return event
    }

    private func isEventInsidePopover(_ event: NSEvent) -> Bool {
        guard let popoverWindow = popover.contentViewController?.view.window else {
            return false
        }
        return event.window === popoverWindow
    }

    private func isEventInsideStatusButton(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button,
              let buttonWindow = button.window,
              event.window === buttonWindow else {
            return false
        }
        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }
}

extension MenuBarController: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        stopPopoverDismissMonitoring()
    }
}

@MainActor
final class MenuBarPopoverViewController: NSViewController {
    static let defaultContentSize = NSSize(width: 390, height: 500)

    static func contentSize(forVisibleFrame visibleFrame: NSRect?) -> NSSize {
        let availableHeight = max(260, (visibleFrame?.height ?? defaultContentSize.height) - 32)
        return NSSize(
            width: defaultContentSize.width,
            height: min(defaultContentSize.height, availableHeight)
        )
    }

    private let socketPath: String
    private let detailController: StatusWindowController
    private let permissionFlowPresenter: PermissionFlowPresenter
    private let copy: MenuBarCopy

    private let headlineLabel = NSTextField(labelWithString: "")
    private let setupLabel = NSTextField(wrappingLabelWithString: "")
    private let accessibilityLabel = NSTextField(labelWithString: "")
    private let screenRecordingLabel = NSTextField(labelWithString: "")
    private let daemonLabel = NSTextField(labelWithString: "")
    private let socketLabel = NSTextField(labelWithString: "")
    private let accessibilityRequestButton: NSButton
    private let accessibilitySettingsButton: NSButton
    private let screenRecordingRequestButton: NSButton
    private let screenRecordingSettingsButton: NSButton
    private let daemonButton: NSButton
    private let automationButton: NSButton
    private var sessionDaemonProcess: Process?
    private var activityChannelAvailable = true
    private var activityChannelIssue: String?

    init(
        socketPath: String,
        detailController: StatusWindowController,
        language: MenuBarLanguage = .current
    ) {
        let copy = MenuBarCopy(language: language)
        self.socketPath = socketPath
        self.detailController = detailController
        self.copy = copy
        self.accessibilityRequestButton = NSButton(
            title: copy.requestPermission,
            target: nil,
            action: nil
        )
        self.accessibilitySettingsButton = NSButton(
            title: copy.openSettings,
            target: nil,
            action: nil
        )
        self.screenRecordingRequestButton = NSButton(
            title: copy.requestPermission,
            target: nil,
            action: nil
        )
        self.screenRecordingSettingsButton = NSButton(
            title: copy.openSettings,
            target: nil,
            action: nil
        )
        self.daemonButton = NSButton(title: copy.startSessionDaemon, target: nil, action: nil)
        self.automationButton = NSButton(title: copy.pauseAutomation, target: nil, action: nil)
        self.permissionFlowPresenter = PermissionFlowPresenter(
            showPersistentControls: { detailController.showWindow() }
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.defaultContentSize))
        buildLayout()
    }

    func refresh(
        with status: CompanionStatus,
        activityChannelAvailable: Bool = true,
        activityChannelIssue: String? = nil
    ) {
        self.activityChannelAvailable = activityChannelAvailable
        self.activityChannelIssue = activityChannelIssue
        headlineLabel.stringValue = copy.shortLabel(for: status.health)
        setupLabel.stringValue = copy.setupSummary(for: status.health)
        accessibilityLabel.stringValue = copy.accessibilityStatus(
            granted: status.permissions.accessibilityTrusted
        )
        screenRecordingLabel.stringValue = copy.screenRecordingStatus(
            granted: status.permissions.screenCaptureGranted
        )
        accessibilityRequestButton.isHidden = status.permissions.accessibilityTrusted
        accessibilitySettingsButton.isHidden = status.permissions.accessibilityTrusted
        screenRecordingRequestButton.isHidden = status.permissions.screenCaptureGranted
        screenRecordingSettingsButton.isHidden = status.permissions.screenCaptureGranted
        daemonLabel.stringValue = copy.daemonSummary(isAvailable: status.daemonSocketExists)
        socketLabel.stringValue = status.daemonSocketPath

        automationButton.title = status.automationPaused ? copy.resumeAutomation : copy.pauseAutomation
        automationButton.bezelColor = status.automationPaused ? .systemGreen : .controlAccentColor
        automationButton.contentTintColor = .white

        if sessionDaemonProcess?.isRunning == true {
            daemonButton.title = copy.stopSessionDaemon
            daemonButton.isEnabled = true
        } else if status.daemonSocketExists {
            daemonButton.title = copy.daemonRunning
            daemonButton.isEnabled = false
        } else if !status.permissions.accessibilityTrusted {
            daemonButton.title = copy.accessibilityRequired
            daemonButton.isEnabled = false
        } else {
            daemonButton.title = copy.startSessionDaemon
            daemonButton.isEnabled = true
        }
    }

    private func buildLayout() {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stack

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        stack.addArrangedSubview(makeHeader())
        addSeparator(to: stack)
        stack.addArrangedSubview(makePermissionsSection())
        addSeparator(to: stack)
        stack.addArrangedSubview(makeDaemonSection())
        addSeparator(to: stack)
        stack.addArrangedSubview(makeToolsSection())
        addSeparator(to: stack)
        stack.addArrangedSubview(makeSettingsSection())
    }

    private func makeHeader() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3

        let title = NSTextField(labelWithString: "Accio Computer Use")
        title.font = .boldSystemFont(ofSize: 15)
        stack.addArrangedSubview(title)

        headlineLabel.font = .systemFont(ofSize: 12)
        headlineLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(headlineLabel)

        setupLabel.font = .systemFont(ofSize: 12)
        setupLabel.textColor = .secondaryLabelColor
        setupLabel.preferredMaxLayoutWidth = 350
        stack.addArrangedSubview(setupLabel)

        automationButton.target = self
        automationButton.action = #selector(toggleAutomationPause)
        configureActionButton(automationButton, emphasized: true, minimumWidth: 170)
        stack.addArrangedSubview(automationButton)

        return stack
    }

    private func makePermissionsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        stack.addArrangedSubview(sectionTitle(copy.permissionsTitle))
        accessibilityRequestButton.identifier = NSUserInterfaceItemIdentifier(
            PermissionControlIdentifier.accessibilityRequest.rawValue
        )
        accessibilitySettingsButton.identifier = NSUserInterfaceItemIdentifier(
            PermissionControlIdentifier.accessibilitySettings.rawValue
        )
        screenRecordingRequestButton.identifier = NSUserInterfaceItemIdentifier(
            PermissionControlIdentifier.screenRecordingRequest.rawValue
        )
        screenRecordingSettingsButton.identifier = NSUserInterfaceItemIdentifier(
            PermissionControlIdentifier.screenRecordingSettings.rawValue
        )
        stack.addArrangedSubview(makePermissionRow(
            label: accessibilityLabel,
            requestButton: accessibilityRequestButton,
            requestAction: #selector(requestAccessibilityPermission),
            settingsButton: accessibilitySettingsButton,
            settingsAction: #selector(openAccessibilitySettings)
        ))
        stack.addArrangedSubview(makePermissionRow(
            label: screenRecordingLabel,
            requestButton: screenRecordingRequestButton,
            requestAction: #selector(requestScreenRecordingPermission),
            settingsButton: screenRecordingSettingsButton,
            settingsAction: #selector(openScreenRecordingSettings)
        ))

        let captureExplanation = NSTextField(
            wrappingLabelWithString: copy.screenRecordingExplanation
        )
        captureExplanation.font = .systemFont(ofSize: 11)
        captureExplanation.textColor = .secondaryLabelColor
        captureExplanation.preferredMaxLayoutWidth = 350
        stack.addArrangedSubview(captureExplanation)

        return stack
    }

    private func makePermissionRow(
        label: NSTextField,
        requestButton: NSButton,
        requestAction: Selector,
        settingsButton: NSButton,
        settingsAction: Selector
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)

        requestButton.target = self
        requestButton.action = requestAction
        configureActionButton(requestButton, emphasized: true, minimumWidth: 72)
        row.addArrangedSubview(requestButton)

        settingsButton.target = self
        settingsButton.action = settingsAction
        configureActionButton(settingsButton, minimumWidth: 96)
        row.addArrangedSubview(settingsButton)

        return row
    }

    private func makeDaemonSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        stack.addArrangedSubview(sectionTitle(copy.daemonTitle))

        daemonLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(daemonLabel)

        socketLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        socketLabel.textColor = .secondaryLabelColor
        socketLabel.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(socketLabel)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        daemonButton.target = self
        daemonButton.action = #selector(toggleSessionDaemon)
        daemonButton.identifier = NSUserInterfaceItemIdentifier("daemon.session.toggle")
        configureActionButton(daemonButton, emphasized: true, minimumWidth: 160)
        row.addArrangedSubview(daemonButton)
        row.addArrangedSubview(makeButton(
            title: copy.copySocket,
            action: #selector(copySocketPath),
            minimumWidth: 120
        ))
        stack.addArrangedSubview(row)

        return stack
    }

    private func makeToolsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        stack.addArrangedSubview(sectionTitle(copy.toolsTitle))

        let firstRow = NSStackView()
        firstRow.orientation = .horizontal
        firstRow.spacing = 8
        firstRow.addArrangedSubview(makeButton(title: copy.details, action: #selector(openDetails)))
        firstRow.addArrangedSubview(makeButton(
            title: copy.copyMCPConfig,
            action: #selector(copyMCPConfig),
            minimumWidth: 150
        ))
        stack.addArrangedSubview(firstRow)

        let secondRow = NSStackView()
        secondRow.orientation = .horizontal
        secondRow.spacing = 8
        secondRow.addArrangedSubview(makeButton(
            title: copy.copyCLICommands,
            action: #selector(copyQuickCommands),
            minimumWidth: 150
        ))
        secondRow.addArrangedSubview(makeButton(title: copy.openLogs, action: #selector(openLogs)))
        stack.addArrangedSubview(secondRow)

        let thirdRow = NSStackView()
        thirdRow.orientation = .horizontal
        thirdRow.spacing = 8
        thirdRow.addArrangedSubview(makeButton(
            title: copy.restartHelper,
            action: #selector(restartHelper),
            minimumWidth: 150
        ))
        thirdRow.addArrangedSubview(makeButton(title: copy.quit, action: #selector(quitApp)))
        stack.addArrangedSubview(thirdRow)

        return stack
    }

    private func makeSettingsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        stack.addArrangedSubview(sectionTitle(copy.settingsTitle))

        let background = NSButton(
            checkboxWithTitle: copy.preferBackgroundMode,
            target: self,
            action: #selector(toggleBackgroundMode(_:))
        )
        background.state = preferBackgroundOperations ? .on : .off
        stack.addArrangedSubview(background)

        let toastEnabled = !UserDefaults.standard.bool(forKey: "com.accio.computeruse.disableActivationToast")
        let toast = NSButton(
            checkboxWithTitle: copy.warnBeforeForegroundFallback,
            target: self,
            action: #selector(toggleToast(_:))
        )
        toast.state = toastEnabled ? .on : .off
        stack.addArrangedSubview(toast)

        let privacy = NSTextField(
            wrappingLabelWithString: copy.privacyDescription
        )
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .secondaryLabelColor
        privacy.preferredMaxLayoutWidth = 350
        stack.addArrangedSubview(privacy)

        let hint = NSTextField(wrappingLabelWithString: copy.settingsHint)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 350
        stack.addArrangedSubview(hint)

        return stack
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: 12)
        return label
    }

    private func makeButton(title: String, action: Selector, minimumWidth: CGFloat = 96) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        configureActionButton(button, minimumWidth: minimumWidth)
        return button
    }

    private func configureActionButton(
        _ button: NSButton,
        emphasized: Bool = false,
        minimumWidth: CGFloat
    ) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: emphasized ? .semibold : .regular)
        button.isBordered = true
        button.setButtonType(.momentaryPushIn)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if emphasized {
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth),
        ])
    }

    private func addSeparator(to stack: NSStackView) {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
    }

    @objc private func openDetails() {
        detailController.showWindow()
    }

    @objc private func copyMCPConfig() {
        copyToPasteboard(MCPConfigurationSnippet.text)
    }

    @objc private func copyQuickCommands() {
        copyToPasteboard(CompanionClipboardText.quickCommands)
    }

    @objc private func copySocketPath() {
        copyToPasteboard(socketPath)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func openAccessibilitySettings() {
        permissionFlowPresenter.openSettings(.accessibility, from: .transientPopover)
    }

    @objc private func requestAccessibilityPermission() {
        permissionFlowPresenter.request(.accessibility, from: .transientPopover)
    }

    @objc private func toggleAutomationPause() {
        let store = AutomationPauseStore.shared
        do {
            try store.setPaused(!store.isPaused)
            if store.isPaused {
                ActivitySocketClient.shared.publish(
                    AutomationActivityEvent(phase: .paused, actionKind: .readApp, targetApp: nil)
                )
            }
            refresh(
                with: CompanionStatus.current(
                    socketPath: socketPath,
                    activityChannelAvailable: activityChannelAvailable
                ),
                activityChannelAvailable: activityChannelAvailable,
                activityChannelIssue: activityChannelIssue
            )
        } catch {
            showAlert(message: copy.pauseUpdateFailed)
        }
    }

    @objc private func openScreenRecordingSettings() {
        permissionFlowPresenter.openSettings(.screenRecording, from: .transientPopover)
    }

    @objc private func requestScreenRecordingPermission() {
        permissionFlowPresenter.request(.screenRecording, from: .transientPopover)
    }

    @objc private func openLogs() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AccioComputerUse", isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleSessionDaemon() {
        if sessionDaemonProcess?.isRunning == true {
            sessionDaemonProcess?.terminate()
            sessionDaemonProcess = nil
            refresh(
                with: CompanionStatus.current(
                    socketPath: socketPath,
                    activityChannelAvailable: activityChannelAvailable
                ),
                activityChannelAvailable: activityChannelAvailable,
                activityChannelIssue: activityChannelIssue
            )
            return
        }

        guard let executableURL = Bundle.main.executableURL else {
            showAlert(message: copy.executableMissing)
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["serve", socketPath]
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] terminatedProcess in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self,
                          self.sessionDaemonProcess === terminatedProcess else { return }
                    self.sessionDaemonProcess = nil
                    self.refresh(
                        with: CompanionStatus.current(
                            socketPath: self.socketPath,
                            activityChannelAvailable: self.activityChannelAvailable
                        ),
                        activityChannelAvailable: self.activityChannelAvailable,
                        activityChannelIssue: self.activityChannelIssue
                    )
                    if let message = SessionDaemonTerminationCopy.message(
                        exitStatus: terminatedProcess.terminationStatus,
                        language: self.copy.language
                    ) {
                        self.showAlert(message: message)
                    }
                }
            }
        }
        do {
            try process.run()
            sessionDaemonProcess = process
            refresh(
                with: CompanionStatus.current(
                    socketPath: socketPath,
                    activityChannelAvailable: activityChannelAvailable
                ),
                activityChannelAvailable: activityChannelAvailable,
                activityChannelIssue: activityChannelIssue
            )
        } catch {
            showAlert(message: copy.sessionDaemonStartFailed)
        }
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Accio Computer Use"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func restartHelper() {
        if sessionDaemonProcess?.isRunning == true {
            sessionDaemonProcess?.terminate()
        }
        guard HelperRelauncher.relaunchCurrentAppBundle() else {
            showAlert(message: copy.relaunchFailed)
            return
        }
    }

    @objc private func quitApp() {
        if sessionDaemonProcess?.isRunning == true {
            sessionDaemonProcess?.terminate()
        }
        NSApp.terminate(nil)
    }

    @objc private func toggleBackgroundMode(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: preferBackgroundModeDefaultsKey)
    }

    @objc private func toggleToast(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .off, forKey: "com.accio.computeruse.disableActivationToast")
    }
}
