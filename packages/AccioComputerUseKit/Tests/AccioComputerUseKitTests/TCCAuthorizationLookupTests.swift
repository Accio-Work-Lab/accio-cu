import Foundation
import Testing
@testable import AccioComputerUseKit

@Test("CLI identity does not include app bundle id by default")
func cliIdentityDoesNotIncludeFixedBundleID() {
    let executablePath = "/tmp/accio-computer-use-test-bin"
    let records = PermissionIdentityLookup.selfOnlyClients(
        bundleIdentifier: nil,
        bundleURL: URL(fileURLWithPath: "/tmp/accio-computer-use-test-bin"),
        executablePath: executablePath
    )

    #expect(!records.contains(PermissionClientRecord(identifier: PermissionSupport.bundleIdentifier, type: 0)))
    #expect(records.contains(PermissionClientRecord(
        identifier: (executablePath as NSString).resolvingSymlinksInPath,
        type: 1
    )))
}

@Test("App identity includes bundle and app path")
func appIdentityIncludesBundleAndAppPath() {
    let appURL = URL(fileURLWithPath: "/Applications/Accio Computer Use.app")
    let executablePath = "/Applications/Accio Computer Use.app/Contents/MacOS/AccioComputerUse"
    let records = PermissionIdentityLookup.selfOnlyClients(
        bundleIdentifier: PermissionSupport.bundleIdentifier,
        bundleURL: appURL,
        executablePath: executablePath
    )

    #expect(records.contains(PermissionClientRecord(identifier: PermissionSupport.bundleIdentifier, type: 0)))
    #expect(records.contains(PermissionClientRecord(identifier: appURL.standardizedFileURL.path, type: 1)))
    #expect(records.contains(PermissionClientRecord(
        identifier: (executablePath as NSString).resolvingSymlinksInPath,
        type: 1
    )))
}

@Test("CLI symlink into app includes app identity")
func cliSymlinkIntoAppIncludesAppIdentity() {
    let appURL = URL(fileURLWithPath: "/Applications/Accio Computer Use.app")
    let executablePath = "/Applications/Accio Computer Use.app/Contents/MacOS/accio-computer-use"
    let records = PermissionIdentityLookup.selfOnlyClients(
        bundleIdentifier: nil,
        bundleURL: URL(fileURLWithPath: "/Users/example/.local/bin/accio-computer-use"),
        executablePath: executablePath
    )

    #expect(records.contains(PermissionClientRecord(identifier: PermissionSupport.bundleIdentifier, type: 0)))
    #expect(records.contains(PermissionClientRecord(identifier: appURL.standardizedFileURL.path, type: 1)))
    #expect(records.contains(PermissionClientRecord(
        identifier: (executablePath as NSString).resolvingSymlinksInPath,
        type: 1
    )))
}

@Test("Enclosing app bundle is detected from executable path")
func enclosingAppBundleDetectedFromExecutablePath() {
    let appPath = "/Applications/Accio Computer Use.app"
    let executablePath = "\(appPath)/Contents/MacOS/accio-computer-use"

    #expect(
        PermissionIdentityLookup.enclosingAppBundleURL(
            forResolvedExecutablePath: executablePath
        )?.path == appPath
    )
}

@Test("Daemon default socket path is scoped to current user")
func daemonDefaultSocketPathIsUserScoped() {
    #expect(DaemonServer.defaultSocketDirectory == "/tmp/accio-computer-use-\(getuid())")
    #expect(DaemonServer.defaultSocketPath == "/tmp/accio-computer-use-\(getuid())/daemon.sock")
}
