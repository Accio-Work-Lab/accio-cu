import inspect
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from typing import Optional, get_type_hints
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from accio_cu_code import helpers
from accio_cu_code.transport import DaemonTransport


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER_API_REFERENCE = (
    REPO_ROOT / "Skills" / "accio-computer-use" / "references" / "helper-api.md"
)
SKILL_ROOT = REPO_ROOT / "Skills" / "accio-computer-use"
INTERACTION_SKILL_HELPERS = {
    "observation-and-targeting.md": (
        "list_apps",
        "get_screen_state",
        "get_app_state",
    ),
    "clicking-and-coordinates.md": ("click", "double_click", "hover"),
    "text-and-keyboard.md": ("type_text", "set_value", "press_key"),
    "scrolling-and-dragging.md": ("scroll", "drag"),
    "menus-and-secondary-actions.md": (
        "menu_select",
        "perform_secondary_action",
    ),
    "waiting-and-verification.md": ("wait_for_element",),
}


EXPECTED_SIGNATURES = {
    "list_apps": "()",
    "get_screen_state": "()",
    "get_app_state": "(*, app)",
    "click": (
        "(*, app=None, stable_ref=None, element_index: Optional[str] = None, element_text=None, "
        "snapshot_id=None, x=None, y=None, coordinate_space=None, "
        "click_count=1, mouse_button='left')"
    ),
    "double_click": (
        "(*, app=None, stable_ref=None, element_index: Optional[str] = None, element_text=None, "
        "snapshot_id=None, x=None, y=None, coordinate_space=None, "
        "mouse_button='left')"
    ),
    "hover": (
        "(*, app, stable_ref=None, element_index: Optional[str] = None, element_text=None, "
        "snapshot_id=None, x=None, y=None, coordinate_space=None)"
    ),
    "drag": ("(*, from_x, from_y, to_x, to_y, app=None, coordinate_space=None)"),
    "perform_secondary_action": (
        "(*, app, action, stable_ref=None, element_index: Optional[str] = None, "
        "element_text=None, snapshot_id=None)"
    ),
    "press_key": "(*, app, key)",
    "scroll": (
        "(*, app, direction, stable_ref=None, element_index: Optional[str] = None, "
        "element_text=None, snapshot_id=None, pages=1)"
    ),
    "set_value": (
        "(*, app, value, stable_ref=None, element_index: Optional[str] = None, "
        "element_text=None, snapshot_id=None)"
    ),
    "type_text": (
        "(*, app, text, stable_ref=None, element_index: Optional[str] = None, "
        "element_text=None, snapshot_id=None)"
    ),
    "wait_for_element": (
        "(*, app, element_text=None, wait_mode='element_text', timeout_seconds=10, "
        "poll_interval=0.5)"
    ),
    "menu_select": "(*, app, path)",
}


class HelperTests(unittest.TestCase):
    def test_helper_api_reference_signatures_match_python_functions(self):
        text = HELPER_API_REFERENCE.read_text()
        documented = dict(
            re.findall(r"^Signature: `([a-z_]+)(\(.*\))`$", text, re.MULTILINE)
        )

        self.assertEqual(documented, EXPECTED_SIGNATURES)

    def test_public_helpers_have_code_defined_signatures_and_docstrings(self):
        exported = helpers.configure(lambda name, arguments: None, [])

        self.assertEqual(set(exported), set(EXPECTED_SIGNATURES))
        for name, expected in EXPECTED_SIGNATURES.items():
            function = exported[name]
            self.assertEqual(str(inspect.signature(function)), expected)
            self.assertTrue(inspect.getdoc(function))

    def test_element_indices_are_typed_as_optional_strings(self):
        exported = helpers.configure(lambda name, arguments: None, [])

        for name in (
            "click",
            "double_click",
            "hover",
            "perform_secondary_action",
            "scroll",
            "set_value",
            "type_text",
        ):
            self.assertEqual(
                get_type_hints(exported[name])["element_index"],
                Optional[str],
                name,
            )

    def test_interaction_skills_keep_local_signatures_in_sync(self):
        for filename, helper_names in INTERACTION_SKILL_HELPERS.items():
            text = (SKILL_ROOT / "interaction-skills" / filename).read_text()
            self.assertIn("## Parameter semantics", text, filename)
            normalized = re.sub(r"\s+", " ", text).replace('"', "'")
            for name in helper_names:
                expected = f"{name}{EXPECTED_SIGNATURES[name]}"
                self.assertIn(expected, normalized, f"{filename}: {name}")

    def test_main_skill_requires_runtime_discovery_before_guessing(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()

        self.assertIn("inspect.signature(function)", text)
        self.assertIn("inspect.getdoc(function)", text)
        self.assertIn(
            "Each `accio-computer-use` coding block starts a new Python process",
            text,
        )

    def test_start_here_uses_automatic_post_action_screenshot(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()

        self.assertNotIn('verified = get_app_state(app="Safari")', text)
        self.assertNotIn('"screenshots": final.screenshot_paths', text)
        self.assertIn("execution_feedback.latest_observation", text)

    def test_routine_mutation_does_not_require_visual_inspection(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()

        self.assertIn("Inspect the compact feedback first", text)
        self.assertIn("Do not open its screenshot by default", text)
        self.assertIn("Only inspect the screenshot when", text)

    def test_skill_treats_state_and_screenshot_as_independent_evidence(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()
        normalized = " ".join(text.split())

        self.assertIn("state and screenshot are independent evidence", normalized)
        self.assertIn("state_source_call_index", normalized)
        self.assertIn("screenshot_source_call_index", normalized)
        self.assertIn("do not assume that screenshot depicts that state", normalized)

    def test_main_skill_uses_general_evidence_sufficiency_policy(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()

        self.assertIn("## Evidence sufficiency", text)
        self.assertIn("unresolved goal predicate", text)
        self.assertIn("fresh result resolves that predicate", text)
        self.assertIn("adds no new evidence", text)
        self.assertIn("one observation that can resolve the missing fact", text)
        self.assertNotIn("beginning a new phase or app", text)

    def test_verification_uses_only_declared_independent_routes(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()
        normalized = " ".join(text.split())

        self.assertIn("declares it available", normalized)
        self.assertIn("semantically independent evidence", normalized)
        self.assertIn("Do not invent an integration", normalized)
        self.assertNotIn("such as application-native scripting", text)

    def test_visual_completion_check_is_not_required_after_every_stage(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()

        self.assertIn("At task completion", text)
        self.assertIn("freshest matching screenshot", text)
        self.assertNotIn("Every completed stage and completed task", text)

    def test_action_handoff_example_does_not_dump_full_result_text(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()
        handoff = text.split("## Use the observation returned by each action", 1)[
            1
        ].split("## Load interaction skills on demand", 1)[0]

        self.assertNotIn("print(result.text)", handoff)
        self.assertIn("result.text.splitlines()", handoff)

    def test_observation_skill_emits_images_instead_of_printing_paths(self):
        text = (
            SKILL_ROOT / "interaction-skills" / "observation-and-targeting.md"
        ).read_text()

        self.assertIn('emit({"screenshots": state.screenshot_paths})', text)
        self.assertIn('emit({"screenshots": screen.screenshot_paths})', text)
        self.assertNotIn("print(state.screenshot_paths)", text)
        self.assertNotIn("print(screen.screenshot_paths)", text)

    def test_main_skill_requires_initial_observation_handoff_before_side_effects(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()

        self.assertIn("Before the first side effect of every task", text)
        self.assertIn("observation-only block", text)
        self.assertIn("Only after the model has read that returned state", text)
        self.assertIn("This gate applies to every execution route", text)
        self.assertIn("If the observation does not establish the target and scope", text)

    def test_main_skill_requires_host_image_read_for_visual_verification(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()
        normalized = " ".join(text.split())

        self.assertIn(
            "In CLI mode require an actual host image-reading",
            normalized,
        )
        self.assertIn(
            "Receiving a path is not visual verification",
            normalized,
        )
        self.assertIn("attached image content reaches the model", normalized)

    def test_start_here_separates_initial_observation_from_actions(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()
        start_here = text.split("## Start here", 1)[1].split(
            "## Discover the API from Python", 1
        )[0]
        blocks = re.findall(r"```bash\n(.*?)```", start_here, re.DOTALL)

        self.assertGreaterEqual(len(blocks), 2)
        observation_block, action_block = blocks[:2]
        self.assertIn('state = get_app_state(app="Safari")', observation_block)
        self.assertIn("print(state.text)", observation_block)
        self.assertIn('"screenshots": state.screenshot_paths', observation_block)
        self.assertNotIn("click(", observation_block)
        self.assertNotIn("type_text(", observation_block)
        self.assertNotIn("press_key(", observation_block)
        self.assertIn("click(", action_block)

    def test_start_here_makes_final_host_image_read_a_completion_gate(self):
        text = (SKILL_ROOT / "SKILL.md").read_text()
        start_here = text.split("## Start here", 1)[1].split(
            "## Initial observation gate", 1
        )[0]

        self.assertIn("Before reporting completion", start_here)
        self.assertIn("required image content", start_here)

    def test_optional_none_is_omitted_but_falsey_values_are_forwarded(self):
        calls = []
        tools = [
            tool_definition(
                "click",
                [
                    "app",
                    "stable_ref",
                    "element_index",
                    "element_text",
                    "snapshot_id",
                    "x",
                    "y",
                    "coordinate_space",
                    "click_count",
                    "mouse_button",
                ],
            )
        ]
        helpers.configure(
            lambda name, arguments: calls.append((name, arguments)), tools
        )

        helpers.click(app="Safari", x=0, click_count=0, element_text="")
        helpers.double_click(app="Safari", y=0)

        self.assertEqual(
            calls[0],
            (
                "click",
                {
                    "app": "Safari",
                    "element_text": "",
                    "x": 0,
                    "click_count": 0,
                    "mouse_button": "left",
                },
            ),
        )
        self.assertEqual(
            calls[1],
            (
                "click",
                {
                    "app": "Safari",
                    "y": 0,
                    "click_count": 2,
                    "mouse_button": "left",
                },
            ),
        )

    def test_known_schema_drift_fails_before_model_code(self):
        mismatched = [
            tool_definition("get_app_state", ["application"], ["application"])
        ]

        with self.assertRaisesRegex(
            helpers.HelperContractError, "parameters do not match"
        ):
            helpers.configure(lambda name, arguments: None, mismatched)

    def test_runtime_contract_requires_every_code_defined_native_helper(self):
        with self.assertRaisesRegex(
            helpers.IncompatibleRuntimeError, "missing required tool.*hover"
        ):
            helpers.validate_runtime_contract(
                [tool_definition("get_app_state", ["app"], ["app"])]
            )

    def test_signature_rejects_unknown_semantic_schema_constraints(self):
        tool = tool_definition("click", list(inspect.signature(helpers.click).parameters))
        tool["inputSchema"]["properties"]["click_count"]["maximum"] = 0

        with self.assertRaisesRegex(
            helpers.HelperContractError, "click_count schema does not match"
        ):
            helpers.configure(lambda name, arguments: None, [tool])

    def test_signature_rejects_required_names_without_properties(self):
        tool = tool_definition("get_app_state", ["app"], ["app"])
        tool["inputSchema"]["required"].append("impossible_ghost")

        with self.assertRaisesRegex(
            helpers.HelperContractError,
            "required names are missing from properties: impossible_ghost",
        ):
            helpers.configure(lambda name, arguments: None, [tool])

    def test_signature_ignores_documentation_only_schema_metadata(self):
        tool = tool_definition("get_app_state", ["app"], ["app"])
        tool["inputSchema"]["description"] = "Native API documentation."
        tool["inputSchema"]["properties"]["app"]["description"] = "App name."

        exported = helpers.configure(lambda name, arguments: None, [tool])

        self.assertIn("get_app_state", exported)

    def test_unknown_daemon_tools_are_not_injected(self):
        exported = helpers.configure(
            lambda name, arguments: None,
            [tool_definition("future_tool", ["value"])],
        )

        self.assertNotIn("future_tool", exported)

    def test_unavailable_code_defined_helper_has_clear_error(self):
        helpers.configure(lambda name, arguments: None, [])

        with self.assertRaisesRegex(helpers.HelperContractError, "not available"):
            helpers.get_app_state(app="Safari")

    def test_built_native_tool_schemas_match_static_helpers(self):
        binary = Path(
            os.environ.get(
                "ACCIO_TEST_NATIVE_BINARY",
                REPO_ROOT / ".build" / "debug" / "AccioComputerUse",
            )
        )
        if not binary.is_file():
            self.skipTest("build AccioComputerUse to validate the native tool contract")

        with tempfile.TemporaryDirectory() as directory:
            socket_path = os.path.join(directory, "daemon.sock")
            process = subprocess.Popen(
                [str(binary), "serve", socket_path],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline and not os.path.exists(socket_path):
                    if process.poll() is not None:
                        break
                    time.sleep(0.05)
                self.assertTrue(
                    os.path.exists(socket_path), "native daemon socket did not start"
                )
                tools = DaemonTransport(socket_path).list_tools(timeout=5)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)

        helpers.validate_runtime_contract(tools)
        exported = helpers.configure(lambda name, arguments: None, tools)
        native_helper_names = set(EXPECTED_SIGNATURES) - {"double_click"}
        advertised_names = {tool["name"] for tool in tools}
        self.assertLessEqual(native_helper_names, advertised_names)
        self.assertEqual(set(exported), set(EXPECTED_SIGNATURES))


def tool_definition(name, parameters, required=None):
    return {
        "name": name,
        "inputSchema": {
            "type": "object",
            "properties": {
                parameter: helper_parameter_schema(parameter)
                for parameter in parameters
            },
            "required": list(required or []),
            "additionalProperties": False,
        },
    }


def helper_parameter_schema(parameter):
    if parameter == "click_count":
        return {"type": "integer"}
    if parameter == "path":
        return {"type": "array", "items": {"type": "string"}}
    number_parameters = {
        "x",
        "y",
        "from_x",
        "from_y",
        "to_x",
        "to_y",
        "pages",
        "timeout_seconds",
        "poll_interval",
    }
    schema = {"type": "number" if parameter in number_parameters else "string"}
    enum_values = {
        "coordinate_space": ["pixel", "normalized_1000", "normalized_1"],
        "mouse_button": ["left", "right", "middle"],
        "direction": ["up", "down", "left", "right"],
        "wait_mode": [
            "element_text",
            "window_title_contains",
            "element_count_changed",
            "focused_value_contains",
        ],
    }.get(parameter)
    if enum_values is not None:
        schema["enum"] = enum_values
    return schema


if __name__ == "__main__":
    unittest.main()
