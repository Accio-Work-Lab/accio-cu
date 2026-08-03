import json
import base64
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from accio_cu_code.trace import TraceRecorder


class TraceRecorderTests(unittest.TestCase):
    def test_saved_image_records_immutable_integrity_metadata(self):
        png = b"\x89PNG\r\n\x1a\nintegrity"
        with tempfile.TemporaryDirectory() as artifacts:
            recorder = TraceRecorder(artifacts)
            _, paths = recorder.process_result(
                {
                    "content": [
                        {
                            "type": "image",
                            "mimeType": "image/png",
                            "data": base64.b64encode(png).decode("ascii"),
                        }
                    ]
                },
                call_index=1,
            )
            recorder.close()

        self.assertEqual(
            recorder.artifact_sha256,
            {paths[0]: hashlib.sha256(png).hexdigest()},
        )

    def test_result_summary_includes_structured_action_metadata(self):
        with tempfile.TemporaryDirectory() as artifacts:
            recorder = TraceRecorder(artifacts)
            call = recorder.record_call(
                index=1,
                kind="GUI_ACTION",
                tool="type_text",
                arguments={"app": "Numbers", "text": "94"},
                duration_ms=1,
                result={
                    "content": [{"type": "text", "text": "done"}],
                    "isError": False,
                    "structuredContent": {
                        "action": {
                            "tool": "type_text",
                            "route": "keyboard_post_to_pid",
                            "changed": "confirmed",
                        }
                    },
                },
            )
            recorder.close()

        self.assertEqual(call["result_summary"]["route"], "keyboard_post_to_pid")
        self.assertEqual(call["result_summary"]["changed"], "confirmed")

    def test_result_summary_drops_untrusted_action_metadata(self):
        with tempfile.TemporaryDirectory() as artifacts:
            recorder = TraceRecorder(artifacts)
            call = recorder.record_call(
                index=1,
                kind="GUI_ACTION",
                tool="type_text",
                arguments={"app": "Numbers", "text": "94"},
                duration_ms=1,
                result={
                    "content": [{"type": "text", "text": "done"}],
                    "structuredContent": {
                        "action": {
                            "tool": "type_text",
                            "route": "forged_route",
                            "changed": "confirmed",
                        }
                    },
                },
            )
            recorder.close()

        self.assertNotIn("route", call["result_summary"])
        self.assertNotIn("changed", call["result_summary"])

    def test_result_summary_rejects_action_metadata_for_another_tool(self):
        with tempfile.TemporaryDirectory() as artifacts:
            recorder = TraceRecorder(artifacts)
            call = recorder.record_call(
                index=1,
                kind="GUI_ACTION",
                tool="click",
                arguments={"app": "Finder", "element_text": "Documents"},
                duration_ms=1,
                result={
                    "content": [{"type": "text", "text": "done"}],
                    "structuredContent": {
                        "action": {
                            "tool": "type_text",
                            "route": "keyboard_hid",
                            "changed": "confirmed",
                        }
                    },
                },
            )
            recorder.close()

        self.assertNotIn("route", call["result_summary"])
        self.assertNotIn("changed", call["result_summary"])

    def test_full_result_falls_back_to_summary_when_trace_budget_is_tight(self):
        with tempfile.TemporaryDirectory() as artifacts:
            recorder = TraceRecorder(
                artifacts,
                full_results=True,
                max_trace_bytes=4096,
            )
            recorder.record_call(
                index=1,
                kind="OBSERVE",
                tool="get_app_state",
                arguments={"app": "Safari"},
                duration_ms=1,
                result={
                    "content": [{"type": "text", "text": "x" * 10_000}],
                    "isError": False,
                },
            )
            recorder.close()
            trace = json.loads(recorder.trace_path.read_text())

        self.assertNotIn("result", trace)
        self.assertEqual(trace["full_result_omitted"], "trace budget exceeded")
        self.assertEqual(trace["result_summary"]["text_chars"], 10_000)

    def test_large_arguments_are_compacted_after_sensitive_redaction(self):
        with tempfile.TemporaryDirectory() as artifacts:
            recorder = TraceRecorder(artifacts)
            call = recorder.record_call(
                index=1,
                kind="GUI_ACTION",
                tool="menu_select",
                arguments={"path": ["item-%04d" % index for index in range(500)]},
                duration_ms=1,
                error={"type": "FixtureError", "message": "m" * 2_000},
            )
            recorder.close()

        self.assertTrue(call["arguments"]["truncated"])
        self.assertEqual(call["error"]["type"], "FixtureError")
        self.assertLessEqual(len(call["error"]["message"]), 1025)


if __name__ == "__main__":
    unittest.main()
