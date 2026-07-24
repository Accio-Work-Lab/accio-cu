import json
import os
from pathlib import Path
import socket
import struct
import sys
import unittest
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from accio_cu_code.worker import (
    CappedTextIO,
    SerializationError,
    ToolResult,
    ProtocolChannel,
    _execute,
    _json_safe,
)
import accio_cu_code.worker as worker_module


class WorkerUnitTests(unittest.TestCase):
    def setUp(self):
        worker_module._request_id = 0
        worker_module._emitted_value = None

    def test_execute_exposes_real_helper_signatures_and_docstrings(self):
        worker_module._channel = FakeWorkerChannel(None)
        initial = {
            "code": (
                "import inspect\n"
                "emit({\n"
                "    'signature': str(inspect.signature(get_app_state)),\n"
                "    'doc': inspect.getdoc(get_app_state),\n"
                "})\n"
            ),
            "tools": [tool_definition("get_app_state")],
            "max_output_bytes": 1024,
            "timeout": 5.0,
        }
        with mock.patch.object(worker_module, "_apply_resource_limits"):
            result = _execute(initial)

        self.assertTrue(result["success"])
        self.assertEqual(result["value"]["signature"], "(*, app)")
        self.assertIn("Snapshot", result["value"]["doc"])

    def test_execute_accepts_normal_python_definitions_and_reflection(self):
        worker_module._channel = FakeWorkerChannel(None)
        initial = {
            "code": (
                "import inspect\n"
                "def identity(value):\n"
                "    return value\n"
                "emit(identity(inspect.isfunction(identity)))\n"
            ),
            "tools": [tool_definition("get_app_state")],
            "max_output_bytes": 1024,
            "timeout": 5.0,
        }
        with mock.patch.object(worker_module, "_apply_resource_limits"):
            result = _execute(initial)

        self.assertTrue(result["success"])
        self.assertTrue(result["value"])

    def test_tool_result_and_json_serialization(self):
        result = ToolResult(
            {
                "content": [
                    {"type": "text", "text": "ready"},
                    {"type": "image", "path": "/tmp/image.png"},
                ],
                "isError": False,
                "structuredContent": {
                    "state": {"snapshot_id": "snap-1", "app": "TextEdit"}
                },
            }
        )
        self.assertEqual(result.text, "ready")
        self.assertEqual(result.screenshot_paths, ["/tmp/image.png"])
        self.assertEqual(result.snapshot_id, "snap-1")
        self.assertEqual(result.state["app"], "TextEdit")
        self.assertEqual(_json_safe({"result": result})["result"], result.to_dict())
        with self.assertRaises(SerializationError):
            _json_safe(float("inf"))

    def test_tool_result_exposes_structured_action_metadata(self):
        result = ToolResult(
            {
                "content": [{"type": "text", "text": "done"}],
                "isError": False,
                "structuredContent": {
                    "action": {
                        "tool": "type_text",
                        "route": "keyboard_post_to_pid",
                        "changed": "confirmed",
                    }
                },
            }
        )

        self.assertEqual(result.action["tool"], "type_text")
        self.assertEqual(result.route, "keyboard_post_to_pid")
        self.assertEqual(result.changed, "confirmed")

    def test_tool_result_rejects_untrusted_action_metadata(self):
        result = ToolResult(
            {
                "content": [{"type": "text", "text": "done"}],
                "structuredContent": {
                    "action": {
                        "tool": "type_text",
                        "route": "route=" + "x" * 10_000,
                        "changed": "confirmed",
                    }
                },
            }
        )

        self.assertEqual(result.action, {})
        self.assertIsNone(result.route)
        self.assertIsNone(result.changed)

    def test_capped_output_preserves_utf8_boundary(self):
        output = CappedTextIO(4)
        output.write("ééé")
        self.assertTrue(output.truncated)
        self.assertTrue(output.getvalue().startswith("éé"))
        output.write("ignored")
        self.assertIn("output truncated", output.getvalue())

    def test_execute_runs_helper_print_and_emit_through_channel(self):
        channel = FakeWorkerChannel(
            {
                "type": "call_result",
                "id": 1,
                "result": {
                    "content": [{"type": "text", "text": "ready"}],
                    "isError": False,
                },
            }
        )
        worker_module._channel = channel
        initial = {
            "code": (
                'state = get_app_state(app="Safari")\n'
                "print(state.text)\n"
                'emit({"ready": state.text == "ready"})\n'
            ),
            "tools": [tool_definition("get_app_state")],
            "max_output_bytes": 1024,
            "timeout": 5.0,
        }
        with mock.patch.object(worker_module, "_apply_resource_limits"):
            result = _execute(initial)

        self.assertTrue(result["success"])
        self.assertEqual(result["stdout"], "ready\n")
        self.assertEqual(result["value"], {"ready": True})
        self.assertEqual(channel.sent[0]["tool"], "get_app_state")

    def test_execute_maps_call_error_and_tool_error(self):
        call_error_channel = FakeWorkerChannel(
            {
                "type": "call_error",
                "id": 1,
                "error": {"type": "ArgumentValidationError", "message": "bad app"},
            }
        )
        worker_module._channel = call_error_channel
        caught_initial = {
            "code": (
                "try:\n"
                '    get_app_state(app="Safari")\n'
                "except ArgumentValidationError as error:\n"
                "    emit(str(error))\n"
            ),
            "tools": [tool_definition("get_app_state")],
            "max_output_bytes": 1024,
            "timeout": 5.0,
        }
        with mock.patch.object(worker_module, "_apply_resource_limits"):
            caught = _execute(caught_initial)
        self.assertTrue(caught["success"])
        self.assertEqual(caught["value"], "bad app")

        worker_module._request_id = 0
        worker_module._emitted_value = None
        worker_module._channel = FakeWorkerChannel(
            {
                "type": "call_result",
                "id": 1,
                "result": {
                    "content": [{"type": "text", "text": "native failure"}],
                    "isError": True,
                },
            }
        )
        with mock.patch.object(worker_module, "_apply_resource_limits"):
            failed = _execute(
                {
                    **caught_initial,
                    "code": 'get_app_state(app="Safari")\n',
                }
            )
        self.assertFalse(failed["success"])
        self.assertEqual(failed["error"]["type"], "ToolError")
        self.assertIn("native failure", failed["error"]["message"])

    def test_protocol_channel_uses_bounded_length_prefixed_json(self):
        worker_socket, parent_socket = socket.socketpair()
        descriptor = worker_socket.detach()
        with mock.patch.dict(
            os.environ,
            {
                "ACCIO_PROTOCOL_FD": str(descriptor),
                "ACCIO_PROTOCOL_MAX_BYTES": "1024",
            },
            clear=False,
        ):
            channel = ProtocolChannel()
        try:
            incoming = json.dumps({"type": "execute"}).encode("utf-8")
            parent_socket.sendall(struct.pack("!I", len(incoming)) + incoming)
            self.assertEqual(channel.receive(), {"type": "execute"})

            channel.send({"type": "finished", "success": True})
            size = struct.unpack("!I", read_exact(parent_socket, 4))[0]
            outgoing = json.loads(read_exact(parent_socket, size).decode("utf-8"))
            self.assertEqual(outgoing["type"], "finished")
        finally:
            channel.connection.close()
            parent_socket.close()


class FakeWorkerChannel:
    def __init__(self, response):
        self.response = response
        self.sent = []

    def send(self, message):
        self.sent.append(message)

    def receive(self):
        return self.response


def tool_definition(name):
    return {
        "name": name,
        "description": "fixture",
        "inputSchema": {
            "type": "object",
            "properties": {"app": {"type": "string"}},
            "required": ["app"],
            "additionalProperties": False,
        },
    }


def read_exact(connection, length):
    value = b""
    while len(value) < length:
        value += connection.recv(length - len(value))
    return value


if __name__ == "__main__":
    unittest.main()
