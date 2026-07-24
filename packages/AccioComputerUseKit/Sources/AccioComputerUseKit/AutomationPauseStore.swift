import Darwin
import Foundation

public struct AutomationPauseStore: Sendable {
    public static let shared = AutomationPauseStore(
        directoryURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AccioComputerUse", isDirectory: true)
    )

    public let directoryURL: URL
    public var markerURL: URL { directoryURL.appendingPathComponent("automation-paused", isDirectory: false) }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public var isPaused: Bool {
        switch inspectDirectory() {
        case .missing:
            return false
        case .unsafe:
            return true
        case .safe:
            break
        }

        var metadata = stat()
        if lstat(markerURL.path, &metadata) != 0 {
            return errno != ENOENT
        }
        // A valid marker means paused; an invalid marker fails closed as paused.
        return true
    }

    public func setPaused(_ paused: Bool) throws {
        try ensureSafeDirectory()
        if paused {
            try createPauseMarker()
        } else {
            try removePauseMarker()
        }
    }

    private enum DirectoryInspection {
        case missing
        case safe
        case unsafe
    }

    private func inspectDirectory() -> DirectoryInspection {
        var metadata = stat()
        guard lstat(directoryURL.path, &metadata) == 0 else {
            return errno == ENOENT ? .missing : .unsafe
        }
        let safe = metadata.st_uid == getuid()
            && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && (metadata.st_mode & mode_t(S_IRWXG | S_IRWXO)) == 0
        return safe ? .safe : .unsafe
    }

    private func ensureSafeDirectory() throws {
        switch inspectDirectory() {
        case .safe:
            return
        case .unsafe:
            throw ComputerUseError.permissionDenied("Accio runtime control directory is unsafe. Automation remains paused.")
        case .missing:
            guard mkdir(directoryURL.path, mode_t(S_IRWXU)) == 0 || errno == EEXIST else {
                throw ComputerUseError.message("Failed to create the Accio runtime control directory.")
            }
            guard case .safe = inspectDirectory() else {
                throw ComputerUseError.permissionDenied("Accio runtime control directory is unsafe. Automation remains paused.")
            }
        }
    }

    private func createPauseMarker() throws {
        let descriptor = open(markerURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        if descriptor >= 0 {
            defer { close(descriptor) }
            let bytes = Array("paused\n".utf8)
            guard write(descriptor, bytes, bytes.count) == bytes.count else {
                unlink(markerURL.path)
                throw ComputerUseError.message("Failed to persist the automation pause state.")
            }
            _ = fsync(descriptor)
            return
        }

        guard errno == EEXIST else {
            throw ComputerUseError.message("Failed to pause Accio automation.")
        }
        var metadata = stat()
        guard lstat(markerURL.path, &metadata) == 0, isSafeMarker(metadata) else {
            throw ComputerUseError.permissionDenied("Accio pause state is unsafe. Automation remains paused.")
        }
    }

    private func removePauseMarker() throws {
        var metadata = stat()
        if lstat(markerURL.path, &metadata) != 0 {
            if errno == ENOENT { return }
            throw ComputerUseError.message("Failed to inspect the automation pause state.")
        }
        guard isSafeMarker(metadata) else {
            throw ComputerUseError.permissionDenied("Accio pause state is unsafe and cannot be resumed automatically.")
        }
        guard unlink(markerURL.path) == 0 else {
            throw ComputerUseError.message("Failed to resume Accio automation.")
        }
    }

    private func isSafeMarker(_ metadata: stat) -> Bool {
        metadata.st_uid == getuid()
            && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && (metadata.st_mode & mode_t(S_IRWXG | S_IRWXO)) == 0
    }
}

public struct AutomationPolicy: Sendable {
    public static let pausedMessage = "Accio automation is paused by the user. Resume it from a local Accio control surface."
    public let pauseStore: AutomationPauseStore

    public init(pauseStore: AutomationPauseStore = .shared) {
        self.pauseStore = pauseStore
    }

    public func authorizeToolCall(named _: String) throws {
        guard !pauseStore.isPaused else {
            throw ComputerUseError.permissionDenied(Self.pausedMessage)
        }
    }
}
