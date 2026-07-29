import Testing
@testable import AccioComputerUseKit

@Test("public release version is 0.0.1")
func publicReleaseVersionIsExpected() {
    #expect(accioComputerUseVersion == "0.0.1")
}

@Test("desktop action annotations request conservative host approval")
func desktopActionAnnotationsAreConservative() throws {
    let actions = [
        "click", "hover", "drag", "perform_secondary_action", "press_key",
        "scroll", "set_value", "type_text", "menu_select",
    ]

    for name in actions {
        let tool = try #require(ToolDefinitions.all.first { $0.name == name })
        #expect(tool.annotations["destructiveHint"] as? Bool == true)
        #expect(tool.annotations["openWorldHint"] as? Bool == true)
        #expect(tool.annotations["readOnlyHint"] as? Bool == false)
    }
}

@Test("observations that may launch or poll an app are not marked read-only")
func appObservationAnnotationsAreConservative() throws {
    for name in ["get_app_state", "wait_for_element"] {
        let tool = try #require(ToolDefinitions.all.first { $0.name == name })
        #expect(tool.annotations["readOnlyHint"] as? Bool == false)
        #expect(tool.annotations["destructiveHint"] as? Bool == false)
    }
}

@Test("pure state listing and screen capture remain read-only")
func pureObservationAnnotationsRemainReadOnly() throws {
    for name in ["get_screen_state", "list_apps"] {
        let tool = try #require(ToolDefinitions.all.first { $0.name == name })
        #expect(tool.annotations["readOnlyHint"] as? Bool == true)
        #expect(tool.annotations["destructiveHint"] as? Bool == false)
    }
}
