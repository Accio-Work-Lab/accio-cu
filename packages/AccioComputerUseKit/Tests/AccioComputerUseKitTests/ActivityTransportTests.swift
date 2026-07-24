import Foundation
import Testing
@testable import AccioComputerUseKit

private final class ReceivedActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvent: AutomationActivityEvent?

    func store(_ event: AutomationActivityEvent) {
        lock.lock()
        storedEvent = event
        lock.unlock()
    }

    var event: AutomationActivityEvent? {
        lock.lock()
        defer { lock.unlock() }
        return storedEvent
    }
}

@Suite(.serialized)
struct ActivityTransportTests {
    @Test("activity socket accepts an allowlisted event from the same executable")
    func acceptsTrustedEvent() throws {
        let directory = URL(
            fileURLWithPath: "/tmp/accio-activity-\(UUID().uuidString)",
            isDirectory: true
        )
        let socketPath = directory.appendingPathComponent("activity.sock").path
        let received = ReceivedActivity()
        let delivered = DispatchSemaphore(value: 0)
        let server = ActivitySocketServer(socketPath: socketPath) { event in
            received.store(event)
            delivered.signal()
        }
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        try server.start()
        let expected = AutomationActivityEvent(
            phase: .acting,
            actionKind: .click,
            targetApp: "Safari"
        )
        ActivitySocketClient(socketPath: socketPath).publish(expected)

        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(received.event?.eventID == expected.eventID)
        #expect(received.event?.phase == expected.phase)
        #expect(received.event?.actionKind == expected.actionKind)
        #expect(received.event?.targetApp == expected.targetApp)
        #expect(received.event?.captureKind == expected.captureKind)
    }

    @Test("activity socket refuses to replace a live listener")
    func refusesSecondListener() throws {
        let directory = URL(
            fileURLWithPath: "/tmp/accio-activity-\(UUID().uuidString)",
            isDirectory: true
        )
        let socketPath = directory.appendingPathComponent("activity.sock").path
        let first = ActivitySocketServer(socketPath: socketPath) { _ in }
        let second = ActivitySocketServer(socketPath: socketPath) { _ in }
        defer {
            second.stop()
            first.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        try first.start()
        #expect(throws: (any Error).self) {
            try second.start()
        }
    }

    @Test("stopping an old activity server does not unlink a replacement inode")
    func oldServerPreservesReplacementSocket() throws {
        let directory = URL(
            fileURLWithPath: "/tmp/accio-activity-\(UUID().uuidString)",
            isDirectory: true
        )
        let socketPath = directory.appendingPathComponent("activity.sock").path
        let first = ActivitySocketServer(socketPath: socketPath) { _ in }
        let replacement = ActivitySocketServer(socketPath: socketPath) { _ in }
        defer {
            replacement.stop()
            first.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        try first.start()
        #expect(unlink(socketPath) == 0)
        try replacement.start()
        first.stop()

        #expect(ActivitySocketClient.hasTrustedListener(at: socketPath))
    }

    @Test("activity socket rejects a differently signed executable")
    func rejectsDifferentExecutable() throws {
        let pythonPath = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else { return }

        let directory = URL(
            fileURLWithPath: "/tmp/accio-activity-\(UUID().uuidString)",
            isDirectory: true
        )
        let socketPath = directory.appendingPathComponent("activity.sock").path
        let delivered = DispatchSemaphore(value: 0)
        let server = ActivitySocketServer(socketPath: socketPath) { _ in delivered.signal() }
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        try server.start()

        let event = AutomationActivityEvent(
            phase: .acting,
            actionKind: .click,
            targetApp: "Safari"
        )
        let payload = try JSONSerialization.data(withJSONObject: event.notificationUserInfo)
        let script = """
        import base64, socket, time
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(\(String(reflecting: socketPath)))
        client.sendall(base64.b64decode(\(String(reflecting: payload.base64EncodedString()))))
        time.sleep(0.5)
        client.close()
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()

        #expect(delivered.wait(timeout: .now() + 0.2) == .timedOut)
    }
}
