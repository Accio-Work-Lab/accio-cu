import AppKit
import ApplicationServices
import CoreGraphics
import Testing
@testable import AccioComputerUseKit

private func syntheticApp() -> RunningAppDescriptor {
    RunningAppDescriptor(
        name: "SyntheticApp",
        bundleIdentifier: "com.example.synthetic",
        pid: NSRunningApplication.current.processIdentifier,
        runningApplication: NSRunningApplication.current
    )
}

private func syntheticElement(
    index: Int,
    role: String,
    text: String?,
    actions: [String] = [],
    stableKey: String,
    element: AXUIElement? = nil
) -> ElementRecord {
    ElementRecord(
        index: index,
        identifier: nil,
        element: element,
        localFrame: CGRect(x: 0, y: index * 10, width: 100, height: 10),
        rawActions: actions,
        prettyActions: actions,
        displayText: text,
        role: role,
        stableKey: stableKey
    )
}

private func syntheticSnapshot(
    id: String,
    title: String = "Main",
    windowID: CGWindowID = 7,
    elements orderedElements: [ElementRecord]
) -> AppSnapshot {
    let elements = Dictionary(uniqueKeysWithValues: orderedElements.map { ($0.index, $0) })
    let lines = orderedElements.map { record -> String in
        let text = record.displayText.map { " \"\($0)\"" } ?? ""
        let actions = record.prettyActions.isEmpty ? "" : " actions=[\(record.prettyActions.joined(separator: ", "))]"
        return "[\(record.index)] \(record.role ?? "AXUnknown")\(text)\(actions)"
    }
    return AppSnapshot(
        snapshotID: id,
        app: syntheticApp(),
        windowTitle: title,
        windowBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
        targetWindowID: windowID,
        targetWindowLayer: 0,
        screenshotPNGData: Data([0x89, 0x50, 0x4E, 0x47]),
        screenRecordingDenied: false,
        treeLines: lines,
        focusedSummary: nil,
        selectedText: nil,
        elements: elements,
        elementCount: elements.count
    )
}

@Test("stable refs are reused, new nodes get incrementing refs, and removed refs are reported")
func axDiffReusesRefsAndReportsNewAndRemovedRefs() {
    let before = syntheticSnapshot(id: "before", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
        syntheticElement(index: 1, role: "AXButton", text: "Save", actions: ["AXPress"], stableKey: "root/save"),
        syntheticElement(index: 2, role: "AXButton", text: "Cancel", actions: ["AXPress"], stableKey: "root/cancel"),
    ])
    let beforeState = AXSnapshotDiff.applyStableRefs(snapshot: before, previous: nil)
    let after = syntheticSnapshot(id: "after", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
        syntheticElement(index: 1, role: "AXButton", text: "Save", actions: ["AXPress"], stableKey: "root/save"),
        syntheticElement(index: 2, role: "AXButton", text: "Apply", actions: ["AXPress"], stableKey: "root/apply"),
    ])
    _ = AXSnapshotDiff.applyStableRefs(snapshot: after, previous: beforeState)

    let partition = AXSnapshotDiff.partitionRefs(before: before, after: after)

    #expect(partition.kept == ["a1", "a2"])
    #expect(partition.new == ["a4"])
    #expect(partition.removed == ["a3"])
}

@Test("AXDIFF formatting includes compact ref ranges and new subtree with current indices")
func axDiffFormatsRangesAndNewSubtree() {
    let before = syntheticSnapshot(id: "before", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
        syntheticElement(index: 1, role: "AXGroup", text: "Controls", stableKey: "root/controls"),
        syntheticElement(index: 2, role: "AXButton", text: "Save", actions: ["AXPress"], stableKey: "root/controls/save"),
    ])
    let beforeState = AXSnapshotDiff.applyStableRefs(snapshot: before, previous: nil)
    let after = syntheticSnapshot(id: "after", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
        syntheticElement(index: 1, role: "AXGroup", text: "Controls", stableKey: "root/controls"),
        syntheticElement(index: 2, role: "AXButton", text: "Save", actions: ["AXPress"], stableKey: "root/controls/save"),
        syntheticElement(index: 3, role: "AXButton", text: "Apply", actions: ["AXPress"], stableKey: "root/controls/apply"),
    ])
    _ = AXSnapshotDiff.applyStableRefs(snapshot: after, previous: beforeState)

    let diff = AXSnapshotDiff.makeDiff(
        before: before,
        after: after,
        actionSummary: "[Result] tool=click route=ax_press changed=confirmed",
        fullText: String(repeating: "full snapshot text\n", count: 100)
    )

    #expect(diff.shouldUseDiff)
    #expect(diff.text?.contains("AXDIFF v1 snapshot=after elements=4") == true)
    #expect(diff.text?.contains("kept_refs (3): a1-a3") == true)
    #expect(diff.text?.contains("new_refs (1): a4") == true)
    #expect(diff.text?.contains("[3] AXButton \"Apply\" ref=a4 actions=[AXPress]") == true)
}

@Test("diff admission falls back when refs are missing, bucket changes, or diff is not smaller")
func axDiffAdmissionFallsBackForUnsafeCases() {
    let beforeWithoutRefs = syntheticSnapshot(id: "before", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
    ])
    let afterWithoutRefs = syntheticSnapshot(id: "after", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
        syntheticElement(index: 1, role: "AXButton", text: "Apply", actions: ["AXPress"], stableKey: "root/apply"),
    ])
    let noRefs = AXSnapshotDiff.makeDiff(
        before: beforeWithoutRefs,
        after: afterWithoutRefs,
        actionSummary: "[Result] changed=confirmed",
        fullText: String(repeating: "full\n", count: 20)
    )
    #expect(!noRefs.shouldUseDiff)
    #expect(noRefs.reason == "no_previous_refs")

    let before = syntheticSnapshot(id: "before", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
        syntheticElement(index: 1, role: "AXButton", text: "Save", actions: ["AXPress"], stableKey: "root/save"),
    ])
    let beforeState = AXSnapshotDiff.applyStableRefs(snapshot: before, previous: nil)
    let changedWindow = syntheticSnapshot(id: "after", title: "Other", windowID: 8, elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Other", stableKey: "root"),
        syntheticElement(index: 1, role: "AXButton", text: "Save", actions: ["AXPress"], stableKey: "root/save"),
    ])
    _ = AXSnapshotDiff.applyStableRefs(snapshot: changedWindow, previous: beforeState)

    let bucketChanged = AXSnapshotDiff.makeDiff(
        before: before,
        after: changedWindow,
        actionSummary: "[Result] changed=confirmed",
        fullText: String(repeating: "full\n", count: 100)
    )
    #expect(!bucketChanged.shouldUseDiff)
    #expect(bucketChanged.reason == "bucket_changed")

    let notWorthIt = AXSnapshotDiff.makeDiff(
        before: before,
        after: before,
        actionSummary: "[Result] changed=confirmed",
        fullText: "tiny"
    )
    #expect(!notWorthIt.shouldUseDiff)
    #expect(notWorthIt.reason == "not_worth_it")
}

@Test("full snapshot rendering preserves ephemeral index and adds stable ref")
func fullSnapshotRenderingAddsStableRefsWithoutDroppingIndices() {
    let snapshot = syntheticSnapshot(id: "snap", elements: [
        syntheticElement(index: 5, role: "AXButton", text: "Save", actions: ["AXPress"], stableKey: "root/save"),
    ])
    _ = AXSnapshotDiff.applyStableRefs(snapshot: snapshot, previous: nil)

    let text = snapshot.renderedText(style: .fullState)

    #expect(text.contains("[5] AXButton \"Save\" ref=a1 actions=[AXPress]"))
}

@Test("mutable window titles stay in one stable-ref lineage")
func mutableWindowTitlesPreserveStableRefs() {
    let before = syntheticSnapshot(id: "before", title: "Document", elements: [
        syntheticElement(
            index: 0,
            role: "AXWindow",
            text: "Document",
            stableKey: "text|AXWindow|document||0"
        ),
        syntheticElement(
            index: 1,
            role: "AXTextArea",
            text: nil,
            stableKey: "text|AXWindow|document||0/text|AXTextArea|||0"
        ),
    ])
    let beforeState = AXSnapshotDiff.applyStableRefs(snapshot: before, previous: nil)
    let after = syntheticSnapshot(id: "after", title: "Document — Edited", elements: [
        syntheticElement(
            index: 0,
            role: "AXWindow",
            text: "Document — Edited",
            stableKey: "text|AXWindow|document — edited||0"
        ),
        syntheticElement(
            index: 1,
            role: "AXTextArea",
            text: nil,
            stableKey: "text|AXWindow|document — edited||0/text|AXTextArea|||0"
        ),
    ])

    #expect(AXSnapshotDiff.bucketKey(for: before) == AXSnapshotDiff.bucketKey(for: after))
    _ = AXSnapshotDiff.applyStableRefs(snapshot: after, previous: beforeState)

    #expect(before.elements[0]?.stableRef == after.elements[0]?.stableRef)
    #expect(before.elements[1]?.stableRef == after.elements[1]?.stableRef)

    let diff = AXSnapshotDiff.makeDiff(
        before: before,
        after: after,
        actionSummary: "[Result] changed=confirmed",
        fullText: String(repeating: "full state\n", count: 100)
    )
    #expect(diff.shouldUseDiff)
    #expect(diff.text?.contains("changed_refs") == true)
    #expect(diff.text?.contains("Document — Edited") == true)
}

@Test("AX identity survives mutable semantic keys while replacement identity retires the old ref")
func axIdentityControlsStableRefReuse() throws {
    let originalIdentity = AXUIElementCreateApplication(101)
    let replacementIdentity = AXUIElementCreateApplication(102)
    let before = syntheticSnapshot(id: "before", elements: [
        syntheticElement(
            index: 0,
            role: "AXButton",
            text: "Start",
            stableKey: "root/start",
            element: originalIdentity
        ),
    ])
    let beforeState = AXSnapshotDiff.applyStableRefs(snapshot: before, previous: nil)
    let originalRef = try #require(before.elements[0]?.stableRef)

    let propertyChanged = syntheticSnapshot(id: "changed", elements: [
        syntheticElement(
            index: 0,
            role: "AXButton",
            text: "Stop",
            stableKey: "root/stop",
            element: originalIdentity
        ),
    ])
    let changedState = AXSnapshotDiff.applyStableRefs(
        snapshot: propertyChanged,
        previous: beforeState
    )
    #expect(propertyChanged.elements[0]?.stableRef == originalRef)

    let replaced = syntheticSnapshot(id: "replaced", elements: [
        syntheticElement(
            index: 0,
            role: "AXButton",
            text: "Stop",
            stableKey: "root/stop",
            element: replacementIdentity
        ),
    ])
    _ = AXSnapshotDiff.applyStableRefs(snapshot: replaced, previous: changedState)
    #expect(replaced.elements[0]?.stableRef != originalRef)
    let service = ComputerUseService()
    #expect(throws: ComputerUseError.self) {
        try service.lookupElementByStableRef(snapshot: replaced, stableRef: originalRef)
    }
}

@Test("new lineages never recycle refs and reject refs from the prior lineage")
func newLineagesDoNotRecycleStableRefs() throws {
    let first = syntheticSnapshot(id: "first", windowID: 7, elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "First", stableKey: "root"),
        syntheticElement(index: 1, role: "AXButton", text: "Save", stableKey: "root/save"),
    ])
    let firstState = AXSnapshotDiff.applyStableRefs(snapshot: first, previous: nil)
    let staleRef = try #require(first.elements[1]?.stableRef)

    let second = syntheticSnapshot(id: "second", windowID: 8, elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Second", stableKey: "root"),
        syntheticElement(index: 1, role: "AXTextArea", text: nil, stableKey: "root/editor"),
    ])
    _ = AXSnapshotDiff.applyStableRefs(
        snapshot: second,
        previous: nil,
        minimumRefCounter: firstState.maxRefCounter
    )

    #expect(second.elements.values.allSatisfy { $0.stableRef != staleRef })
    let service = ComputerUseService()
    #expect(throws: ComputerUseError.self) {
        try service.lookupElementByStableRef(snapshot: second, stableRef: staleRef)
    }
}

@Test("subtree projection matches complete ref tokens")
func subtreeProjectionDoesNotConfuseA1WithA10() {
    let root = syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root")
    let old = syntheticElement(index: 1, role: "AXButton", text: "Old", stableKey: "root/old")
    let added = syntheticElement(index: 2, role: "AXButton", text: "Added", stableKey: "root/added")
    root.stableRef = "a9"
    old.stableRef = "a10"
    added.stableRef = "a1"
    let snapshot = syntheticSnapshot(id: "refs", elements: [root, old, added])

    let subtree = AXSnapshotDiff.projectSubtree(snapshot: snapshot, refs: ["a1"])

    #expect(subtree.contains("Added"))
    #expect(!subtree.contains("Old"))
}

@Test("snapshot preconditions reject stale IDs instead of refreshing and continuing")
func snapshotPreconditionsFailClosed() throws {
    let service = ComputerUseService()
    let current = syntheticSnapshot(id: "current", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
    ])
    service.snapshotsByApp["syntheticapp"] = current
    // Wall-clock age alone must not invalidate a version. The action refreshes
    // and compares live state before producing a side effect.
    service.snapshotTimestamps["syntheticapp"] = Date(timeIntervalSinceNow: -3600)

    try service.validateSnapshotPrecondition(
        for: "SyntheticApp",
        snapshotId: "current"
    )

    do {
        try service.validateSnapshotPrecondition(
            for: "SyntheticApp",
            snapshotId: "stale"
        )
        Issue.record("Expected a stale snapshot_id to fail closed")
    } catch {
        #expect(String(describing: error).contains("stale snapshot_id"))
    }

    let changed = syntheticSnapshot(id: "fresh", title: "Changed", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Changed", stableKey: "root"),
    ])
    #expect(throws: ComputerUseError.self) {
        try service.validateRefreshedSnapshot(changed, against: current, query: "SyntheticApp")
    }

    let movedToAnotherWindow = syntheticSnapshot(id: "other-window", windowID: 8, elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
    ])
    #expect(throws: ComputerUseError.self) {
        try service.validateRefreshedSnapshot(
            movedToAnotherWindow,
            against: current,
            query: "SyntheticApp"
        )
    }
}

@Test("snapshot results expose structured state metadata for coding batches")
func snapshotResultsExposeStructuredState() throws {
    let snapshot = syntheticSnapshot(id: "structured-snapshot", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
    ])
    let service = ComputerUseService()
    let result = service.snapshotResult(for: snapshot, style: .fullState)
    let structured = try #require(result.asDictionary["structuredContent"] as? [String: Any])
    let state = try #require(structured["state"] as? [String: Any])

    #expect(state["snapshot_id"] as? String == "structured-snapshot")
    #expect(state["app"] as? String == "SyntheticApp")
    #expect(state["window_id"] as? CGWindowID == 7)
}

@Test(
    "action results expose route and change metadata for coding batches",
    arguments: [true, false]
)
func actionResultsExposeStructuredMetadata(actionDiffEnabled: Bool) throws {
    let before = syntheticSnapshot(id: "before-action", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
    ])
    let after = syntheticSnapshot(id: "after-action", title: "Changed", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Changed", stableKey: "root"),
    ])
    let service = ComputerUseService(actionDiffEnabled: actionDiffEnabled)
    let action = ActionResultSummary(
        tool: "type_text",
        target: nil,
        route: "keyboard_post_to_pid",
        changeLevel: .confirmed,
        focusedBefore: "[3] AXTable",
        focusedAfter: "[18] AXTextArea",
        consecutiveNoChange: nil
    )
    let result = service.actionObservationResult(
        before: before,
        after: after,
        actionSummary: action.renderedLine,
        actionMetadata: action.structuredMetadata
    )
    let structured = try #require(result.asDictionary["structuredContent"] as? [String: Any])
    let actionPayload = try #require(structured["action"] as? [String: Any])

    #expect(actionPayload["tool"] as? String == "type_text")
    #expect(actionPayload["route"] as? String == "keyboard_post_to_pid")
    #expect(actionPayload["changed"] as? String == "confirmed")
}

@Test("verification failure overrides optimistic action metadata")
func verificationFailureOverridesActionMetadata() {
    let before = syntheticSnapshot(id: "before-warning", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Main", stableKey: "root"),
    ])
    let after = syntheticSnapshot(id: "after-warning", title: "Changed", elements: [
        syntheticElement(index: 0, role: "AXWindow", text: "Changed", stableKey: "root"),
    ])
    let preState = ActionPreState(pid: before.app.pid, fingerprint: 0, snapshot: before)
    let action = ActionResultSummary.make(
        tool: "type_text",
        route: "keyboard_post_to_pid",
        preState: preState,
        postSnapshot: after,
        changeLevelOverride: ChangeLevel.none
    )

    #expect(action.changeLevel == ChangeLevel.none)
    #expect(action.structuredMetadata["changed"] == "none")
}
