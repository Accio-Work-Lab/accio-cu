import Foundation

// Global state for signal handler (C function pointers cannot capture context).
// Access is safe: written once before signals can fire, read only in signal handlers.
nonisolated(unsafe) private var _daemonServerFD: Int32 = -1

public enum DaemonStartupError: Error, LocalizedError, Equatable {
    case permissionsPending([SystemPermissionKind])

    public var exitCode: Int32 { 2 }

    public var errorDescription: String? {
        switch self {
        case .permissionsPending(let permissions):
            let names = permissions.map(\.title).joined(separator: ", ")
            return "Daemon refusing to start: missing effective permission(s): \(names). "
                + "Run `accio-computer-use setup --wait-for-permissions`."
        }
    }
}

public final class DaemonServer: @unchecked Sendable {
    public static let defaultSocketDirectory = "/tmp/accio-computer-use-\(getuid())"
    public static let defaultSocketPath = "\(defaultSocketDirectory)/daemon.sock"
    private static let maxRequestBytes = 1_048_576
    private static let readTimeoutMilliseconds: Int32 = 2_000

    private let socketPath: String
    private let mcpServer: StdioMCPServer
    private let handlingLock = NSLock()
    private var serverFD: Int32 = -1

    public init(socketPath: String = DaemonServer.defaultSocketPath, service: ComputerUseService = ComputerUseService()) {
        self.socketPath = socketPath
        self.mcpServer = StdioMCPServer(service: service)
    }

    public func run() throws {
        guard Thread.isMainThread else {
            throw ComputerUseError.message("DaemonServer.run() must be called on the main thread")
        }

        // Validate actual runtime permissions before serving.
        // TCC database entries may not be effective for LaunchAgent processes
        // on macOS 15+, leading to degraded responses (elements=0, no screenshot).
        let runtimePerms = PermissionDiagnostics.runtimeProbe()
        if !runtimePerms.allGranted {
            throw DaemonStartupError.permissionsPending(runtimePerms.missingPermissions)
        }

        try bindSocket()
        installSignalHandlers()
        FileHandle.standardError.write(Data("Listening on \(socketPath)\n".utf8))

        Self.runEventLoop(
            acceptConnections: { [self] in acceptConnections() },
            runMainLoop: { RunLoop.main.run() }
        )
    }

    static func startAcceptLoop(_ body: @escaping @Sendable () -> Void) {
        Thread.detachNewThread(body)
    }

    static func runEventLoop(
        acceptConnections: @escaping @Sendable () -> Void,
        runMainLoop: () -> Void
    ) {
        startAcceptLoop(acceptConnections)
        runMainLoop()
    }

    // MARK: - Private

    private func acceptConnections() {
        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                    accept(serverFD, addrPtr, &clientLen)
                }
            }
            guard clientFD >= 0 else { continue }
            if Self.isAuthorizedPeer(clientFD) {
                Thread.detachNewThread { [self] in
                    handleConnection(clientFD)
                    close(clientFD)
                }
            } else {
                FileHandle.standardError.write(Data("Rejected daemon client from a different user.\n".utf8))
                close(clientFD)
            }
        }
    }

    private func bindSocket() throws {
        try prepareSocketDirectoryIfNeeded()
        let lockFD = try acquireSocketLock()
        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        try Self.removeOwnedStaleSocketIfPresent(at: socketPath)

        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw ComputerUseError.message("Failed to create Unix socket: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ComputerUseError.message("Socket path too long: \(socketPath)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(serverFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFD)
            throw ComputerUseError.message("Failed to bind socket at \(socketPath): \(String(cString: strerror(errno)))")
        }

        guard chmod(socketPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            close(serverFD)
            unlink(socketPath)
            throw ComputerUseError.message("Failed to restrict socket permissions at \(socketPath): \(String(cString: strerror(errno)))")
        }

        guard listen(serverFD, 5) == 0 else {
            close(serverFD)
            unlink(socketPath)
            throw ComputerUseError.message("Failed to listen on socket: \(String(cString: strerror(errno)))")
        }
    }

    private func acquireSocketLock() throws -> Int32 {
        let lockPath = socketPath + ".lock"
        let descriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw ComputerUseError.message("Failed to open daemon socket lock: \(String(cString: strerror(errno)))")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (metadata.st_mode & mode_t(S_IRWXG | S_IRWXO)) == 0 else {
            close(descriptor)
            throw ComputerUseError.message("Daemon socket lock must be a current-user-owned 0600 file")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let failure = errno
            close(descriptor)
            throw ComputerUseError.message("Failed to lock daemon socket startup: \(String(cString: strerror(failure)))")
        }
        return descriptor
    }

    private func prepareSocketDirectoryIfNeeded() throws {
        guard socketPath == DaemonServer.defaultSocketPath else { return }
        let path = DaemonServer.defaultSocketDirectory
        if mkdir(path, mode_t(S_IRWXU)) != 0, errno != EEXIST {
            throw ComputerUseError.message("Failed to create daemon socket directory: \(String(cString: strerror(errno)))")
        }

        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (metadata.st_mode & mode_t(S_IRWXG | S_IRWXO)) == 0 else {
            throw ComputerUseError.message("Daemon socket directory must be a current-user-owned 0700 directory: \(path)")
        }
    }

    static func removeOwnedStaleSocketIfPresent(at socketPath: String) throws {
        var metadata = stat()
        if lstat(socketPath, &metadata) != 0 {
            if errno == ENOENT { return }
            throw ComputerUseError.message("Failed to inspect daemon socket: \(String(cString: strerror(errno)))")
        }
        guard metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK),
              (metadata.st_mode & mode_t(S_IRWXG | S_IRWXO)) == 0 else {
            throw ComputerUseError.message("Refusing to replace an unsafe daemon socket path: \(socketPath)")
        }
        guard !DaemonClient.hasLiveCurrentUserListener(socketPath: socketPath) else {
            throw ComputerUseError.message("A process is already listening at \(socketPath)")
        }
        guard unlink(socketPath) == 0 else {
            throw ComputerUseError.message("Failed to remove stale daemon socket: \(String(cString: strerror(errno)))")
        }
    }

    private static func isAuthorizedPeer(_ fd: Int32) -> Bool {
        var uid = uid_t()
        var gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    private func handleConnection(_ fd: Int32) {
        guard let data = readAllAvailableData(from: fd),
              let input = String(data: data, encoding: .utf8) else {
            return
        }

        for line in input.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            handlingLock.lock()
            defer { handlingLock.unlock() }
            if let response = mcpServer.handle(line: trimmed) {
                let responseData = Data((response + "\n").utf8)
                _ = write(fd, [UInt8](responseData), responseData.count)
            }
        }
    }

    private func readAllAvailableData(from fd: Int32) -> Data? {
        var buffer = Data()
        let chunkSize = 65536
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, DaemonServer.readTimeoutMilliseconds)
            guard ready > 0, (descriptor.revents & Int16(POLLIN)) != 0 else {
                break
            }

            let bytesRead = read(fd, &chunk, chunkSize)
            if bytesRead <= 0 { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])
            if buffer.count > DaemonServer.maxRequestBytes {
                FileHandle.standardError.write(Data("Rejected daemon request larger than \(DaemonServer.maxRequestBytes) bytes.\n".utf8))
                return nil
            }
            if bytesRead < chunkSize { break }
        }
        return buffer.isEmpty ? nil : buffer
    }

    private func installSignalHandlers() {
        _daemonServerFD = serverFD
        signal(SIGINT) { _ in
            close(_daemonServerFD)
            _exit(0)
        }
        signal(SIGTERM) { _ in
            close(_daemonServerFD)
            _exit(0)
        }
    }
}
