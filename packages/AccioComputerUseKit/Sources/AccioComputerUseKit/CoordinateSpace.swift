import CoreGraphics
import Foundation

/// Coordinate system used by a tool caller for x/y inputs.
///
/// Different LLMs emit coordinates in different spaces and the CLI cannot
/// otherwise tell them apart. Callers declare the space per call (or via
/// `ACCIO_COMPUTER_USE_COORDINATE_SPACE`) and the service converts to
/// screenshot-pixel coordinates before any window/global mapping.
public enum CoordinateSpace: String, Sendable {
    /// Raw pixels of the screenshot returned by the previous tool call. Default.
    case pixel
    /// Normalized [0, 1000] (Gemini convention).
    case normalized1000 = "normalized_1000"
    /// Normalized [0, 1].
    case normalized1 = "normalized_1"

    public init(rawCaseInsensitive raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            self = .pixel
            return
        }
        switch raw {
        case "pixel", "pixels", "px":
            self = .pixel
        case "normalized_1000", "normalized1000", "gemini", "0-1000":
            self = .normalized1000
        case "normalized_1", "normalized1", "normalized", "0-1":
            self = .normalized1
        default:
            self = .pixel
        }
    }

    public static func parseDeclared(_ raw: String) throws -> CoordinateSpace {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            throw ComputerUseError.invalidArguments("coordinate_space must be one of: pixel, normalized_1000, normalized_1.")
        }
        switch normalized {
        case "pixel", "pixels", "px":
            return .pixel
        case "normalized_1000", "normalized1000", "gemini", "0-1000":
            return .normalized1000
        case "normalized_1", "normalized1", "normalized", "0-1":
            return .normalized1
        default:
            throw ComputerUseError.invalidArguments("coordinate_space must be one of: pixel, normalized_1000, normalized_1.")
        }
    }

    /// Returns the session-wide default coordinate space sourced from the
    /// environment. Falls back to `.pixel` when unset or unrecognized.
    public static func sessionDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> CoordinateSpace {
        for name in ["ACCIO_COMPUTER_USE_COORDINATE_SPACE", "OPEN_COMPUTER_USE_COORDINATE_SPACE"] {
            if let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return CoordinateSpace(rawCaseInsensitive: raw)
            }
        }
        return .pixel
    }

    /// Convert a single coordinate value from this space to screenshot pixels.
    /// `pixelExtent` is the screenshot's pixel width (for x) or height (for y).
    public func toPixel(_ value: Double, pixelExtent: Double) -> Double {
        switch self {
        case .pixel:
            return value
        case .normalized1000:
            return value * pixelExtent / 1000.0
        case .normalized1:
            return value * pixelExtent
        }
    }

    /// Convert a CGPoint expressed in this space to a screenshot-pixel point.
    /// `pixelSize` must be the screenshot pixel size (PNG width/height).
    public func toPixelPoint(_ point: CGPoint, pixelSize: CGSize) -> CGPoint {
        CGPoint(
            x: toPixel(Double(point.x), pixelExtent: Double(pixelSize.width)),
            y: toPixel(Double(point.y), pixelExtent: Double(pixelSize.height))
        )
    }

    /// Short human-readable label for action summaries.
    public var summaryLabel: String {
        switch self {
        case .pixel: return "pixel"
        case .normalized1000: return "normalized_1000"
        case .normalized1: return "normalized_1"
        }
    }
}
