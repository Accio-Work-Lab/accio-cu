import Foundation

public enum DaemonClient {
    public static func isAvailable(socketPath: String = DaemonServer.defaultSocketPath) -> Bool {
        hasLiveCurrentUserListener(socketPath: socketPath)
    }

    static func hasLiveCurrentUserListener(socketPath: String) -> Bool {
        withConnectedSecureSocket(socketPath: socketPath) { fd in
            var uid = uid_t()
            var gid = gid_t()
            return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
        }
    }

    /// Forwards a tool call to the daemon via Unix socket.
    /// Returns the raw JSON-RPC result dictionary, or nil if daemon is unreachable.
    public static func callTool(
        socketPath: String = DaemonServer.defaultSocketPath,
        toolName: String,
        arguments: [String: Any]
    ) -> [String: Any]? {
        guard isSecureSocketPath(socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        guard connectSocket(fd, socketPath: socketPath) else { return nil }
        guard isCurrentUserPeer(fd) else { return nil }

        // Build JSON-RPC request (same format as MCP tools/call)
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": toolName, "arguments": arguments],
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              let requestLine = String(data: requestData, encoding: .utf8) else {
            return nil
        }

        // Send request
        let payload = Data((requestLine + "\n").utf8)
        let written = payload.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress!, payload.count)
        }
        guard written == payload.count else { return nil }

        // Signal write end done so server knows request is complete
        shutdown(fd, SHUT_WR)

        // Read response
        var responseBuffer = Data()
        let chunkSize = 65536
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = read(fd, &chunk, chunkSize)
            if bytesRead <= 0 { break }
            responseBuffer.append(contentsOf: chunk[0..<bytesRead])
        }

        guard !responseBuffer.isEmpty else { return nil }

        // Parse first line as JSON-RPC response
        guard let responseString = String(data: responseBuffer, encoding: .utf8) else { return nil }
        let firstLine = responseString.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard let line = firstLine,
              let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }

        // Extract result from JSON-RPC response
        return json["result"] as? [String: Any]
    }

    private static func isSecureSocketPath(_ socketPath: String) -> Bool {
        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0 else { return false }
        return metadata.st_uid == getuid()
            && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK)
            && (metadata.st_mode & mode_t(S_IRWXG | S_IRWXO)) == 0
    }

    private static func withConnectedSecureSocket(
        socketPath: String,
        validate: (Int32) -> Bool
    ) -> Bool {
        guard isSecureSocketPath(socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return connectSocket(fd, socketPath: socketPath) && validate(fd)
    }

    private static func isCurrentUserPeer(_ fd: Int32) -> Bool {
        var uid = uid_t()
        var gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    private static func connectSocket(_ fd: Int32, socketPath: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { destination in
                for index in pathBytes.indices {
                    destination[index] = pathBytes[index]
                }
            }
        }
        return withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}
