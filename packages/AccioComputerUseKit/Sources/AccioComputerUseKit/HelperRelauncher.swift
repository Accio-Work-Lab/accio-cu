import AppKit
import Foundation

struct HelperRelaunchPlan: Equatable {
    let executableURL: URL
    let arguments: [String]
}

public enum HelperRelauncher {
    public static func appBundleURL(
        executablePath: String = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? ""
    ) -> URL? {
        let resolvedPath = (executablePath as NSString).resolvingSymlinksInPath
        return PermissionIdentityLookup.enclosingAppBundleURL(forResolvedExecutablePath: resolvedPath)
    }

    static func relaunchPlan(
        appURL: URL,
        currentPID: pid_t,
        pollIntervalSeconds: Double,
        maximumWaitAttempts: Int
    ) -> HelperRelaunchPlan {
        let script = """
        attempt=0
        while /bin/kill -0 "$1" 2>/dev/null && [ "$attempt" -lt "$3" ]; do
          /bin/sleep "$2"
          attempt=$((attempt + 1))
        done
        if /bin/kill -0 "$1" 2>/dev/null; then
          exit 1
        fi
        exec /usr/bin/open -n -g "$4"
        """
        return HelperRelaunchPlan(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                script,
                "accio-relaunch",
                String(currentPID),
                String(pollIntervalSeconds),
                String(maximumWaitAttempts),
                appURL.path,
            ]
        )
    }

    @MainActor
    @discardableResult
    public static func relaunchCurrentAppBundle(delaySeconds: Double = 0.4) -> Bool {
        guard let appURL = appBundleURL() else {
            return false
        }

        let plan = relaunchPlan(
            appURL: appURL,
            currentPID: getpid(),
            pollIntervalSeconds: delaySeconds,
            maximumWaitAttempts: 25
        )
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            NSApp.terminate(nil)
            return true
        } catch {
            return false
        }
    }
}
