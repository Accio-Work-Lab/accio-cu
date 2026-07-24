import Darwin
import Foundation
import Testing
@testable import AccioComputerUseKit

@Test("shared pause state is persistent rather than stored in temporary files")
func sharedPauseStateUsesApplicationSupport() {
    #expect(AutomationPauseStore.shared.directoryURL.path.contains("/Library/Application Support/"))
    #expect(!AutomationPauseStore.shared.directoryURL.path.hasPrefix("/tmp/"))
}

@Test("pause marker is shared across store instances and uses private permissions")
func pauseMarkerIsSharedAndPrivate() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("accio-pause-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let writer = AutomationPauseStore(directoryURL: directory)
    let reader = AutomationPauseStore(directoryURL: directory)

    try writer.setPaused(true)
    #expect(reader.isPaused)

    var directoryMetadata = stat()
    var markerMetadata = stat()
    #expect(lstat(directory.path, &directoryMetadata) == 0)
    #expect(lstat(writer.markerURL.path, &markerMetadata) == 0)
    #expect(directoryMetadata.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0)
    #expect(markerMetadata.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0)

    try reader.setPaused(false)
    #expect(!writer.isPaused)
}

@Test("automation policy blocks every tool while paused")
func automationPolicyBlocksToolsWhilePaused() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("accio-policy-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = AutomationPauseStore(directoryURL: directory)
    try store.setPaused(true)
    let policy = AutomationPolicy(pauseStore: store)

    for tool in ["list_apps", "get_app_state", "get_screen_state", "click", "type_text"] {
        #expect(throws: ComputerUseError.self) {
            try policy.authorizeToolCall(named: tool)
        }
    }

    try store.setPaused(false)
    try policy.authorizeToolCall(named: "get_app_state")
}
