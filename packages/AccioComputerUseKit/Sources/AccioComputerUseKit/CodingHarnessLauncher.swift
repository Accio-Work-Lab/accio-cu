import Darwin
import Foundation

public enum CodingHarnessLaunchError: LocalizedError, Equatable {
    case runnerNotFound
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runnerNotFound:
            return """
            Accio's internal Python runner was not found. Reinstall with \
            `scripts/install-macos.sh`, or set ACCIO_COMPUTER_USE_CODING_RUNNER \
            to a source checkout's coding/runner.py.
            """
        case let .launchFailed(message):
            return "Failed to start Accio's Python runner: \(message)"
        }
    }
}

public enum CodingHarnessLauncher {
    public static let runnerEnvironmentKey = "ACCIO_COMPUTER_USE_CODING_RUNNER"

    public static func processExecutableURL(
        argumentZero: String = CommandLine.arguments[0],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        var bufferSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &bufferSize)
        if bufferSize > 0 {
            var buffer = [CChar](repeating: 0, count: Int(bufferSize))
            let status = buffer.withUnsafeMutableBufferPointer { pointer in
                _NSGetExecutablePath(pointer.baseAddress, &bufferSize)
            }
            if status == 0 {
                let executableURL = buffer.withUnsafeBufferPointer { pointer in
                    URL(
                        fileURLWithFileSystemRepresentation: pointer.baseAddress!,
                        isDirectory: false,
                        relativeTo: nil
                    )
                }
                return executableURL.resolvingSymlinksInPath()
            }
        }

        return commandLineExecutableURL(
            argumentZero: argumentZero,
            environment: environment,
            fileManager: fileManager
        )
    }

    public static func commandLineExecutableURL(
        argumentZero: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> URL {
        if argumentZero.contains("/") {
            return URL(fileURLWithPath: argumentZero).resolvingSymlinksInPath()
        }

        for directory in environment["PATH", default: ""].split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(argumentZero)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath()
            }
        }

        return URL(fileURLWithPath: argumentZero).resolvingSymlinksInPath()
    }

    public static func runnerURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL = processExecutableURL(),
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        fileManager: FileManager = .default
    ) -> URL? {
        let environmentRunner = environment[runnerEnvironmentKey]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let bundleRunner = bundleResourceURL.map {
            $0.appendingPathComponent("coding", isDirectory: true)
                .appendingPathComponent("runner.py")
        }
        let installedRunner =
            executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("coding", isDirectory: true)
                .appendingPathComponent("runner.py")
        let checkoutRunner = sourceCheckoutRunnerURL(for: executableURL)
        let candidates = [
            environmentRunner,
            bundleRunner,
            installedRunner,
            checkoutRunner,
        ].compactMap { $0 }
        return candidates.first { fileManager.isReadableFile(atPath: $0.path) }
    }

    private static func sourceCheckoutRunnerURL(for executableURL: URL) -> URL? {
        var current = executableURL.deletingLastPathComponent()
        for _ in 0..<64 {
            if current.lastPathComponent == ".build" {
                return current
                    .deletingLastPathComponent()
                    .appendingPathComponent("coding", isDirectory: true)
                    .appendingPathComponent("runner.py")
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return nil }
            current = parent
        }
        return nil
    }

    @discardableResult
    public static func run(arguments: [String]) throws -> Int32 {
        guard let runner = runnerURL() else {
            throw CodingHarnessLaunchError.runnerNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", runner.path] + arguments
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw CodingHarnessLaunchError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal {
            return 128 + process.terminationStatus
        }
        return process.terminationStatus
    }
}
