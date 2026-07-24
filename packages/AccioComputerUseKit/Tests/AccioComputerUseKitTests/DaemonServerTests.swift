import Foundation
import Testing
@testable import AccioComputerUseKit

@MainActor
@Test("Daemon event loop leaves the main queue available to action handlers")
func daemonEventLoopLeavesMainQueueAvailable() {
    let acceptLoopStarted = DispatchSemaphore(value: 0)
    let releaseAcceptLoop = DispatchSemaphore(value: 0)
    let acceptLoopFinished = DispatchSemaphore(value: 0)

    DaemonServer.runEventLoop(
        acceptConnections: {
            acceptLoopStarted.signal()
            releaseAcceptLoop.wait()
            acceptLoopFinished.signal()
        },
        runMainLoop: {
            #expect(acceptLoopStarted.wait(timeout: .now() + 3) == .success)
            // Reaching this closure on the main thread while the accept loop
            // remains blocked proves socket acceptance was detached from the
            // AppKit event-loop thread. Avoid a nested main-queue sync here;
            // Swift Testing may itself own the main-actor executor.
            #expect(Thread.isMainThread)
        }
    )

    releaseAcceptLoop.signal()
    #expect(acceptLoopFinished.wait(timeout: .now() + 3) == .success)
}

@Test("Daemon refuses to replace a live current-user socket")
func daemonRefusesToReplaceLiveSocket() throws {
    let directory = URL(
        fileURLWithPath: "/tmp/accio-daemon-live-\(UUID().uuidString)",
        isDirectory: true
    )
    let socketPath = directory.appendingPathComponent("daemon.sock").path
    let listener = ActivitySocketServer(socketPath: socketPath) { _ in }
    defer {
        listener.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    try listener.start()

    #expect(DaemonClient.isAvailable(socketPath: socketPath))
    #expect(throws: (any Error).self) {
        try DaemonServer.removeOwnedStaleSocketIfPresent(at: socketPath)
    }
    #expect(DaemonClient.isAvailable(socketPath: socketPath))
}
