import AppKit
import Foundation

// MARK: - Coordinate mapping

func screenshotPixelScale(
    screenshotPixelSize: CGSize?,
    windowBounds: CGRect?
) -> CGSize {
    guard
        let screenshotPixelSize,
        let windowBounds,
        windowBounds.width > 0,
        windowBounds.height > 0,
        screenshotPixelSize.width > 0,
        screenshotPixelSize.height > 0
    else {
        return CGSize(width: 1, height: 1)
    }

    return CGSize(
        width: screenshotPixelSize.width / windowBounds.width,
        height: screenshotPixelSize.height / windowBounds.height
    )
}

func screenshotPixelToWindowPoint(
    _ point: CGPoint,
    screenshotPixelSize: CGSize?,
    windowBounds: CGRect?
) -> CGPoint {
    let scale = screenshotPixelScale(
        screenshotPixelSize: screenshotPixelSize,
        windowBounds: windowBounds
    )
    return CGPoint(
        x: point.x / scale.width,
        y: point.y / scale.height
    )
}

// MARK: - Focus guard

/// Tracks the user's original frontmost app before any activation-based action.
/// Persists across consecutive actions on the same non-native app so that
/// sequential operations (click search → type query) don't bounce focus.
/// Restored when a native-app action runs or the activated app changes.
nonisolated(unsafe) var deferredRestoreApp: NSRunningApplication? = nil

/// Set by activation paths to signal "don't restore focus after this action."
/// Reset at the start of each `preservingFrontmostApp` call.
nonisolated(unsafe) var skipFocusRestore = false

/// Saves the current frontmost application before a block executes and restores
/// it afterward if the block caused a different app to become frontmost.
///
/// Deferred restore logic for non-native (Qt/Electron/Flutter) apps:
/// - When an activation action sets `skipFocusRestore`, the original frontmost
///   app is saved in `deferredRestoreApp` instead of being restored immediately.
/// - On the NEXT action call, if focus should be restored (native app target or
///   different non-native app), `deferredRestoreApp` is restored first.
/// - This allows sequential actions on the same Qt app to maintain focus
///   (preserving transient UI like search boxes) while still restoring the
///   user's original app when the agent moves on.
func preservingFrontmostApp<T>(_ body: () throws -> T) rethrows -> T {
    let currentFrontmost = NSWorkspace.shared.frontmostApplication

    // Determine the "true before" — either the deferred restore target (if we
    // previously skipped restore) or the current frontmost app.
    let trueBefore: NSRunningApplication?
    if let deferred = deferredRestoreApp {
        trueBefore = deferred
    } else {
        trueBefore = currentFrontmost
    }

    skipFocusRestore = false

    defer {
        if !preferBackgroundOperations {
            deferredRestoreApp = nil
            skipFocusRestore = false
        } else if skipFocusRestore {
            // Activation action wants the target to stay active. Save the
            // original app for later restoration (deferred).
            if deferredRestoreApp == nil {
                deferredRestoreApp = trueBefore
            }
            // else: already have a deferred target from a previous action, keep it.
        } else {
            // Normal path: restore focus if it changed.
            let after = NSWorkspace.shared.frontmostApplication
            let restoreTarget = deferredRestoreApp ?? trueBefore
            deferredRestoreApp = nil

            if let restoreTarget,
               let after,
               restoreTarget.processIdentifier != after.processIdentifier {
                Thread.sleep(forTimeInterval: 0.05)
                restoreTarget.activate()
                Thread.sleep(forTimeInterval: 0.15)
                // Keep the target app's window visible (but not focused) so
                // subsequent SkyLight/postToPid events can reach it.
                InputSimulation.raiseTargetWindow(pid: after.processIdentifier)
            }
        }
    }
    return try body()
}

/// Explicitly restore the deferred frontmost app (if any).
/// Call this when a multi-action workflow on a non-native app is complete
/// and focus should return to the user's original app.
func restoreDeferredFocus() {
    guard let restoreTarget = deferredRestoreApp else { return }
    deferredRestoreApp = nil

    let current = NSWorkspace.shared.frontmostApplication
    if let current, restoreTarget.processIdentifier != current.processIdentifier {
        restoreTarget.activate()
        Thread.sleep(forTimeInterval: 0.15)
        InputSimulation.raiseTargetWindow(pid: current.processIdentifier)
    }
}

// MARK: - Framework detection

let preferBackgroundModeDefaultsKey = "com.accio.computeruse.forceBackgroundMode"
let preferBackgroundModeDefaultMigrationKey = "com.accio.computeruse.preferBackgroundModeDefaultMigrated.v1"

public func registerComputerUseDefaults() {
    let defaults = UserDefaults.standard
    defaults.register(defaults: [
        preferBackgroundModeDefaultsKey: false,
        preferBackgroundModeDefaultMigrationKey: false,
    ])

    guard !defaults.bool(forKey: preferBackgroundModeDefaultMigrationKey) else {
        return
    }

    defaults.set(false, forKey: preferBackgroundModeDefaultsKey)
    defaults.set(true, forKey: preferBackgroundModeDefaultMigrationKey)
}

/// User preference: prefer background operations over foreground activation.
/// The persisted key keeps its historical name for compatibility with existing
/// installs, but the behavior is preference-based rather than forced.
var preferBackgroundOperations: Bool {
    registerComputerUseDefaults()
    return UserDefaults.standard.bool(forKey: preferBackgroundModeDefaultsKey)
}

/// Backward-compatible alias used by snapshot recovery code.
var forceBackgroundMode: Bool {
    preferBackgroundOperations
}

/// Detect apps that need activation + hardware cursor warp for input to work.
/// Electron, Qt, and Flutter apps validate cursor position and/or require
/// key window status — pure SkyLight/postToPid delivery is insufficient.
/// Applies to ALL input types: click, scroll, drag, type_text, press_key.
func appRequiresActivationForReliableInput(_ app: RunningAppDescriptor) -> Bool {
    guard let bundleURL = app.runningApplication.bundleURL else { return false }
    let frameworksURL = bundleURL.appendingPathComponent("Contents/Frameworks")

    // Electron/Chromium (VS Code, Slack, Discord, etc.)
    if FileManager.default.fileExists(atPath: frameworksURL.appendingPathComponent("Electron Framework.framework").path) {
        return true
    }
    // CEF — Chromium Embedded Framework (网易云音乐, etc.)
    if FileManager.default.fileExists(atPath: frameworksURL.appendingPathComponent("Chromium Embedded Framework.framework").path) {
        return true
    }
    // Qt (DingTalk, etc.)
    if FileManager.default.fileExists(atPath: frameworksURL.appendingPathComponent("QtCore.framework").path) {
        return true
    }
    // Flutter (DingTalk hybrid uses Flutter for some views)
    if FileManager.default.fileExists(atPath: frameworksURL.appendingPathComponent("FlutterMacOS.framework").path) {
        return true
    }

    return false
}

func needsActivationForInput(_ app: RunningAppDescriptor) -> Bool {
    if !preferBackgroundOperations { return true }
    return appRequiresActivationForReliableInput(app)
}
