import Foundation
import Testing
@testable import AccioComputerUseKit

@Test("helper relauncher resolves app bundle from bundled executable path")
func helperRelauncherResolvesAppBundleFromBundledExecutablePath() {
    let path = "/Applications/Accio Computer Use.app/Contents/MacOS/accio-computer-use"

    let url = HelperRelauncher.appBundleURL(executablePath: path)

    #expect(url?.path == "/Applications/Accio Computer Use.app")
}

@Test("helper relauncher ignores standalone executable path")
func helperRelauncherIgnoresStandaloneExecutablePath() {
    let path = "/usr/local/bin/accio-computer-use"

    let url = HelperRelauncher.appBundleURL(executablePath: path)

    #expect(url == nil)
}

@Test("helper relaunch waits for the old PID and opens a visible new instance")
func helperRelaunchWaitsForExitBeforeOpeningVisibleInstance() {
    let plan = HelperRelauncher.relaunchPlan(
        appURL: URL(fileURLWithPath: "/Applications/Accio Computer Use.app"),
        currentPID: 4242,
        pollIntervalSeconds: 0.1,
        maximumWaitAttempts: 100
    )

    #expect(plan.executableURL.path == "/bin/sh")
    #expect(plan.arguments.dropFirst(2) == [
        "accio-relaunch",
        "4242",
        "0.1",
        "100",
        "/Applications/Accio Computer Use.app",
    ])

    let script = plan.arguments[1]
    #expect(script.contains("/bin/kill -0 \"$1\""))
    #expect(script.contains("if /bin/kill -0 \"$1\" 2>/dev/null; then"))
    #expect(script.contains("exit 1"))
    #expect(script.contains("/usr/bin/open -n -g \"$4\""))
    #expect(!script.contains("open -gj"))
    #expect(!script.contains("open -j"))
}
