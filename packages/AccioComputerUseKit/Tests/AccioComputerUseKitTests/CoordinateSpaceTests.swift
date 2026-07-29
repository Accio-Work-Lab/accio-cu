import CoreGraphics
import Testing
@testable import AccioComputerUseKit

@Test("Pixel space is the identity")
func pixelSpaceIsIdentity() {
    let space = CoordinateSpace.pixel
    let point = space.toPixelPoint(CGPoint(x: 123, y: 456), pixelSize: CGSize(width: 2000, height: 1000))
    #expect(point == CGPoint(x: 123, y: 456))
}

@Test("normalized_1000 maps 0-1000 to full pixel extent")
func normalized1000MapsToPixels() {
    let space = CoordinateSpace.normalized1000
    let size = CGSize(width: 3024, height: 1964)

    let topLeft = space.toPixelPoint(CGPoint(x: 0, y: 0), pixelSize: size)
    #expect(topLeft == CGPoint(x: 0, y: 0))

    let center = space.toPixelPoint(CGPoint(x: 500, y: 500), pixelSize: size)
    #expect(abs(center.x - 1512) < 0.001)
    #expect(abs(center.y - 982) < 0.001)

    let bottomRight = space.toPixelPoint(CGPoint(x: 1000, y: 1000), pixelSize: size)
    #expect(abs(bottomRight.x - 3024) < 0.001)
    #expect(abs(bottomRight.y - 1964) < 0.001)
}

@Test("normalized_1 maps 0-1 to full pixel extent")
func normalized1MapsToPixels() {
    let space = CoordinateSpace.normalized1
    let size = CGSize(width: 1280, height: 800)
    let point = space.toPixelPoint(CGPoint(x: 0.25, y: 0.5), pixelSize: size)
    #expect(point.x == 320)
    #expect(point.y == 400)
}

@Test("Parser accepts known aliases case-insensitively", arguments: [
    ("pixel", CoordinateSpace.pixel),
    ("PIXELS", CoordinateSpace.pixel),
    ("px", CoordinateSpace.pixel),
    ("normalized_1000", CoordinateSpace.normalized1000),
    ("normalized1000", CoordinateSpace.normalized1000),
    ("Gemini", CoordinateSpace.normalized1000),
    ("0-1000", CoordinateSpace.normalized1000),
    ("normalized_1", CoordinateSpace.normalized1),
    ("normalized", CoordinateSpace.normalized1),
    ("0-1", CoordinateSpace.normalized1),
])
func parserAcceptsAliases(raw: String, expected: CoordinateSpace) {
    #expect(CoordinateSpace(rawCaseInsensitive: raw) == expected)
}

@Test("Parser falls back to pixel for nil/empty/unknown")
func parserFallsBackToPixel() {
    #expect(CoordinateSpace(rawCaseInsensitive: nil) == .pixel)
    #expect(CoordinateSpace(rawCaseInsensitive: "") == .pixel)
    #expect(CoordinateSpace(rawCaseInsensitive: "    ") == .pixel)
    #expect(CoordinateSpace(rawCaseInsensitive: "not-a-space") == .pixel)
}

@Test("Declared parser rejects unknown coordinate space")
func declaredParserRejectsUnknownCoordinateSpace() {
    do {
        _ = try CoordinateSpace.parseDeclared("not-a-space")
        Issue.record("Expected parseDeclared to reject an unknown coordinate space")
    } catch let error as ComputerUseError {
        #expect(error.errorDescription == "coordinate_space must be one of: pixel, normalized_1000, normalized_1.")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test("Session default reads env var, falls back to pixel")
func sessionDefaultReadsEnv() {
    #expect(CoordinateSpace.sessionDefault(environment: [:]) == .pixel)
    #expect(CoordinateSpace.sessionDefault(environment: ["ACCIO_COMPUTER_USE_COORDINATE_SPACE": "normalized_1000"]) == .normalized1000)
    #expect(CoordinateSpace.sessionDefault(environment: ["OPEN_COMPUTER_USE_COORDINATE_SPACE": "normalized_1"]) == .normalized1)
    #expect(CoordinateSpace.sessionDefault(environment: ["ACCIO_COMPUTER_USE_COORDINATE_SPACE": "garbage"]) == .pixel)
}

@Test("Display selection uses screen-state coordinates and the largest overlap")
func displaySelectionUsesLargestScreenStateOverlap() {
    let main = VisualCursorScreenMapping(
        screenStateFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        backingScaleFactor: 2
    )
    let secondary = VisualCursorScreenMapping(
        screenStateFrame: CGRect(x: -216, y: -1080, width: 1920, height: 1080),
        appKitFrame: CGRect(x: -216, y: 982, width: 1920, height: 1080),
        backingScaleFactor: 1
    )

    let selected = screenMapping(
        withLargestIntersection: CGRect(x: -216, y: -1050, width: 1920, height: 1050),
        mappings: [main, secondary]
    )

    #expect(selected == secondary)
}

@Test("Validated window mapping supports negative secondary-display coordinates")
func validatedWindowMappingSupportsSecondaryDisplay() {
    let secondary = VisualCursorScreenMapping(
        screenStateFrame: CGRect(x: -216, y: -1080, width: 1920, height: 1080),
        appKitFrame: CGRect(x: -216, y: 982, width: 1920, height: 1080),
        backingScaleFactor: 1
    )
    let windowBounds = CGRect(x: -216, y: -1050, width: 1920, height: 1050)

    let point = validatedScreenStateGlobalPoint(
        windowPoint: CGPoint(x: 912, y: 622),
        windowBounds: windowBounds,
        mappings: [secondary]
    )

    #expect(point == CGPoint(x: 696, y: -428))
}

@Test("Validated window mapping rejects points outside the window or displays")
func validatedWindowMappingRejectsInvalidTargets() {
    let main = VisualCursorScreenMapping(
        screenStateFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        backingScaleFactor: 2
    )
    let windowBounds = CGRect(x: 100, y: 100, width: 800, height: 600)

    #expect(validatedScreenStateGlobalPoint(
        windowPoint: CGPoint(x: 801, y: 200),
        windowBounds: windowBounds,
        mappings: [main]
    ) == nil)
    #expect(validatedScreenStateGlobalPoint(
        windowPoint: CGPoint(x: 800, y: 600),
        windowBounds: windowBounds,
        mappings: [main]
    ) == nil)
    #expect(validatedScreenStateGlobalPoint(
        windowPoint: CGPoint(x: 200, y: 200),
        windowBounds: CGRect(x: 2000, y: 0, width: 800, height: 600),
        mappings: [main]
    ) == nil)
}
