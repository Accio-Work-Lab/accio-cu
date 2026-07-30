import Testing
@testable import AccioComputerUseKit

@Test("Dispatcher rejects non-finite screen click coordinates before executing")
func dispatcherRejectsNonFiniteClickCoordinates() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "click", arguments: [
        "x": Double.infinity,
        "y": 10.0,
    ])

    #expect(result.isError)
    #expect(result.primaryText == "x must be a finite number.")
}

@Test("Dispatcher rejects non-finite click counts before app resolution")
func dispatcherRejectsNonFiniteClickCount() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "click", arguments: [
        "app": "DefinitelyMissingAppForArgumentValidation",
        "element_index": "1",
        "click_count": Double.infinity,
    ])

    #expect(result.isError)
    #expect(result.primaryText == "click_count must be a finite number.")
}

@Test("Dispatcher rejects excessive click counts before app resolution")
func dispatcherRejectsExcessiveClickCount() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "click", arguments: [
        "app": "DefinitelyMissingAppForArgumentValidation",
        "element_index": "1",
        "click_count": 4,
    ])

    #expect(result.isError)
    #expect(result.primaryText == "click_count must be between 1 and 3.")
}

@Test("Dispatcher validates hover targets before resolving the app")
func dispatcherValidatesHoverTarget() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "hover", arguments: [
        "app": "DefinitelyMissingAppForArgumentValidation",
    ])

    #expect(result.isError)
    #expect(result.primaryText?.contains("hover requires") == true)
}

@Test("Dispatcher rejects non-positive scroll pages before action execution")
func dispatcherRejectsNonPositiveScrollPages() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "scroll", arguments: [
        "app": "DefinitelyMissingAppForArgumentValidation",
        "direction": "down",
        "pages": 0.0,
    ])

    #expect(result.isError)
    #expect(result.primaryText == "pages must be > 0.")
}

@Test("Dispatcher rejects excessive scroll pages before app resolution")
func dispatcherRejectsExcessiveScrollPages() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "scroll", arguments: [
        "app": "DefinitelyMissingAppForArgumentValidation",
        "direction": "down",
        "pages": 21.0,
    ])

    #expect(result.isError)
    #expect(result.primaryText == "pages must be <= 20.0.")
}

@Test("Dispatcher rejects invalid repeated key counts before app resolution")
func dispatcherRejectsInvalidRepeatedKeyCount() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "press_key", arguments: [
        "app": "DefinitelyMissingAppForArgumentValidation",
        "key": "Down",
        "count": 1.5,
    ])

    #expect(result.isError)
    #expect(result.primaryText == "count must be a positive integer.")
}

@Test("Dispatcher rejects zero repeated key count before app resolution")
func dispatcherRejectsZeroRepeatedKeyCount() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "press_key", arguments: [
        "app": "DefinitelyMissingAppForArgumentValidation",
        "key": "Down",
        "count": 0,
    ])

    #expect(result.isError)
    #expect(result.primaryText == "count must be a positive integer.")
}

@Test("Dispatcher rejects repeated key count above the maximum before app resolution")
func dispatcherRejectsExcessiveRepeatedKeyCount() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "press_key", arguments: [
        "app": "DefinitelyMissingAppForArgumentValidation",
        "key": "Down",
        "count": 101,
    ])

    #expect(result.isError)
    #expect(result.primaryText == "count must be <= 100.")
}

@Test("Dispatcher accepts omitted repeated key count and uses the default")
func dispatcherDefaultsOmittedRepeatedKeyCount() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "press_key", arguments: [
        "app": "DefinitelyMissingAppForArgumentValidation",
        "key": "Down",
    ])

    #expect(result.isError)
    #expect(result.primaryText?.hasPrefix("App 'DefinitelyMissingAppForArgumentValidation' not found.") == true)
}

@Test("Service rejects invalid repeated key counts before resolving the app", arguments: [
    (0, "count must be a positive integer."),
    (-1, "count must be a positive integer."),
    (101, "count must be <= 100."),
])
func serviceRejectsInvalidRepeatedKeyCount(count: Int, expectedMessage: String) {
    let service = ComputerUseService()

    do {
        _ = try service.pressKey(
            app: "DefinitelyMissingAppForArgumentValidation",
            key: "Down",
            count: count
        )
        Issue.record("Expected pressKey to reject count \(count)")
    } catch let error as ComputerUseError {
        #expect(error.errorDescription == expectedMessage)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test("Dispatcher rejects unknown declared coordinate spaces before executing")
func dispatcherRejectsUnknownCoordinateSpace() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "click", arguments: [
        "x": 10.0,
        "y": 20.0,
        "coordinate_space": "normalised_1000",
    ])

    #expect(result.isError)
    #expect(result.primaryText == "coordinate_space must be one of: pixel, normalized_1000, normalized_1.")
}

@Test("Dispatcher rejects non-finite drag coordinates before executing")
func dispatcherRejectsNonFiniteDragCoordinates() {
    let dispatcher = ComputerUseToolDispatcher()
    let result = dispatcher.callToolAsResult(name: "drag", arguments: [
        "from_x": 0.0,
        "from_y": Double.nan,
        "to_x": 100.0,
        "to_y": 100.0,
    ])

    #expect(result.isError)
    #expect(result.primaryText == "from_y must be a finite number.")
}
