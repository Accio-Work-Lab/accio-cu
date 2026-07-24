import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

@_silgen_name("CGWindowListCreateImage")
func _cgWindowListCreateImage(
    _ screenBounds: CGRect,
    _ listOption: CGWindowListOption,
    _ windowID: CGWindowID,
    _ imageOption: CGWindowImageOption
) -> CGImage?

public enum SystemPermissionKind: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }

    public var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

enum PermissionControlIdentifier: String, CaseIterable {
    case accessibilityRequest = "permission.accessibility.request"
    case accessibilitySettings = "permission.accessibility.settings"
    case screenRecordingRequest = "permission.screenRecording.request"
    case screenRecordingSettings = "permission.screenRecording.settings"

    static func request(for permission: SystemPermissionKind) -> PermissionControlIdentifier {
        permission == .accessibility ? .accessibilityRequest : .screenRecordingRequest
    }

    static func settings(for permission: SystemPermissionKind) -> PermissionControlIdentifier {
        permission == .accessibility ? .accessibilitySettings : .screenRecordingSettings
    }
}

public struct PermissionDiagnostics: Sendable {
    public let accessibilityTrusted: Bool
    public let screenCaptureGranted: Bool

    // MARK: - Shared probe helpers

    /// Two-state result for permission probes.
    ///   - `.granted` if the permission is in effect.
    ///   - `.denied` otherwise (not granted yet, explicitly denied, or unknown
    ///     — all functionally equivalent for our purposes).
    enum ProbeResult: Equatable { case granted, denied }

    /// Reports whether this binary holds Accessibility permission.
    ///
    /// `AXIsProcessTrusted()` is the authoritative answer for the current
    /// process. TCC SQLite rows are intentionally excluded from this decision:
    /// they may be unreadable without Full Disk Access, use a private schema,
    /// or describe an older code-signing requirement after a local rebuild.
    ///
    /// Do NOT add a "deep probe" fallback that reads the system-wide focused
    /// application's window list when this returns false:
    ///
    ///   Reading another app's AX tree requires the AX grant, but reading our
    ///   OWN app's AX tree never does. The status window is almost always the
    ///   frontmost application at poll time (we call `app.activate(...)` on
    ///   launch, and focus returns to us whenever the Settings panel closes).
    ///   So the deep probe always reads OUR windows, always succeeds, and
    ///   always reports `.granted` — a guaranteed false positive that
    ///     1) makes the UI display ✅ when permission is missing,
    ///     2) diverges from `accio-computer-use doctor` (whose focused app is
    ///        typically Terminal, where the same probe correctly fails), and
    ///     3) causes the indicator to oscillate as focus moves between the
    ///        Settings panel and our window.
    static func probeAccessibility() -> ProbeResult {
        resolveAccessibility(runtimeTrusted: AXIsProcessTrusted())
    }

    static func resolveAccessibility(runtimeTrusted: Bool) -> ProbeResult {
        runtimeTrusted ? .granted : .denied
    }

    /// Probes whether screen capture actually works at runtime.
    /// `CGPreflightScreenCaptureAccess()` is authoritative for the current
    /// process. Persisted TCC rows remain diagnostic-only for the same reasons
    /// described by `probeAccessibility()`.
    static func probeScreenCapture() -> ProbeResult {
        resolveScreenCapture(runtimeGranted: CGPreflightScreenCaptureAccess())
    }

    static func resolveScreenCapture(runtimeGranted: Bool) -> ProbeResult {
        runtimeGranted ? .granted : .denied
    }

    /// Runtime permission APIs are inexpensive and permission UI polls this
    /// value. Re-probe every time so a System Settings change is visible
    /// immediately instead of being hidden by a stale process cache.
    public static func current() -> PermissionDiagnostics {
        probeFresh()
    }

    /// Kept for source compatibility with existing callers. `current()` now
    /// always re-probes, so there is no cache to invalidate.
    static func invalidateCache() {
    }

    private static func probeFresh() -> PermissionDiagnostics {
        // Effective capability is deliberately based on Apple's current-process
        // runtime APIs. Daemons run the same probes in their own process.
        let axGranted = probeAccessibility() == .granted
        let screenGranted = probeScreenCapture() == .granted

        return PermissionDiagnostics(
            accessibilityTrusted: axGranted,
            screenCaptureGranted: screenGranted
        )
    }

    /// Current-process capability probe used by daemon startup gates. This has
    /// the same authority as `current()` and never reads the private TCC DB.
    public static func runtimeProbe() -> PermissionDiagnostics {
        return PermissionDiagnostics(
            accessibilityTrusted: AXIsProcessTrusted(),
            screenCaptureGranted: CGPreflightScreenCaptureAccess()
        )
    }

    public var summary: String {
        "Permissions: accessibility=\(accessibilityTrusted ? "granted" : "missing"), screenRecording=\(screenCaptureGranted ? "granted" : "missing")"
    }

    public var missingPermissions: [SystemPermissionKind] {
        SystemPermissionKind.allCases.filter { !isGranted($0) }
    }

    public func isGranted(_ permission: SystemPermissionKind) -> Bool {
        switch permission {
        case .accessibility: return accessibilityTrusted
        case .screenRecording: return screenCaptureGranted
        }
    }

    public var allGranted: Bool {
        accessibilityTrusted && screenCaptureGranted
    }
}

public enum PermissionSupport {
    public static let bundleIdentifier = "com.accio.computeruse"
    nonisolated(unsafe) private static var lastAlertTimestamp: CFAbsoluteTime = 0

    public static func openSystemSettings(for permission: SystemPermissionKind) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    public static func requestAccessibilityPrompt() {
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func requestScreenRecordingPrompt() {
        CGRequestScreenCaptureAccess()
    }

    static func authorizationAction(
        for permission: SystemPermissionKind,
        isGranted: Bool,
        intent: PermissionAuthorizationIntent
    ) -> PermissionAuthorizationAction {
        guard !isGranted else { return .alreadyGranted }
        switch intent {
        case .requestPrompt: return .requestPrompt(permission)
        case .openSettings: return .openSettings(permission)
        }
    }

    /// Human-readable code identities used by `doctor` to explain which app
    /// bundle and executable are running. They do not decide permission state.
    public static func authorizationIdentityLines() -> [String] {
        let records = PermissionIdentityLookup.selfOnlyClients()
        guard !records.isEmpty else {
            return ["  (none detected)"]
        }

        return records.map { record in
            let kind = record.type == 0 ? "bundle id" : "path"
            return "  - \(kind): \(record.identifier)"
        }
    }

    public static func installModelSummary() -> String {
        let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? ""
        let resolvedExecutablePath = (executablePath as NSString).resolvingSymlinksInPath
        let appBundle = PermissionIdentityLookup.enclosingAppBundleURL(
            forResolvedExecutablePath: resolvedExecutablePath
        )

        if let appBundle {
            return "Install model: app-bundled CLI (\(appBundle.path))"
        }
        return "Install model: standalone CLI (not inside an .app bundle)"
    }

    /// Starts the user-facing authorization flow for a single permission.
    /// Returns true when the permission is already granted. When it is missing,
    /// this triggers macOS' native permission prompt and returns false so
    /// callers can keep polling instead of assuming the user granted it
    /// synchronously.
    ///
    @discardableResult
    public static func startAuthorizationFlow(
        for permission: SystemPermissionKind
    ) -> Bool {
        PermissionDiagnostics.invalidateCache()
        let current = PermissionDiagnostics.current()
        let action = authorizationAction(
            for: permission,
            isGranted: current.isGranted(permission),
            intent: .requestPrompt
        )
        switch action {
        case .alreadyGranted:
            return true
        case .requestPrompt(.accessibility):
            requestAccessibilityPrompt()
        case .requestPrompt(.screenRecording):
            requestScreenRecordingPrompt()
        case .openSettings(let permission):
            openSystemSettings(for: permission)
        }

        PermissionDiagnostics.invalidateCache()
        return false
    }

    /// Non-interactive permission check for headless modes (stdio MCP server).
    /// Writes a one-line warning to stderr when something is missing; never
    /// shows a modal alert and never aborts. Returns `true` if all granted.
    @discardableResult
    public static func logAuthorizationStatus(prefix: String = "Warning") -> Bool {
        let permissions = PermissionDiagnostics.current()
        if permissions.allGranted { return true }
        let missing = permissions.missingPermissions.map(\.title).joined(separator: ", ")
        FileHandle.standardError.write(Data(
            "\(prefix): missing permission(s): \(missing). Run `accio-computer-use doctor` for details.\n".utf8
        ))
        return false
    }

    /// Shows a macOS alert if permissions are missing. Returns true only if all
    /// permissions were already granted before showing any UI.
    /// Skips the alert if running as a LaunchAgent (detected via parent PID = launchd)
    /// or if the alert was already shown recently (within 60 seconds) to prevent
    /// infinite popup loops when KeepAlive restarts the daemon.
    @discardableResult
    public static func showAuthorizationAlertIfNeeded() -> Bool {
        PermissionDiagnostics.invalidateCache()
        let permissions = PermissionDiagnostics.current()
        guard !permissions.allGranted else { return true }

        // Skip alert if launched by launchd (ppid == 1) — log to stderr instead
        if getppid() == 1 {
            let missing = permissions.missingPermissions.map(\.title).joined(separator: ", ")
            FileHandle.standardError.write(Data("Permissions missing: \(missing). Grant via System Settings.\n".utf8))
            return false
        }

        // Cooldown: don't show alert if shown in the last 60 seconds (prevents
        // rapid restart loops from re-showing the dialog).
        // Uses a process-level static timestamp instead of a temp file to avoid
        // symlink attacks and TOCTOU races on /tmp.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAlertTimestamp < 60 {
            return false
        }
        lastAlertTimestamp = now

        // Show NSAlert on main thread
        let result = showAlertOnMainThread(permissions: permissions)
        return result
    }

    private static func showAlertOnMainThread(permissions: PermissionDiagnostics) -> Bool {
        // Use DispatchQueue.main.sync if we're not already on main;
        // if we are on main, just call directly.
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                presentAlert(permissions: permissions)
            }
        } else {
            var result = false
            DispatchQueue.main.sync {
                result = MainActor.assumeIsolated {
                    presentAlert(permissions: permissions)
                }
            }
            return result
        }
    }

    @MainActor
    private static func presentAlert(permissions: PermissionDiagnostics) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        let missing = permissions.missingPermissions

        let alert = NSAlert()
        alert.messageText = isChinese
            ? "Accio Computer Use 需要授权"
            : "Accio Computer Use Requires Authorization"
        alert.informativeText = buildPermissionMessage(permissions, chinese: isChinese)
        alert.alertStyle = .warning

        // Add a button for each missing permission. The button starts the
        // native macOS prompt; macOS owns any follow-up Settings navigation.
        if missing.contains(.accessibility) {
            alert.addButton(withTitle: isChinese ? "请求辅助功能授权" : "Request Accessibility Permission")
        }
        if missing.contains(.screenRecording) {
            alert.addButton(withTitle: isChinese ? "请求屏幕录制授权" : "Request Screen Recording Permission")
        }
        alert.addButton(withTitle: isChinese ? "暂不授权" : "Continue Without Permissions")

        let response = alert.runModal()

        // Map button index to action, then force-hide the alert before opening
        // the macOS authorization surfaces. Without this, the NSAlert can
        // visually linger over System Settings while the modal stack unwinds.
        let buttonIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let selectedPermission: SystemPermissionKind?
        if buttonIndex < missing.count {
            selectedPermission = missing[buttonIndex]
        } else {
            selectedPermission = nil
        }
        alert.window.orderOut(nil)

        if let selectedPermission {
            startAuthorizationFlow(for: selectedPermission)
        }

        // Stop the application event loop so it doesn't linger
        app.stop(nil)
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            app.postEvent(event, atStart: true)
        }

        PermissionDiagnostics.invalidateCache()
        return false
    }

    private static func buildPermissionMessage(_ permissions: PermissionDiagnostics, chinese: Bool) -> String {
        let missing = permissions.missingPermissions
        if chinese {
            var lines: [String] = ["本工具需要以下权限才能正常工作：\n"]
            for (i, perm) in missing.enumerated() {
                switch perm {
                case .accessibility:
                    lines.append("步骤 \(i + 1)：授权「辅助功能」")
                    lines.append("   系统设置 → 隐私与安全性 → 辅助功能")
                    lines.append("   找到 Accio Computer Use，打开开关\n")
                case .screenRecording:
                    lines.append("步骤 \(i + 1)：授权「屏幕录制」")
                    lines.append("   系统设置 → 隐私与安全性 → 屏幕录制")
                    lines.append("   找到 Accio Computer Use，打开开关\n")
                }
            }
            lines.append("点击下方按钮后，请在系统弹窗中选择「打开系统设置」并开启权限。")
            return lines.joined(separator: "\n")
        } else {
            var lines: [String] = ["This tool requires the following permissions:\n"]
            for (i, perm) in missing.enumerated() {
                switch perm {
                case .accessibility:
                    lines.append("Step \(i + 1): Grant Accessibility")
                    lines.append("   System Settings → Privacy & Security → Accessibility")
                    lines.append("   Find Accio Computer Use and enable it\n")
                case .screenRecording:
                    lines.append("Step \(i + 1): Grant Screen Recording")
                    lines.append("   System Settings → Privacy & Security → Screen Recording")
                    lines.append("   Find Accio Computer Use and enable it\n")
                }
            }
            lines.append("Click a button below, then choose Open System Settings in the macOS prompt and enable the permission.")
            return lines.joined(separator: "\n")
        }
    }
}

enum PermissionAuthorizationIntent: Equatable {
    case requestPrompt
    case openSettings
}

enum PermissionAuthorizationAction: Equatable {
    case alreadyGranted
    case requestPrompt(SystemPermissionKind)
    case openSettings(SystemPermissionKind)
}

struct PermissionClientRecord: Sendable, Equatable, Hashable {
    let identifier: String
    let type: Int32
}

enum PermissionIdentityLookup {
    /// Returns the current app-bundled executable identities for diagnostic
    /// output. These values are never used to decide effective permission;
    /// Apple's runtime APIs are authoritative for the current process.
    static func selfOnlyClients(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        bundleURL: URL = Bundle.main.bundleURL,
        executablePath: String? = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first
    ) -> [PermissionClientRecord] {
        var seen = Set<PermissionClientRecord>()
        var records: [PermissionClientRecord] = []

        func add(_ record: PermissionClientRecord) {
            if seen.insert(record).inserted {
                records.append(record)
            }
        }

        let resolvedExecutablePath = executablePath.map {
            ($0 as NSString).resolvingSymlinksInPath
        }
        let appBundleURL = effectiveAppBundleURL(
            bundleURL: bundleURL,
            resolvedExecutablePath: resolvedExecutablePath
        )
        let effectiveBundleIdentifier = nonEmpty(bundleIdentifier)
            ?? appBundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier }

        if let bundleID = effectiveBundleIdentifier {
            add(PermissionClientRecord(identifier: bundleID, type: 0))
        } else if appBundleURL != nil {
            add(PermissionClientRecord(identifier: PermissionSupport.bundleIdentifier, type: 0))
        }
        if let appBundleURL {
            add(PermissionClientRecord(identifier: appBundleURL.standardizedFileURL.path, type: 1))
        }
        if let resolvedExecutablePath, !resolvedExecutablePath.isEmpty {
            add(PermissionClientRecord(identifier: resolvedExecutablePath, type: 1))
        }
        return records
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func effectiveAppBundleURL(bundleURL: URL, resolvedExecutablePath: String?) -> URL? {
        if bundleURL.pathExtension == "app" {
            return bundleURL.standardizedFileURL
        }
        guard let resolvedExecutablePath else { return nil }
        return enclosingAppBundleURL(forResolvedExecutablePath: resolvedExecutablePath)
    }

    static func enclosingAppBundleURL(forResolvedExecutablePath path: String) -> URL? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                return url
            }
        }
        return nil
    }
}
