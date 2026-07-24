import Darwin
import Foundation
@preconcurrency import Security

public protocol AutomationActivityPublishing: Sendable {
    func publish(_ event: AutomationActivityEvent)
}

public struct ActivitySocketClient: AutomationActivityPublishing, Sendable {
    public static let shared = ActivitySocketClient()
    public static let defaultSocketPath = "\(DaemonServer.defaultSocketDirectory)/activity.sock"
    static let maximumPayloadBytes = 8_192
    private static let deliveryQueue = DispatchQueue(
        label: "com.accio.computeruse.activity-delivery",
        qos: .utility
    )

    public let socketPath: String

    public init(socketPath: String = defaultSocketPath) {
        self.socketPath = socketPath
    }

    static func hasTrustedListener(at socketPath: String = defaultSocketPath) -> Bool {
        trustedListenerPID(at: socketPath) != nil
    }

    static func trustedListenerPID(at socketPath: String = defaultSocketPath) -> pid_t? {
        guard isSecureSocketPath(socketPath) else { return nil }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard connectSocket(descriptor, path: socketPath),
              LocalSocketPeerTrust.isTrustedPeer(descriptor) else {
            return nil
        }
        return LocalSocketPeerTrust.peerPID(descriptor)
    }

    public func publish(_ event: AutomationActivityEvent) {
        guard let payload = Self.payload(for: event) else { return }

        let path = socketPath
        Self.deliveryQueue.async {
            _ = Self.deliver(payload: payload, socketPath: path)
        }
    }

    func publishAndWaitForAcknowledgement(_ event: AutomationActivityEvent) -> Bool {
        guard let payload = Self.payload(for: event) else { return false }
        let path = socketPath
        return Self.deliveryQueue.sync {
            Self.deliver(payload: payload, socketPath: path)
        }
    }

    public static func flush(timeout: TimeInterval = 0.25) {
        let drained = DispatchSemaphore(value: 0)
        deliveryQueue.async { drained.signal() }
        _ = drained.wait(timeout: .now() + timeout)
    }

    private static func payload(for event: AutomationActivityEvent) -> Data? {
        guard let payload = try? JSONSerialization.data(
            withJSONObject: event.notificationUserInfo,
            options: [.withoutEscapingSlashes]
        ), payload.count <= maximumPayloadBytes else {
            return nil
        }
        return payload
    }

    private static func deliver(payload: Data, socketPath: String) -> Bool {
        guard isSecureSocketPath(socketPath) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            return false
        }

        guard connectSocket(descriptor, path: socketPath),
              LocalSocketPeerTrust.isTrustedPeer(descriptor) else {
            return false
        }

        let wrotePayload = payload.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < payload.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), payload.count - offset)
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wrotePayload else { return false }
        shutdown(descriptor, SHUT_WR)

        var acknowledgement = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&acknowledgement, 1, 250) > 0 else { return false }
        var byte: UInt8 = 0
        return read(descriptor, &byte, 1) == 1 && byte == 1
    }
}

public final class ActivitySocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AutomationActivityEvent) -> Void

    private let socketPath: String
    private let handler: Handler
    private let stateLock = NSLock()
    private var serverDescriptor: Int32 = -1
    private var boundDevice: dev_t?
    private var boundInode: ino_t?
    private var isStopping = false
    private var recentEventIDs: [UUID] = []
    private var rateByPID: [pid_t: (second: Int, count: Int)] = [:]

    public init(
        socketPath: String = ActivitySocketClient.defaultSocketPath,
        handler: @escaping Handler
    ) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        try prepareRuntimeDirectory()
        let lockDescriptor = try acquireStartupLock()
        defer {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }
        try removeOwnedStaleSocketIfPresent()

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ComputerUseError.message("Failed to create the Accio activity socket.")
        }

        guard bindSocket(descriptor, path: socketPath) else {
            close(descriptor)
            throw ComputerUseError.message("Failed to bind the Accio activity channel: \(String(cString: strerror(errno))).")
        }
        guard chmod(socketPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            let failure = errno
            close(descriptor)
            unlink(socketPath)
            throw ComputerUseError.message("Failed to secure the Accio activity channel: \(String(cString: strerror(failure))).")
        }
        guard listen(descriptor, 8) == 0 else {
            let failure = errno
            close(descriptor)
            unlink(socketPath)
            throw ComputerUseError.message("Failed to listen on the Accio activity channel: \(String(cString: strerror(failure))).")
        }
        var boundMetadata = stat()
        guard lstat(socketPath, &boundMetadata) == 0,
              isSecureSocketMetadata(boundMetadata) else {
            close(descriptor)
            unlink(socketPath)
            throw ComputerUseError.message("Failed to verify the Accio activity channel after binding.")
        }

        stateLock.lock()
        serverDescriptor = descriptor
        boundDevice = boundMetadata.st_dev
        boundInode = boundMetadata.st_ino
        isStopping = false
        stateLock.unlock()

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        stateLock.lock()
        guard !isStopping else {
            stateLock.unlock()
            return
        }
        isStopping = true
        let descriptor = serverDescriptor
        let expectedDevice = boundDevice
        let expectedInode = boundInode
        serverDescriptor = -1
        boundDevice = nil
        boundInode = nil
        stateLock.unlock()

        if descriptor >= 0 {
            close(descriptor)
            removeSocketIfOwned(device: expectedDevice, inode: expectedInode)
        }
    }

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let descriptor = serverDescriptor
            let stopping = isStopping
            stateLock.unlock()
            guard !stopping, descriptor >= 0 else { return }

            let client = accept(descriptor, nil, nil)
            guard client >= 0 else {
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var noSignal: Int32 = 1
        guard setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { return }
        guard LocalSocketPeerTrust.isTrustedPeer(client),
              let peerPID = LocalSocketPeerTrust.peerPID(client),
              allowEvent(from: peerPID) else {
            return
        }

        var payload = Data()
        var bytes = [UInt8](repeating: 0, count: 2_048)
        let deadline = Date(timeIntervalSinceNow: 1)
        while payload.count <= ActivitySocketClient.maximumPayloadBytes {
            let remainingMilliseconds = Int32(max(1, min(500, deadline.timeIntervalSinceNow * 1_000)))
            guard Date() < deadline else { return }
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, remainingMilliseconds) > 0,
                  (descriptor.revents & Int16(POLLIN | POLLHUP)) != 0 else {
                return
            }
            let count = bytes.withUnsafeMutableBytes { buffer in
                read(client, buffer.baseAddress, buffer.count)
            }
            if count <= 0 { break }
            payload.append(contentsOf: bytes[0..<count])
        }
        guard !payload.isEmpty,
              payload.count <= ActivitySocketClient.maximumPayloadBytes,
              let dictionary = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let event = AutomationActivityEvent.validated(userInfo: dictionary),
              rememberIfNew(event.eventID) else {
            return
        }
        handler(event)
        var acknowledgement: UInt8 = 1
        _ = write(client, &acknowledgement, 1)
    }

    private func allowEvent(from pid: pid_t) -> Bool {
        let second = Int(Date().timeIntervalSince1970)
        stateLock.lock()
        defer { stateLock.unlock() }
        let previous = rateByPID[pid]
        let next = previous?.second == second ? (second, (previous?.count ?? 0) + 1) : (second, 1)
        rateByPID[pid] = next
        if rateByPID.count > 32 {
            rateByPID = rateByPID.filter { $0.value.second >= second - 1 }
        }
        return next.1 <= 50
    }

    private func rememberIfNew(_ eventID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !recentEventIDs.contains(eventID) else { return false }
        recentEventIDs.append(eventID)
        if recentEventIDs.count > 256 {
            recentEventIDs.removeFirst(recentEventIDs.count - 256)
        }
        return true
    }

    private func prepareRuntimeDirectory() throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        if mkdir(directory, mode_t(S_IRWXU)) != 0, errno != EEXIST {
            throw ComputerUseError.message("Failed to create the Accio runtime directory.")
        }
        var metadata = stat()
        guard lstat(directory, &metadata) == 0,
              metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (metadata.st_mode & mode_t(S_IRWXG | S_IRWXO)) == 0 else {
            throw ComputerUseError.permissionDenied("Accio runtime directory must be owned by the current user with mode 0700.")
        }
    }

    private func acquireStartupLock() throws -> Int32 {
        let lockPath = socketPath + ".lock"
        let descriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw ComputerUseError.message("Failed to open the Accio activity startup lock.")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (metadata.st_mode & mode_t(S_IRWXG | S_IRWXO)) == 0 else {
            close(descriptor)
            throw ComputerUseError.permissionDenied("The Accio activity startup lock must be a current-user-owned 0600 file.")
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw ComputerUseError.message("Failed to lock Accio activity startup.")
        }
        return descriptor
    }

    private func removeOwnedStaleSocketIfPresent() throws {
        var metadata = stat()
        if lstat(socketPath, &metadata) != 0 {
            if errno == ENOENT { return }
            throw ComputerUseError.message("Failed to inspect the Accio activity socket.")
        }
        guard isSecureSocketMetadata(metadata) else {
            throw ComputerUseError.permissionDenied("Refusing to replace an unsafe Accio activity socket.")
        }
        if socketAcceptsConnection(at: socketPath) {
            throw ComputerUseError.message("The Accio activity channel is already running.")
        }
        guard unlink(socketPath) == 0 else {
            throw ComputerUseError.message("Failed to replace the stale Accio activity socket.")
        }
    }

    private func removeSocketIfOwned(device: dev_t?, inode: ino_t?) {
        var metadata = stat()
        guard let device, let inode,
              lstat(socketPath, &metadata) == 0,
              isSecureSocketMetadata(metadata),
              metadata.st_dev == device,
              metadata.st_ino == inode else { return }
        unlink(socketPath)
    }
}

private func connectSocket(_ descriptor: Int32, path: String) -> Bool {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
            for index in pathBytes.indices { destination[index] = pathBytes[index] }
        }
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}

private func bindSocket(_ descriptor: Int32, path: String) -> Bool {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
            for index in pathBytes.indices { destination[index] = pathBytes[index] }
        }
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}

private func isSecureSocketPath(_ path: String) -> Bool {
    var metadata = stat()
    return lstat(path, &metadata) == 0 && isSecureSocketMetadata(metadata)
}

private func socketAcceptsConnection(at path: String) -> Bool {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return true }
    defer { close(descriptor) }
    return connectSocket(descriptor, path: path)
}

private func isSecureSocketMetadata(_ metadata: stat) -> Bool {
    metadata.st_uid == getuid()
        && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
        && (metadata.st_mode & mode_t(S_IRWXG | S_IRWXO)) == 0
}

enum LocalSocketPeerTrust {
    static func isTrustedPeer(_ descriptor: Int32) -> Bool {
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(descriptor, &uid, &gid) == 0,
              uid == getuid(),
              let pid = peerPID(descriptor) else {
            return false
        }
        if pid == getpid() {
            return true
        }
        guard let auditToken = peerAuditToken(descriptor),
              let peerCode = dynamicCode(for: auditToken),
              let requirement = currentDesignatedRequirement() else {
            return false
        }
        return SecCodeCheckValidity(peerCode, SecCSFlags(), requirement) == errSecSuccess
    }

    static func peerPID(_ descriptor: Int32) -> pid_t? {
        var pid = pid_t()
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return pid
    }

    private static func peerAuditToken(_ descriptor: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size else {
            return nil
        }
        return token
    }

    private static func dynamicCode(for auditToken: audit_token_t) -> SecCode? {
        var token = auditToken
        let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit as String: data] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private static func currentDesignatedRequirement() -> SecRequirement? {
        var currentCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &currentCode) == errSecSuccess,
              let currentCode else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(currentCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }
}
