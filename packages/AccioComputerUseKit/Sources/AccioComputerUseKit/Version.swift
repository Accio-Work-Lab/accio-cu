import Foundation

public let accioComputerUseVersion = "0.0.1"

public func resolvedVersion(bundle: Bundle = .main) -> String {
    if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return version
    }
    return accioComputerUseVersion
}
