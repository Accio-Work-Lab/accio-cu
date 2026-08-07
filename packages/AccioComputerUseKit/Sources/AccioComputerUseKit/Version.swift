import Foundation

public let accioComputerUseVersion = "0.0.1"
public let accioBuildRevisionKey = "AccioBuildRevision"

public func resolvedVersion(bundle: Bundle = .main) -> String {
    if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return version
    }
    return accioComputerUseVersion
}

public func resolvedVersionDescription(bundle: Bundle = .main) -> String {
    let version = resolvedVersion(bundle: bundle)
    guard let revision = bundle.object(forInfoDictionaryKey: accioBuildRevisionKey) as? String,
          !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return version
    }
    return "\(version) (\(revision))"
}
