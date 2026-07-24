import ApplicationServices
import Foundation

struct AXStableRefInfo {
    let ref: String
    let stableKey: String
    let index: Int
    let role: String?
    let displayText: String?
    let actions: [String]
    let element: AXUIElement?
}

struct AXDiffState {
    let bucketKey: String
    let snapshotID: String
    let windowTitle: String?
    let elementCount: Int
    let treeText: String
    let refsByStableKey: [String: AXStableRefInfo]
    let maxRefCounter: Int
}

struct AXSnapshotDiffResult {
    let shouldUseDiff: Bool
    let text: String?
    let reason: String
}

enum AXSnapshotDiff {
    static let maxElementDriftRatio = 0.5
    static let minJaccard = 0.5
    static let maxNewRefRatio = 0.5
    static let maxChangeRatio = 0.6
    static let maxDiffToFullRatio = 0.85

    static func bucketKey(for snapshot: AppSnapshot) -> String {
        let appID = snapshot.app.bundleIdentifier ?? snapshot.app.name
        let windowID = snapshot.targetWindowID.map(String.init) ?? "no-window"
        // A document title is mutable state, not window identity. Apps commonly
        // append markers such as "Edited" without replacing the actual window.
        return "\(appID)::pid=\(snapshot.app.pid)::window=\(windowID)"
    }

    static func applyStableRefs(
        snapshot: AppSnapshot,
        previous: AXDiffState?,
        minimumRefCounter: Int = 0
    ) -> AXDiffState {
        let previousByKey = previous?.refsByStableKey ?? [:]
        let previousInfos = Array(previousByKey.values)
        var refsByStableKey: [String: AXStableRefInfo] = [:]
        var usedRefs = Set<String>()
        var nextCounter = max(previous?.maxRefCounter ?? 0, minimumRefCounter)

        for index in snapshot.elements.keys.sorted() {
            guard let record = snapshot.elements[index] else { continue }
            let rawStableKey = record.stableKey.isEmpty ? fallbackStableKey(for: record) : record.stableKey
            let stableKey = canonicalStableKey(rawStableKey)
            var ref: String
            let priorByIdentity = record.element.flatMap { currentElement in
                previousInfos.first { prior in
                    guard let previousElement = prior.element else { return false }
                    return CFEqual(previousElement, currentElement)
                }
            }
            let priorByKey = previousByKey[stableKey]
            // Synthetic/no-AX records use the semantic key fallback. For real
            // AX records, an element recreated at the same path is a new
            // identity and must not inherit a retired ref.
            let prior = priorByIdentity ?? (
                record.element == nil || priorByKey?.element == nil ? priorByKey : nil
            )
            if let prior, !usedRefs.contains(prior.ref) {
                ref = prior.ref
            } else {
                repeat {
                    nextCounter += 1
                    ref = "a\(nextCounter)"
                } while usedRefs.contains(ref)
            }
            usedRefs.insert(ref)
            record.stableRef = ref
            record.stableKey = stableKey
            refsByStableKey[stableKey] = AXStableRefInfo(
                ref: ref,
                stableKey: stableKey,
                index: index,
                role: record.role,
                displayText: record.displayText,
                actions: record.rawActions,
                element: record.element
            )
        }

        return AXDiffState(
            bucketKey: bucketKey(for: snapshot),
            snapshotID: snapshot.snapshotID,
            windowTitle: snapshot.windowTitle,
            elementCount: snapshot.elementCount,
            treeText: normalizedTreeText(snapshot),
            refsByStableKey: refsByStableKey,
            maxRefCounter: nextCounter
        )
    }

    static func makeDiff(
        before: AppSnapshot,
        after: AppSnapshot,
        actionSummary: String,
        fullText: String
    ) -> AXSnapshotDiffResult {
        if actionSummary.contains("changed=none") {
            return .init(shouldUseDiff: false, text: nil, reason: "change_none")
        }
        if actionSummary.contains("changed=unverifiable") {
            return .init(shouldUseDiff: false, text: nil, reason: "change_unverifiable")
        }
        if before.elementCount == 0 || after.elementCount == 0 {
            return .init(shouldUseDiff: false, text: nil, reason: "empty_tree")
        }
        if stableRefMap(snapshot: before).isEmpty || stableRefMap(snapshot: after).isEmpty {
            return .init(shouldUseDiff: false, text: nil, reason: "no_previous_refs")
        }
        if bucketKey(for: before) != bucketKey(for: after) {
            return .init(shouldUseDiff: false, text: nil, reason: "bucket_changed")
        }
        if containsTransientMenu(before) || containsTransientMenu(after) {
            return .init(shouldUseDiff: false, text: nil, reason: "transient_menu")
        }

        let driftDenom = max(before.elementCount, after.elementCount)
        if driftDenom > 0 {
            let drift = Double(abs(before.elementCount - after.elementCount)) / Double(driftDenom)
            if drift > maxElementDriftRatio {
                return .init(shouldUseDiff: false, text: nil, reason: "element_drift")
            }
        }

        let similarity = jaccard(before: normalizedTreeText(before), after: normalizedTreeText(after))
        if similarity < minJaccard {
            return .init(shouldUseDiff: false, text: nil, reason: "low_similarity")
        }

        let partition = partitionRefs(before: before, after: after)
        let changed = changedRefs(before: before, after: after)
        let currentCount = after.elements.count
        if currentCount > 0 && Double(partition.new.count) / Double(currentCount) > maxNewRefRatio {
            return .init(shouldUseDiff: false, text: nil, reason: "too_many_new_refs")
        }

        let unionCount = partition.kept.count + partition.new.count + partition.removed.count
        if unionCount > 0 {
            let changeRatio = Double(partition.new.count + partition.removed.count + changed.count) / Double(unionCount)
            if changeRatio > maxChangeRatio {
                return .init(shouldUseDiff: false, text: nil, reason: "too_many_changes")
            }
        }

        let diffText = formatDiff(snapshot: after, partition: partition, changed: changed)
        if Double(diffText.count) >= Double(fullText.count) * maxDiffToFullRatio {
            return .init(shouldUseDiff: false, text: nil, reason: "not_worth_it")
        }

        return .init(shouldUseDiff: true, text: diffText, reason: "eligible")
    }

    static func partitionRefs(
        before: AppSnapshot,
        after: AppSnapshot
    ) -> (kept: [String], new: [String], removed: [String]) {
        let beforeRefs = Set(stableRefMap(snapshot: before).keys)
        let afterRefs = Set(stableRefMap(snapshot: after).keys)
        let kept = beforeRefs.intersection(afterRefs)
        let new = afterRefs.subtracting(beforeRefs)
        let removed = beforeRefs.subtracting(afterRefs)

        return (sortRefs(Array(kept)), sortRefs(Array(new)), sortRefs(Array(removed)))
    }

    static func changedRefs(before: AppSnapshot, after: AppSnapshot) -> [String] {
        let beforeLines = semanticLinesByRef(snapshot: before)
        let afterLines = semanticLinesByRef(snapshot: after)
        let shared = Set(beforeLines.keys).intersection(afterLines.keys)
        return sortRefs(shared.filter { beforeLines[$0] != afterLines[$0] })
    }

    static func stableRefMap(snapshot: AppSnapshot) -> [String: ElementRecord] {
        var out: [String: ElementRecord] = [:]
        for record in snapshot.elements.values {
            if let ref = record.stableRef, !ref.isEmpty {
                out[ref] = record
            }
        }
        return out
    }

    static func insertStableRef(into line: String, ref: String?) -> String {
        guard let ref, !ref.isEmpty, !line.contains(" ref=") else { return line }
        if let range = line.range(of: " actions=[") {
            return String(line[..<range.lowerBound]) + " ref=\(ref)" + String(line[range.lowerBound...])
        }
        return line + " ref=\(ref)"
    }

    static func lineIndex(in line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "[" else { return nil }
        guard let end = trimmed.firstIndex(of: "]") else { return nil }
        return Int(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
    }

    static func compactRefRanges(_ refs: [String]) -> String {
        let numbers = sortRefs(refs).compactMap { ref -> Int? in
            guard ref.first == "a" else { return nil }
            return Int(ref.dropFirst())
        }
        if numbers.isEmpty { return "-" }
        var parts: [String] = []
        var start = numbers[0]
        var end = numbers[0]
        for number in numbers.dropFirst() {
            if number == end + 1 {
                end = number
            } else {
                parts.append(start == end ? "a\(start)" : "a\(start)-a\(end)")
                start = number
                end = number
            }
        }
        parts.append(start == end ? "a\(start)" : "a\(start)-a\(end)")
        return parts.joined(separator: ", ")
    }

    private static func fallbackStableKey(for record: ElementRecord) -> String {
        let role = record.role ?? "AXUnknown"
        let text = normalize(record.displayText ?? record.identifier ?? "")
        let actions = record.rawActions.sorted().joined(separator: ",")
        return "fallback|\(role)|\(text)|\(actions)|\(record.index)"
    }

    /// Window titles are deliberately excluded from the stable identity path.
    /// The tree walker includes the root AXWindow title in every descendant's
    /// path, which would otherwise invalidate all refs for ordinary title-only
    /// changes such as a document becoming edited.
    private static func canonicalStableKey(_ key: String) -> String {
        guard key.hasPrefix("text|AXWindow|") else { return key }

        let rootEnd = key.firstIndex(of: "/") ?? key.endIndex
        let root = String(key[..<rootEnd])
        let parts = root.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 5 else { return key }

        let actionKey = parts[parts.count - 2]
        let ordinal = parts[parts.count - 1]
        let canonicalRoot = "text|AXWindow|<window>|\(actionKey)|\(ordinal)"
        return canonicalRoot + String(key[rootEnd...])
    }

    private static func normalizedTreeText(_ snapshot: AppSnapshot) -> String {
        snapshot.elements.keys.sorted().compactMap { index -> String? in
            guard let record = snapshot.elements[index] else { return nil }
            return [
                record.stableKey,
                record.role ?? "",
                normalize(record.displayText ?? ""),
                record.rawActions.sorted().joined(separator: ","),
            ].joined(separator: "|")
        }.joined(separator: "\n")
    }

    private static func containsTransientMenu(_ snapshot: AppSnapshot) -> Bool {
        snapshot.elements.values.contains { record in
            let role = record.role ?? ""
            return role == kAXMenuRole as String || role == kAXMenuItemRole as String
        }
    }

    private static func jaccard(before: String, after: String) -> Double {
        let a = trigrams(before)
        let b = trigrams(after)
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 1 : Double(intersection) / Double(union)
    }

    private static func trigrams(_ text: String) -> Set<String> {
        if text.count < 3 { return text.isEmpty ? [] : [text] }
        let chars = Array(text)
        var out = Set<String>()
        for i in 0...(chars.count - 3) {
            out.insert(String(chars[i..<(i + 3)]))
        }
        return out
    }

    private static func formatDiff(
        snapshot: AppSnapshot,
        partition: (kept: [String], new: [String], removed: [String]),
        changed: [String]
    ) -> String {
        var lines: [String] = []
        lines.append("AXDIFF v1 snapshot=\(snapshot.snapshotID) elements=\(snapshot.elementCount)")
        lines.append("kept_refs (\(partition.kept.count)): \(compactRefRanges(partition.kept))")
        if !partition.removed.isEmpty {
            lines.append("removed_refs (\(partition.removed.count)): \(compactRefRanges(partition.removed))")
        }
        if !partition.new.isEmpty {
            lines.append("new_refs (\(partition.new.count)): \(compactRefRanges(partition.new))")
            lines.append("new_subtree:")
            let subtree = projectSubtree(snapshot: snapshot, refs: Set(partition.new))
            lines.append(subtree.isEmpty ? "(empty)" : subtree)
        }
        if !changed.isEmpty {
            lines.append("changed_refs (\(changed.count)): \(compactRefRanges(changed))")
            lines.append("changed_subtree:")
            let subtree = projectSubtree(snapshot: snapshot, refs: Set(changed))
            lines.append(subtree.isEmpty ? "(empty)" : subtree)
        }
        return lines.joined(separator: "\n")
    }

    static func projectSubtree(snapshot: AppSnapshot, refs: Set<String>) -> String {
        let renderedLines = snapshot.treeLinesWithStableRefs()
        var include = Set<Int>()
        for (idx, line) in renderedLines.enumerated() {
            guard let lineRef = refToken(in: line), refs.contains(lineRef) else { continue }
            include.insert(idx)
            let depth = indentDepth(line)
            var parentDepth = depth - 1
            var cursor = idx - 1
            while cursor >= 0 && parentDepth >= 0 {
                let candidateDepth = indentDepth(renderedLines[cursor])
                if candidateDepth == parentDepth {
                    include.insert(cursor)
                    parentDepth -= 1
                }
                cursor -= 1
            }
        }
        return include.sorted().map { renderedLines[$0] }.joined(separator: "\n")
    }

    private static func semanticLinesByRef(snapshot: AppSnapshot) -> [String: String] {
        var result: [String: String] = [:]
        for line in snapshot.treeLinesWithStableRefs() {
            guard let ref = refToken(in: line), let closeBracket = line.firstIndex(of: "]") else {
                continue
            }
            var semantic = String(line[line.index(after: closeBracket)...])
                .trimmingCharacters(in: .whitespaces)
            semantic = semantic.replacingOccurrences(
                of: #"\sref=[^\s]+"#,
                with: "",
                options: .regularExpression
            )
            result[ref] = semantic
        }
        return result
    }

    private static func refToken(in line: String) -> String? {
        line.split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.hasPrefix("ref=") })
            .map { String($0.dropFirst(4)) }
    }

    private static func indentDepth(_ line: String) -> Int {
        let trimmed = line.drop(while: { $0 == " " })
        return (line.count - trimmed.count) / 2
    }

    private static func sortRefs(_ refs: [String]) -> [String] {
        refs.sorted { lhs, rhs in
            let li = Int(lhs.dropFirst()) ?? 0
            let ri = Int(rhs.dropFirst()) ?? 0
            return li == ri ? lhs < rhs : li < ri
        }
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
