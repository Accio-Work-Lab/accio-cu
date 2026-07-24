import AppKit
import Foundation

@MainActor
public final class ActivityHUDController: NSObject {
    private let pauseStore: AutomationPauseStore
    private let onPauseChanged: @MainActor () -> Void
    private var panel: NSPanel?
    private var iconView: NSImageView?
    private var messageLabel: NSTextField?
    private var pauseButton: NSButton?
    private var hideTimer: Timer?
    private var latestEvent: AutomationActivityEvent?
    private var activeEvents: [UUID: AutomationActivityEvent] = [:]

    public init(
        pauseStore: AutomationPauseStore = .shared,
        onPauseChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.pauseStore = pauseStore
        self.onPauseChanged = onPauseChanged
        super.init()
    }

    public func handle(_ event: AutomationActivityEvent) {
        // Pause is authoritative local state, never a remotely asserted phase.
        guard let effectiveEvent = reconciledActivityEvent(
            event,
            automationPaused: pauseStore.isPaused
        ) else { return }

        switch effectiveEvent.phase {
        case .observing, .acting, .waiting:
            activeEvents[effectiveEvent.operationID] = effectiveEvent
        case .completed, .failed:
            activeEvents.removeValue(forKey: effectiveEvent.operationID)
            if let remaining = activeEvents.values.first {
                handle(remaining)
                return
            }
        case .paused:
            activeEvents.removeAll()
        case .needsApproval:
            break
        }

        latestEvent = effectiveEvent
        hideTimer?.invalidate()

        let presentation = ActivityPresentation(
            event: effectiveEvent,
            isChinese: Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        )
        preparePanelIfNeeded()
        messageLabel?.stringValue = presentation.message
        messageLabel?.setAccessibilityLabel(presentation.message)
        iconView?.image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: presentation.message)
        pauseButton?.isHidden = effectiveEvent.phase == .paused
        positionPanel()
        panel?.orderFrontRegardless()

        switch effectiveEvent.phase {
        case .paused, .needsApproval:
            break
        case .failed:
            scheduleHide(after: 6)
        case .completed:
            scheduleHide(after: 1.2)
        case .observing, .acting, .waiting:
            // Dispatcher emits a matching completed/failed event. Keep a
            // conservative fallback for crashed or legacy clients.
            scheduleHide(after: 35)
        }
    }

    public func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        latestEvent = nil
        activeEvents.removeAll()
        panel?.orderOut(nil)
    }

    public func synchronizePauseState() {
        if pauseStore.isPaused {
            handle(AutomationActivityEvent(
                phase: .paused,
                actionKind: latestEvent?.actionKind ?? .readApp,
                targetApp: nil
            ))
        } else if latestEvent?.phase == .paused {
            hide()
        }
    }

    private func preparePanelIfNeeded() {
        guard panel == nil else { return }

        let contentSize = NSSize(width: 352, height: 44)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.title = "Accio Activity HUD"
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true

        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
        ])

        let messageLabel = NSTextField(labelWithString: "")
        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = .labelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pauseButton = NSButton(
            title: Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "暂停" : "Pause",
            target: self,
            action: #selector(pauseAutomation)
        )
        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .small
        pauseButton.setAccessibilityLabel(
            Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "暂停后续自动化操作" : "Pause future automation actions"
        )

        let stack = NSStackView(views: [iconView, messageLabel, pauseButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
        ])

        panel.contentView = effectView
        self.panel = panel
        self.iconView = iconView
        self.messageLabel = messageLabel
        self.pauseButton = pauseButton
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.maxY - panel.frame.height - 8
        )
        panel.setFrameOrigin(origin)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    @objc private func pauseAutomation() {
        do {
            try pauseStore.setPaused(true)
            let source = latestEvent
            handle(AutomationActivityEvent(
                phase: .paused,
                actionKind: source?.actionKind ?? .readApp,
                targetApp: source?.targetApp
            ))
            onPauseChanged()
        } catch {
            handle(AutomationActivityEvent(
                phase: .failed,
                actionKind: latestEvent?.actionKind ?? .readApp,
                targetApp: nil
            ))
        }
    }
}
