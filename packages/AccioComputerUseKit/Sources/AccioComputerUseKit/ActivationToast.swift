import AppKit
import Foundation

enum ForegroundActivationReason: Sendable {
    case clickFallback
    case hover
    case scrollFallback
    case dragFallback
    case typing
    case keyboard
    case accessibilityRecovery

    func message(appName: String, chinese: Bool) -> String {
        switch self {
        case .clickFallback:
            return chinese
                ? "点击「\(appName)」需要短暂切换到前台。"
                : "Clicking \"\(appName)\" requires brief foreground access."
        case .hover:
            return chinese
                ? "悬停「\(appName)」需要短暂切换到前台。"
                : "Hovering \"\(appName)\" requires brief foreground access."
        case .scrollFallback:
            return chinese
                ? "滚动「\(appName)」需要短暂切换到前台。"
                : "Scrolling \"\(appName)\" requires brief foreground access."
        case .dragFallback:
            return chinese
                ? "拖拽「\(appName)」需要短暂切换到前台。"
                : "Dragging in \"\(appName)\" requires brief foreground access."
        case .typing:
            return chinese
                ? "输入文本到「\(appName)」需要短暂切换到前台。"
                : "Typing into \"\(appName)\" requires brief foreground access."
        case .keyboard:
            return chinese
                ? "向「\(appName)」发送按键需要短暂切换到前台。"
                : "Sending keys to \"\(appName)\" requires brief foreground access."
        case .accessibilityRecovery:
            return chinese
                ? "恢复「\(appName)」的辅助功能树需要短暂切换到前台。"
                : "Recovering \"\(appName)\" accessibility state requires brief foreground access."
        }
    }
}

private enum ActivationToastDecision {
    case proceed
    case cancel
}

/// Shows a brief floating confirmation before stealing foreground focus for a
/// non-native app. Defaults to proceed after a short countdown, while allowing
/// the user to continue immediately or cancel the current action.
@MainActor
enum ActivationToast {
    static let countdownSeconds = 5
    private static let notificationCooldown: TimeInterval = 10 * 60

    private static var lastNotificationByPID: [pid_t: Date] = [:]
    private static var currentPanel: NSPanel?
    private static var currentController: ActivationToastController?

    static var isEnabled: Bool {
        !UserDefaults.standard.bool(forKey: "com.accio.computeruse.disableActivationToast")
    }

    static func confirmIfNeeded(
        for pid: pid_t,
        appName: String,
        reason: ForegroundActivationReason
    ) -> Bool {
        guard isEnabled else { return true }

        let now = Date()
        if let last = lastNotificationByPID[pid],
           now.timeIntervalSince(last) < notificationCooldown {
            return true
        }

        pruneNotificationCache(now: now)

        let decision = showPanel(appName: appName, reason: reason)
        if decision == .proceed {
            lastNotificationByPID[pid] = Date()
            return true
        }
        return false
    }

    static func reset(for pid: pid_t) {
        lastNotificationByPID.removeValue(forKey: pid)
    }

    private static func pruneNotificationCache(now: Date) {
        lastNotificationByPID = lastNotificationByPID.filter { _, timestamp in
            now.timeIntervalSince(timestamp) < notificationCooldown
        }
    }

    private static func showPanel(appName: String, reason: ForegroundActivationReason) -> ActivationToastDecision {
        let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        let controller = ActivationToastController(
            appName: appName,
            message: reason.message(appName: appName, chinese: isChinese),
            isChinese: isChinese
        )
        currentController = controller
        currentPanel = controller.panel
        controller.panel.orderFrontRegardless()

        let deadline = Date().addingTimeInterval(TimeInterval(countdownSeconds))
        while controller.decision == nil && Date() < deadline {
            controller.updateCountdown(remaining: max(0, Int(ceil(deadline.timeIntervalSinceNow))))
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        let decision = controller.decision ?? .proceed
        controller.panel.orderOut(nil)
        currentPanel = nil
        currentController = nil
        return decision
    }
}

@MainActor
private final class ActivationToastController: NSObject {
    let panel: NSPanel
    private let countdownLabel: NSTextField
    var decision: ActivationToastDecision?

    init(appName _: String, message: String, isChinese: Bool) {
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 14, weight: .medium)
        messageLabel.textColor = .white
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 2
        messageLabel.preferredMaxLayoutWidth = 360

        countdownLabel = NSTextField(labelWithString: "")
        countdownLabel.font = .systemFont(ofSize: 12)
        countdownLabel.textColor = NSColor.white.withAlphaComponent(0.78)
        countdownLabel.alignment = .center

        let continueButton = NSButton(
            title: isChinese ? "立即继续" : "Continue",
            target: nil,
            action: #selector(continueNow)
        )
        continueButton.bezelStyle = .rounded

        let cancelButton = NSButton(
            title: isChinese ? "取消" : "Cancel",
            target: nil,
            action: #selector(cancel)
        )
        cancelButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [cancelButton, continueButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [messageLabel, countdownLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 126))
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.masksToBounds = true
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let panelWidth: CGFloat = 420
        let panelHeight: CGFloat = 126
        let panel = NSPanel(
            contentRect: NSRect(
                x: screenFrame.midX - panelWidth / 2,
                y: screenFrame.maxY - panelHeight - 20,
                width: panelWidth,
                height: panelHeight
            ),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.84)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.sharingType = .none
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.contentView = contentView

        self.panel = panel
        super.init()

        continueButton.target = self
        cancelButton.target = self
        updateCountdown(remaining: ActivationToast.countdownSeconds)
    }

    func updateCountdown(remaining: Int) {
        let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        countdownLabel.stringValue = isChinese
            ? "\(remaining) 秒后自动继续"
            : "Continuing automatically in \(remaining)s"
    }

    @objc private func continueNow() {
        decision = .proceed
    }

    @objc private func cancel() {
        decision = .cancel
    }
}

// MARK: - Thread-safe bridge for non-main-actor callers

enum ActivationToastBridge {
    static func confirmIfNeeded(
        for pid: pid_t,
        appName: String,
        reason: ForegroundActivationReason
    ) throws {
        guard !activationToastBypassedForHeadlessService(
            environment: ProcessInfo.processInfo.environment,
            arguments: CommandLine.arguments
        ) else {
            return
        }

        let shouldProceed: Bool
        if Thread.isMainThread {
            shouldProceed = MainActor.assumeIsolated {
                ActivationToast.confirmIfNeeded(for: pid, appName: appName, reason: reason)
            }
        } else {
            shouldProceed = DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    ActivationToast.confirmIfNeeded(for: pid, appName: appName, reason: reason)
                }
            }
        }

        guard shouldProceed else {
            throw ComputerUseError.message("Foreground activation for \(appName) was cancelled by the user.")
        }
    }
}

func activationToastBypassedForHeadlessService(
    environment: [String: String],
    arguments: [String]
) -> Bool {
    if environment["XPC_SERVICE_NAME"] == "com.accio.computeruse.daemon" {
        return true
    }

    return arguments.dropFirst().contains("serve")
}
