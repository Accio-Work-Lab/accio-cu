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
