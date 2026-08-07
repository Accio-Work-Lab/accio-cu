import Foundation
import Testing
@testable import AccioComputerUseKit

@Test("bare command names are resolved through PATH before runner discovery")
func bareCommandNameResolvesThroughPath() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let executable = root
        .appendingPathComponent("Accio Computer Use.app/Contents/MacOS/accio-computer-use")
    let runner = root
        .appendingPathComponent("Accio Computer Use.app/Contents/Resources/coding/runner.py")
    let commandDirectory = root.appendingPathComponent("bin", isDirectory: true)
    let command = commandDirectory.appendingPathComponent("accio-computer-use")
    try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: runner.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: commandDirectory,
        withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
    #expect(FileManager.default.createFile(atPath: runner.path, contents: Data()))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path
    )
    try FileManager.default.createSymbolicLink(at: command, withDestinationURL: executable)

    let resolvedExecutable = CodingHarnessLauncher.commandLineExecutableURL(
        argumentZero: "accio-computer-use",
        environment: ["PATH": commandDirectory.path]
    )
    let resolvedRunner = CodingHarnessLauncher.runnerURL(
        environment: [:],
        bundleResourceURL: nil,
        executableURL: resolvedExecutable,
        currentDirectoryURL: root.appendingPathComponent("unrelated")
    )

    #expect(resolvedExecutable == executable)
    #expect(resolvedRunner == runner)
}

@Test("coding runner is resolved beside the app-bundled native executable")
func codingRunnerResolvesFromAppBundleLayout() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let executable = root
        .appendingPathComponent("Accio Computer Use.app/Contents/MacOS/accio-computer-use")
    let runner = root
        .appendingPathComponent("Accio Computer Use.app/Contents/Resources/coding/runner.py")
    try FileManager.default.createDirectory(
        at: runner.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: runner.path, contents: Data()))

    let resolved = CodingHarnessLauncher.runnerURL(
        environment: [:],
        bundleResourceURL: nil,
        executableURL: executable,
        currentDirectoryURL: root.appendingPathComponent("unrelated")
    )

    #expect(resolved == runner)
}

@Test("coding runner environment override has priority")
func codingRunnerEnvironmentOverrideHasPriority() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let override = root.appendingPathComponent("custom-runner.py")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(FileManager.default.createFile(atPath: override.path, contents: Data()))

    let resolved = CodingHarnessLauncher.runnerURL(
        environment: [CodingHarnessLauncher.runnerEnvironmentKey: override.path],
        bundleResourceURL: nil,
        executableURL: root.appendingPathComponent("missing"),
        currentDirectoryURL: root.appendingPathComponent("unrelated")
    )

    #expect(resolved == override)
}

@Test("coding runner is resolved from a source checkout outside its working directory")
func codingRunnerResolvesFromSourceCheckout() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let executable = root.appendingPathComponent(".build/debug/AccioComputerUse")
    let runner = root.appendingPathComponent("coding/runner.py")
    try FileManager.default.createDirectory(
        at: runner.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: runner.path, contents: Data()))

    let resolved = CodingHarnessLauncher.runnerURL(
        environment: [:],
        bundleResourceURL: nil,
        executableURL: executable,
        currentDirectoryURL: root.appendingPathComponent("unrelated")
    )

    #expect(resolved == runner)
}

@Test("coding runner is never loaded implicitly from the working directory")
func codingRunnerIgnoresWorkingDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let runner = root.appendingPathComponent("coding/runner.py")
    try FileManager.default.createDirectory(
        at: runner.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    #expect(FileManager.default.createFile(atPath: runner.path, contents: Data()))

    let resolved = CodingHarnessLauncher.runnerURL(
        environment: [:],
        bundleResourceURL: nil,
        executableURL: root.appendingPathComponent("untrusted/accio-computer-use"),
        currentDirectoryURL: root
    )

    #expect(resolved == nil)
}

@Test("runner diagnostics report the executable and every unique candidate")
func codingRunnerDiagnosticsAreActionable() throws {
    let executable = URL(fileURLWithPath: "/Applications/Accio Computer Use.app/Contents/MacOS/accio-computer-use")
    let resources = URL(fileURLWithPath: "/Applications/Accio Computer Use.app/Contents/Resources")
    let candidates = CodingHarnessLauncher.runnerCandidates(
        environment: [:],
        bundleResourceURL: resources,
        executableURL: executable
    )

    #expect(candidates.map(\.path) == [
        "/Applications/Accio Computer Use.app/Contents/Resources/coding/runner.py",
    ])

    let error = CodingHarnessLaunchError.runnerNotFound(
        executablePath: executable.path,
        searchedPaths: candidates.map(\.path)
    )
    let description = try #require(error.errorDescription)
    #expect(description.contains("Executable: \(executable.path)"))
    #expect(description.contains(candidates[0].path))
    #expect(description.contains("command -v accio-computer-use"))
}
