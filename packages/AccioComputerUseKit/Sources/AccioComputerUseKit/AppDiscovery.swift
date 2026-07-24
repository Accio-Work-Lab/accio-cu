import AppKit
import CoreServices
import Foundation

public struct RunningAppDescriptor {
    public let name: String
    public let bundleIdentifier: String?
    public let pid: pid_t
    public let runningApplication: NSRunningApplication
}

struct ListedAppDescriptor {
    let name: String
    let bundleIdentifier: String
    let isRunning: Bool
    let isFrontmost: Bool
    let lastUsed: Date?
    let uses: Int?

    var renderedLine: String {
        var markers: [String] = []
        if isFrontmost { markers.append("frontmost") }
        if isRunning { markers.append("running") }
        if let lastUsed { markers.append("last-used=\(AppDiscovery.usageDateFormatter.string(from: lastUsed))") }
        if let uses { markers.append("uses=\(uses)") }
        return "\(name) — \(bundleIdentifier) [\(markers.joined(separator: ", "))]"
    }
}

private struct SpotlightAppRecord {
    let name: String
    let bundleIdentifier: String
    let lastUsed: Date?
    let uses: Int?
}

enum AppSafetyPolicy {
    private static let blockedBundleIdentifiers: Set<String> = [
        PermissionSupport.bundleIdentifier,
        "com.1password.1password", "com.1password.safari",
        "com.bitwarden.desktop", "com.lastpass.LastPass",
    ]

    static func isBlocked(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return blockedBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }

    static func permissionDenied(bundleIdentifier: String) -> ComputerUseError {
        if bundleIdentifier.caseInsensitiveCompare(PermissionSupport.bundleIdentifier) == .orderedSame {
            return .permissionDenied("Accio Computer Use is the automation host, not an automation target.")
        }
        return .permissionDenied("Computer Use is not allowed to use the app '\(bundleIdentifier)' for safety reasons.")
    }
}

enum AppDiscovery {
    private static let listAppsQuery = #"kMDItemContentType == "com.apple.application-bundle" && kMDItemFSName == "*.app""#
    private static let lastUsedDateRankingAttribute = "kMDItemLastUsedDate_Ranking"
    private static let useCountAttribute = "kMDItemUseCount"
    private static let maxRecentNonRunningApps = 10
    private static let standardApplicationSearchRoots: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
    ]

    static let usageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func listCatalog() -> [ListedAppDescriptor] {
        let running = userFacingRunningApps()
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
        let runningByBundle = running.reduce(into: [String: RunningAppDescriptor]()) { result, descriptor in
            guard let bundleIdentifier = descriptor.bundleIdentifier else { return }
            let key = bundleIdentifier.lowercased()
            if result[key] == nil { result[key] = descriptor }
        }

        var entriesByBundle: [String: ListedAppDescriptor] = [:]

        for record in spotlightRecentApps(cutoffDate: recentUsageCutoff()) {
            let key = record.bundleIdentifier.lowercased()
            guard !AppSafetyPolicy.isBlocked(bundleIdentifier: record.bundleIdentifier) else { continue }
            let runningDescriptor = runningByBundle[key]
            entriesByBundle[key] = ListedAppDescriptor(
                name: runningDescriptor?.name ?? record.name,
                bundleIdentifier: record.bundleIdentifier,
                isRunning: runningDescriptor != nil,
                isFrontmost: key == frontmostBundleIdentifier,
                lastUsed: record.lastUsed,
                uses: record.uses
            )
        }

        for descriptor in running {
            guard let bundleIdentifier = descriptor.bundleIdentifier else { continue }
            let key = bundleIdentifier.lowercased()
            let existing = entriesByBundle[key]
            entriesByBundle[key] = ListedAppDescriptor(
                name: descriptor.name,
                bundleIdentifier: bundleIdentifier,
                isRunning: true,
                isFrontmost: key == frontmostBundleIdentifier,
                lastUsed: existing?.lastUsed,
                uses: existing?.uses
            )
        }

        let sorted = entriesByBundle.values.sorted(by: compareListedApps)
        let runningEntries = sorted.filter(\.isRunning)
        let recentEntries = sorted.filter { !$0.isRunning }.prefix(maxRecentNonRunningApps)
        return runningEntries + Array(recentEntries)
    }

    static func runningApps() -> [RunningAppDescriptor] {
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
                return appName(lhs).localizedCaseInsensitiveCompare(appName(rhs)) == .orderedAscending
            }
            .map { app in
                RunningAppDescriptor(name: appName(app), bundleIdentifier: app.bundleIdentifier, pid: app.processIdentifier, runningApplication: app)
            }
    }

    static func resolve(_ query: String) throws -> RunningAppDescriptor {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let running = runningApps()
        let expectedBundleIdentifier = bundleIdentifier(forQuery: normalizedQuery)

        if isBundleIdentifierQuery(normalizedQuery), AppSafetyPolicy.isBlocked(bundleIdentifier: normalizedQuery) {
            throw AppSafetyPolicy.permissionDenied(bundleIdentifier: normalizedQuery)
        }

        if let expectedBundleIdentifier,
           let match = runningApplication(bundleIdentifier: expectedBundleIdentifier) {
            return match
        }

        if let match = resolvedRunningApp(in: running, matching: normalizedQuery) {
            return match
        }

        try launchIfPossible(normalizedQuery)

        for _ in 0..<20 {
            if let expectedBundleIdentifier,
               let launched = runningApplication(bundleIdentifier: expectedBundleIdentifier) {
                return launched
            }
            if let launched = resolvedRunningApp(in: runningApps(), matching: normalizedQuery) {
                return launched
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        throw ComputerUseError.appNotFound(normalizedQuery)
    }

    /// Returns a locally observed display name without launching an app.
    /// Activity UI must never display the untrusted query supplied by an agent.
    static func activityDisplayName(matching query: String) -> String? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return nil }
        return resolvedRunningApp(in: runningApps(), matching: normalizedQuery)?.name
    }

    private static func resolvedRunningApp(in descriptors: [RunningAppDescriptor], matching query: String) -> RunningAppDescriptor? {
        if isBundleIdentifierQuery(query) {
            return descriptors.first { $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame }
        }

        if let exact = descriptors.first(where: { descriptor in
            guard !AppSafetyPolicy.isBlocked(bundleIdentifier: descriptor.bundleIdentifier) else { return false }
            return descriptor.name.caseInsensitiveCompare(query) == .orderedSame
        }) {
            return exact
        }

        if let byProcess = descriptors.first(where: { descriptor in
            guard !AppSafetyPolicy.isBlocked(bundleIdentifier: descriptor.bundleIdentifier) else { return false }
            return descriptor.runningApplication.executableURL?.lastPathComponent
                .caseInsensitiveCompare(query) == .orderedSame
        }) {
            return byProcess
        }

        let bundleSuffix = "." + query.lowercased()
        if let byBundleSuffix = descriptors.first(where: { descriptor in
            guard !AppSafetyPolicy.isBlocked(bundleIdentifier: descriptor.bundleIdentifier) else { return false }
            guard let bid = descriptor.bundleIdentifier?.lowercased() else { return false }
            return bid.hasSuffix(bundleSuffix)
        }) {
            return byBundleSuffix
        }

        if let byContains = descriptors.first(where: { descriptor in
            guard !AppSafetyPolicy.isBlocked(bundleIdentifier: descriptor.bundleIdentifier) else { return false }
            return descriptor.name.localizedCaseInsensitiveContains(query)
        }) {
            return byContains
        }

        return nil
    }

    private static func runningApplication(bundleIdentifier: String) -> RunningAppDescriptor? {
        guard !AppSafetyPolicy.isBlocked(bundleIdentifier: bundleIdentifier) else { return nil }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
                return appName(lhs).localizedCaseInsensitiveCompare(appName(rhs)) == .orderedAscending
            }
            .first
            .map { app in
                RunningAppDescriptor(
                    name: appName(app),
                    bundleIdentifier: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    runningApplication: app
                )
            }
    }

    private static func userFacingRunningApps() -> [RunningAppDescriptor] {
        var seen: Set<String> = []
        return runningApps().filter { descriptor in
            guard descriptor.runningApplication.activationPolicy == .regular else { return false }
            guard let bid = descriptor.bundleIdentifier else { return false }
            guard !AppSafetyPolicy.isBlocked(bundleIdentifier: bid) else { return false }
            return seen.insert(bid.lowercased()).inserted
        }
    }

    private static func compareListedApps(_ lhs: ListedAppDescriptor, _ rhs: ListedAppDescriptor) -> Bool {
        if lhs.isFrontmost != rhs.isFrontmost { return lhs.isFrontmost }
        if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
        if let lhsLast = lhs.lastUsed, let rhsLast = rhs.lastUsed, lhsLast != rhsLast { return lhsLast > rhsLast }
        if let lhsUses = lhs.uses, let rhsUses = rhs.uses, lhsUses != rhsUses { return lhsUses > rhsUses }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func launchIfPossible(_ query: String) throws {
        if isBundleIdentifierQuery(query) {
            guard !AppSafetyPolicy.isBlocked(bundleIdentifier: query) else { return }
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: query) {
                try openApplication(at: appURL)
            }
            return
        }
        if let appURL = applicationURL(named: query) {
            if AppSafetyPolicy.isBlocked(bundleIdentifier: Bundle(url: appURL)?.bundleIdentifier) { return }
            try openApplication(at: appURL)
            return
        }
        // Filename search failed — try Spotlight display name lookup.
        // Apps like "iDingTalk.app" have localizedName "阿里钉" which differs from the filename.
        if let appURL = applicationURLByDisplayName(query) {
            if AppSafetyPolicy.isBlocked(bundleIdentifier: Bundle(url: appURL)?.bundleIdentifier) { return }
            try openApplication(at: appURL)
            return
        }
        let guessedBundleID = "com.apple.\(query)"
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: guessedBundleID) {
            if AppSafetyPolicy.isBlocked(bundleIdentifier: guessedBundleID) { return }
            try openApplication(at: appURL)
        }
    }

    private static func applicationURL(named query: String) -> URL? {
        let targetName = query.hasSuffix(".app") ? String(query.dropLast(4)) : query
        guard !targetName.isEmpty else { return nil }
        let fileManager = FileManager.default
        for root in standardApplicationSearchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isApplicationKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let candidateURL as URL in enumerator {
                guard candidateURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                let candidateName = candidateURL.lastPathComponent.hasSuffix(".app") ? String(candidateURL.lastPathComponent.dropLast(4)) : candidateURL.lastPathComponent
                if candidateName.caseInsensitiveCompare(targetName) == .orderedSame { return candidateURL }
            }
        }
        return nil
    }

    private static func bundleIdentifier(forQuery query: String) -> String? {
        if isBundleIdentifierQuery(query) {
            return query
        }

        if let appURL = applicationURL(named: query),
           let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier {
            return bundleIdentifier
        }

        if let appURL = applicationURLByDisplayName(query),
           let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier {
            return bundleIdentifier
        }

        return nil
    }

    /// Find an app by its localized display name via Spotlight.
    /// Handles apps like "iDingTalk.app" whose CFBundleDisplayName ("阿里钉") differs from filename.
    private static func applicationURLByDisplayName(_ query: String) -> URL? {
        let mdQuery = "kMDItemContentType == 'com.apple.application-bundle' && kMDItemDisplayName == '\(query)*'" as CFString
        guard let queryRef = MDQueryCreate(kCFAllocatorDefault, mdQuery, nil, nil) else { return nil }
        guard MDQueryExecute(queryRef, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }

        for index in 0..<MDQueryGetResultCount(queryRef) {
            guard let rawResult = MDQueryGetResultAtIndex(queryRef, index) else { continue }
            let item = unsafeBitCast(rawResult, to: MDItem.self)
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            // Verify display name matches (Spotlight wildcards may over-match)
            let bundle = Bundle(url: url)
            let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            if let displayName, displayName.caseInsensitiveCompare(query) == .orderedSame {
                return url
            }
            // Also match by kMDItemDisplayName (without .app suffix)
            if let mdDisplayName = MDItemCopyAttribute(item, kMDItemDisplayName) as? String {
                let cleanName = mdDisplayName.hasSuffix(".app") ? String(mdDisplayName.dropLast(4)) : mdDisplayName
                if cleanName.caseInsensitiveCompare(query) == .orderedSame {
                    return url
                }
            }
        }
        return nil
    }

    private static func openApplication(at appURL: URL) throws {
        // Use /usr/bin/open -g to launch without activating. NSWorkspace's
        // openApplication(configuration.activates = false) is unreliable —
        // many apps self-activate in applicationDidFinishLaunching, overriding
        // the flag. The -g flag is enforced at the launchd/WindowServer level
        // and reliably prevents foreground stealing.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", appURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ComputerUseError.message("Failed to open application at \(appURL.path) (exit code \(process.terminationStatus))")
        }
    }

    private static func recentUsageCutoff(referenceDate: Date = Date()) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let startOfToday = calendar.startOfDay(for: referenceDate)
        return calendar.date(byAdding: .day, value: -13, to: startOfToday) ?? startOfToday
    }

    private static func isBundleIdentifierQuery(_ query: String) -> Bool {
        query.contains(".")
    }

    static func appName(_ app: NSRunningApplication) -> String {
        app.localizedName
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? app.executableURL?.lastPathComponent
            ?? "pid-\(app.processIdentifier)"
    }

    private static func spotlightRecentApps(cutoffDate: Date) -> [SpotlightAppRecord] {
        let sortingAttributes = [
            lastUsedDateRankingAttribute as CFString,
            useCountAttribute as CFString,
        ] as CFArray

        guard let query = MDQueryCreate(kCFAllocatorDefault, listAppsQuery as CFString, nil, sortingAttributes) else { return [] }

        let scopes = ["/Applications", "/System/Applications", "/System/Library/CoreServices"] as [CFString]
        MDQuerySetSearchScope(query, scopes as CFArray, 0)
        MDQuerySetSortOptionFlagsForAttribute(query, lastUsedDateRankingAttribute as CFString, kMDQueryReverseSortOrderFlag.rawValue)

        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }

        var seen: Set<String> = []
        var records: [SpotlightAppRecord] = []

        for index in 0..<MDQueryGetResultCount(query) {
            guard let rawResult = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = unsafeBitCast(rawResult, to: MDItem.self)
            guard let bundleIdentifier = MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String, !bundleIdentifier.isEmpty else { continue }
            let key = bundleIdentifier.lowercased()
            guard seen.insert(key).inserted else { continue }
            guard !AppSafetyPolicy.isBlocked(bundleIdentifier: bundleIdentifier) else { continue }
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let appURL = URL(fileURLWithPath: path)
            let bundle = Bundle(url: appURL)
            if bundle?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true { continue }
            if bundle?.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true { continue }
            let lastUsed = MDItemCopyAttribute(item, lastUsedDateRankingAttribute as CFString) as? Date
                ?? MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            guard let lastUsed, lastUsed >= cutoffDate else { continue }
            let uses = (MDItemCopyAttribute(item, useCountAttribute as CFString) as? NSNumber)?.intValue
            let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (MDItemCopyAttribute(item, kMDItemDisplayName) as? String).map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
                ?? (appURL.lastPathComponent.hasSuffix(".app") ? String(appURL.lastPathComponent.dropLast(4)) : appURL.lastPathComponent)
            records.append(SpotlightAppRecord(name: displayName, bundleIdentifier: bundleIdentifier, lastUsed: lastUsed, uses: uses))
        }
        return records
    }
}
