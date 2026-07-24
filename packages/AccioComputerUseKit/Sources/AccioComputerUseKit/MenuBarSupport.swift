import Foundation

public enum CompanionHealth: String, CaseIterable, Sendable {
    case ready
    case paused
    case needsPermission
    case activityUnavailable
    case daemonUnavailable
}

enum MenuBarLanguage: Equatable, Sendable {
    case english
    case chinese

    init(preferredLanguages: [String]) {
        for language in preferredLanguages {
            let normalized = language.lowercased()
            if normalized.hasPrefix("zh") {
                self = .chinese
                return
            }
            if normalized.hasPrefix("en") {
                self = .english
                return
            }
        }
        self = .english
    }

    static var current: MenuBarLanguage {
        MenuBarLanguage(preferredLanguages: Locale.preferredLanguages)
    }
}

struct MenuBarCopy: Sendable {
    let language: MenuBarLanguage

    private var isChinese: Bool { language == .chinese }

    var permissionsTitle: String { isChinese ? "权限" : "Permissions" }
    var daemonTitle: String { isChinese ? "后台服务" : "Background Service" }
    var toolsTitle: String { isChinese ? "工具" : "Tools" }
    var settingsTitle: String { isChinese ? "设置" : "Settings" }
    var requestPermission: String { isChinese ? "请求授权" : "Request" }
    var openSettings: String { isChinese ? "打开设置" : "Open Settings" }
    var pauseAutomation: String { isChinese ? "暂停后续操作" : "Pause Future Actions" }
    var resumeAutomation: String { isChinese ? "恢复自动化" : "Resume Automation" }
    var stopSessionDaemon: String { isChinese ? "停止本次后台服务" : "Stop Session Service" }
    var daemonRunning: String { isChinese ? "后台服务运行中" : "Background Service Running" }
    var accessibilityRequired: String { isChinese ? "需要辅助功能授权" : "Accessibility Required" }
    var startSessionDaemon: String { isChinese ? "启动本次后台服务" : "Start Session Service" }
    var copySocket: String { isChinese ? "复制套接字路径" : "Copy Socket Path" }
    var details: String { isChinese ? "详细信息" : "Details" }
    var copyMCPConfig: String { isChinese ? "复制 MCP 配置" : "Copy MCP Config" }
    var copyCLICommands: String { isChinese ? "复制 CLI 命令" : "Copy CLI Commands" }
    var openLogs: String { isChinese ? "打开日志" : "Open Logs" }
    var restartHelper: String { isChinese ? "重启助手" : "Restart Helper" }
    var quit: String { isChinese ? "退出" : "Quit" }
    var preferBackgroundMode: String { isChinese ? "优先使用后台模式" : "Prefer background mode" }
    var warnBeforeForegroundFallback: String {
        isChinese ? "切换到前台操作前提醒" : "Warn before foreground fallback"
    }
    var screenRecordingExplanation: String {
        PrivacyCopy.screenRecordingExplanation(isChinese: isChinese)
    }
    var privacyDescription: String {
        isChinese
            ? "敏感字段输出会被隐藏；Accio 控件不会出现在截图中。"
            : "Sensitive field output is redacted; Accio controls are excluded from screenshots."
    }
    var settingsHint: String {
        isChinese
            ? "更改屏幕录制授权后，请重启助手以让 macOS 应用新权限。若需持续后台服务，请通过 CLI 安装 LaunchAgent。"
            : "After changing Screen Recording, restart the helper so macOS applies the new permission. For persistent background service, install the LaunchAgent from the CLI."
    }
    var pauseUpdateFailed: String {
        isChinese ? "无法更新自动化暂停状态。" : "Could not update automation pause state."
    }
    var executableMissing: String {
        isChinese ? "无法找到 Accio 可执行文件。" : "Unable to locate the Accio executable."
    }
    var relaunchFailed: String {
        isChinese
            ? "无法重新启动 App。请退出 Accio Computer Use，然后从“应用程序”文件夹重新打开。"
            : "Unable to relaunch the app bundle. Quit Accio Computer Use and open it again from /Applications."
    }

    func shortLabel(for health: CompanionHealth) -> String {
        switch (language, health) {
        case (.english, .ready): return "Ready"
        case (.english, .paused): return "Paused"
        case (.english, .needsPermission): return "Needs Permission"
        case (.english, .activityUnavailable): return "Indicator Off"
        case (.english, .daemonUnavailable): return "Background Service Off"
        case (.chinese, .ready): return "已就绪"
        case (.chinese, .paused): return "已暂停"
        case (.chinese, .needsPermission): return "需要授权"
        case (.chinese, .activityUnavailable): return "状态指示不可用"
        case (.chinese, .daemonUnavailable): return "后台服务未运行"
        }
    }

    func setupSummary(for health: CompanionHealth) -> String {
        switch (language, health) {
        case (.english, .ready):
            return "Ready for CLI and MCP clients."
        case (.english, .paused):
            return "Future automation actions are paused."
        case (.english, .needsPermission):
            return "Grant the missing permissions to enable desktop automation."
        case (.english, .activityUnavailable):
            return "Restart the helper to restore the required activity indicator."
        case (.english, .daemonUnavailable):
            return "Start a session service, or use stdio MCP directly."
        case (.chinese, .ready):
            return "CLI 和 MCP 客户端已可使用。"
        case (.chinese, .paused):
            return "后续自动化操作已暂停。"
        case (.chinese, .needsPermission):
            return "请先完成缺失授权，再启用桌面自动化。"
        case (.chinese, .activityUnavailable):
            return "请重启助手以恢复必要的操作状态提示。"
        case (.chinese, .daemonUnavailable):
            return "可启动本次后台服务，或直接使用 stdio MCP。"
        }
    }

    func statusAccessibilityDescription(for health: CompanionHealth) -> String {
        "Accio Computer Use — \(shortLabel(for: health))"
    }

    func statusToolTip(for health: CompanionHealth, activityChannelAvailable: Bool) -> String {
        let base = statusAccessibilityDescription(for: health)
        guard !activityChannelAvailable, health != .activityUnavailable else { return base }
        return base + (isChinese ? " · 状态指示不可用" : " · Activity indicator unavailable")
    }

    func accessibilityStatus(granted: Bool) -> String {
        switch (language, granted) {
        case (.english, true): return "Accessibility granted"
        case (.english, false): return "Accessibility missing"
        case (.chinese, true): return "辅助功能已授权"
        case (.chinese, false): return "辅助功能未授权"
        }
    }

    func screenRecordingStatus(granted: Bool) -> String {
        switch (language, granted) {
        case (.english, true): return "Screen Recording granted"
        case (.english, false): return "Screen Recording missing"
        case (.chinese, true): return "屏幕录制已授权"
        case (.chinese, false): return "屏幕录制未授权"
        }
    }

    func daemonSummary(isAvailable: Bool) -> String {
        switch (language, isAvailable) {
        case (.english, true): return "Background service available"
        case (.english, false): return "Background service not running"
        case (.chinese, true): return "后台服务可用"
        case (.chinese, false): return "后台服务未运行"
        }
    }

    var sessionDaemonStartFailed: String {
        isChinese
            ? "无法启动本次后台服务。请重启助手，或运行 accio-computer-use doctor。"
            : "Could not start the session service. Restart the helper or run accio-computer-use doctor."
    }
}

public struct CompanionStatus: Sendable {
    public let permissions: PermissionDiagnostics
    public let daemonSocketPath: String
    public let daemonSocketExists: Bool
    public let automationPaused: Bool
    public let activityChannelAvailable: Bool

    public var health: CompanionHealth {
        if !permissions.allGranted {
            return .needsPermission
        }
        if automationPaused {
            return .paused
        }
        if !activityChannelAvailable {
            return .activityUnavailable
        }
        if !daemonSocketExists {
            return .daemonUnavailable
        }
        return .ready
    }

    public var shortLabel: String {
        switch health {
        case .ready:
            return "Ready"
        case .paused:
            return "Paused"
        case .needsPermission:
            return "Needs Permission"
        case .activityUnavailable:
            return "Indicator Off"
        case .daemonUnavailable:
            return "Daemon Off"
        }
    }

    public var permissionSummary: String {
        if permissions.allGranted {
            return "All permissions granted"
        }
        let missing = permissions.missingPermissions.map(\.title).joined(separator: ", ")
        return "Missing \(missing)"
    }

    public var daemonSummary: String {
        daemonSocketExists ? "Daemon socket available" : "Daemon not running"
    }

    public var setupSummary: String {
        switch health {
        case .ready:
            return "Ready for CLI and MCP clients."
        case .paused:
            return "Future automation actions are paused by the user."
        case .needsPermission:
            return "Grant the missing permissions to enable desktop automation."
        case .activityUnavailable:
            return "Restart the helper to restore the required activity indicator."
        case .daemonUnavailable:
            return "Start a session daemon or use stdio MCP directly."
        }
    }

    public var statusIcon: String {
        switch health {
        case .ready:
            return "checkmark.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .needsPermission:
            return "exclamationmark.triangle.fill"
        case .activityUnavailable:
            return "eye.slash.fill"
        case .daemonUnavailable:
            return "circle.dashed"
        }
    }

    public init(
        permissions: PermissionDiagnostics,
        daemonSocketPath: String = DaemonServer.defaultSocketPath,
        daemonSocketExists: Bool,
        automationPaused: Bool = false,
        activityChannelAvailable: Bool = true
    ) {
        self.permissions = permissions
        self.daemonSocketPath = daemonSocketPath
        self.daemonSocketExists = daemonSocketExists
        self.automationPaused = automationPaused
        self.activityChannelAvailable = activityChannelAvailable
    }

    public static func current(
        socketPath: String = DaemonServer.defaultSocketPath,
        fileManager _: FileManager = .default,
        activityChannelAvailable: Bool? = nil
    ) -> CompanionStatus {
        PermissionDiagnostics.invalidateCache()
        let resolvedActivityAvailability = activityChannelAvailable ?? (
            Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                ? ActivitySocketClient.hasTrustedListener()
                : true
        )
        return CompanionStatus(
            permissions: PermissionDiagnostics.current(),
            daemonSocketPath: socketPath,
            daemonSocketExists: DaemonClient.isAvailable(socketPath: socketPath),
            automationPaused: AutomationPauseStore.shared.isPaused,
            activityChannelAvailable: resolvedActivityAvailability
        )
    }
}

public enum MCPConfigurationSnippet {
    public static let text = """
    {
      "mcpServers": {
        "accio-computer-use": {
          "command": "accio-computer-use",
          "args": ["mcp"]
        }
      }
    }
    """
}

public enum CompanionClipboardText {
    public static let quickCommands = """
    accio-computer-use setup
    accio-computer-use doctor
    accio-computer-use mcp
    accio-computer-use call list_apps
    """
}

enum SessionDaemonTerminationCopy {
    static func message(
        exitStatus: Int32,
        language: MenuBarLanguage = .english
    ) -> String? {
        guard exitStatus != 0 else { return nil }
        return language == .chinese
            ? "本次后台服务已退出（状态码 \(exitStatus)）。请重启助手，或运行 accio-computer-use doctor。"
            : "The session service exited with status \(exitStatus). Restart the helper or run accio-computer-use doctor."
    }
}
