import base64
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from coding.accio_cu_code import mcp
from coding.accio_cu_code.runner import RunnerConfig
from coding.tests.test_coding_cli import CLI_PATH, FakeDaemon


def rpc_request(request_id, method, params=None):
    payload = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        payload["params"] = params
    return payload


class CodingMCPServerTests(unittest.TestCase):
    def run_mcp(self, messages, daemon_socket, *extra_args, timeout=10):
        command = [
            sys.executable,
            str(CLI_PATH),
            "mcp",
            "--socket",
            daemon_socket,
            *extra_args,
        ]
        input_text = "\n".join(
            message if isinstance(message, str) else json.dumps(message)
            for message in messages
        )
        return subprocess.run(
            command,
            input=input_text + "\n",
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )

    def parse_responses(self, process):
        return [json.loads(line) for line in process.stdout.splitlines() if line]

    def test_initialize_notifications_and_tools_list(self):
        with FakeDaemon() as daemon:
            process = self.run_mcp(
                [
                    rpc_request(1, "initialize", {"protocolVersion": "2026-05-20"}),
                    {"jsonrpc": "2.0", "method": "notifications/initialized"},
                    rpc_request(2, "tools/list"),
                    rpc_request(3, "ping"),
                ],
                daemon.socket_path,
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        responses = self.parse_responses(process)
        self.assertEqual([item["id"] for item in responses], [1, 2, 3])
        initialized = responses[0]["result"]
        self.assertEqual(initialized["protocolVersion"], "2026-05-20")
        self.assertEqual(initialized["serverInfo"]["name"], "accio-computer-use")
        self.assertEqual(initialized["capabilities"], {"tools": {"listChanged": False}})

        tools = responses[1]["result"]["tools"]
        self.assertEqual(len(tools), 1)
        self.assertEqual(tools[0]["name"], "execute")
        self.assertEqual(tools[0]["inputSchema"]["required"], ["code"])
        self.assertFalse(tools[0]["inputSchema"]["additionalProperties"])
        self.assertTrue(tools[0]["annotations"]["destructiveHint"])

    def test_execute_returns_existing_envelope_as_mcp_result(self):
        with FakeDaemon() as daemon:
            process = self.run_mcp(
                [
                    rpc_request(
                        1,
                        "tools/call",
                        {
                            "name": "execute",
                            "arguments": {
                                "code": (
                                    'state = get_app_state(app="Safari")\n'
                                    'emit({"observed": state.text})\n'
                                )
                            },
                        },
                    )
                ],
                daemon.socket_path,
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        response = self.parse_responses(process)[0]
        result = response["result"]
        envelope = result["structuredContent"]
        self.assertFalse(result["isError"])
        self.assertTrue(envelope["success"])
        self.assertEqual(envelope["schema_version"], "accio.coding.v1")
        self.assertEqual(envelope["value"], {"observed": "get_app_state:Safari"})
        self.assertEqual(envelope["calls"][0]["tool"], "get_app_state")
        self.assertEqual(json.loads(result["content"][0]["text"]), envelope)

    def test_emitted_screenshot_is_attached_as_mcp_image_content(self):
        png = b"\x89PNG\r\n\x1a\nfixture"

        def result_with_image(name, arguments):
            return {
                "content": [
                    {"type": "text", "text": "state"},
                    {
                        "type": "image",
                        "mimeType": "image/png",
                        "data": base64.b64encode(png).decode("ascii"),
                    },
                ],
                "isError": False,
            }

        with FakeDaemon(result_with_image) as daemon:
            process = self.run_mcp(
                [
                    rpc_request(
                        1,
                        "tools/call",
                        {
                            "name": "execute",
                            "arguments": {
                                "code": (
                                    'state = get_app_state(app="Safari")\n'
                                    'emit({"screenshots": state.screenshot_paths})\n'
                                )
                            },
                        },
                    )
                ],
                daemon.socket_path,
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        result = self.parse_responses(process)[0]["result"]
        images = [item for item in result["content"] if item["type"] == "image"]
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0]["mimeType"], "image/png")
        self.assertEqual(base64.b64decode(images[0]["data"]), png)
        self.assertNotIn(images[0]["data"], result["content"][0]["text"])

    def test_failed_block_is_a_tool_error_with_structured_envelope(self):
        with FakeDaemon() as daemon:
            process = self.run_mcp(
                [
                    rpc_request(
                        1,
                        "tools/call",
                        {
                            "name": "execute",
                            "arguments": {"code": 'raise RuntimeError("boom")'},
                        },
                    )
                ],
                daemon.socket_path,
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        result = self.parse_responses(process)[0]["result"]
        self.assertTrue(result["isError"])
        self.assertFalse(result["structuredContent"]["success"])
        self.assertEqual(result["structuredContent"]["error"]["type"], "RuntimeError")

    def test_invalid_code_and_unknown_tool_are_bounded_errors(self):
        with FakeDaemon() as daemon:
            process = self.run_mcp(
                [
                    rpc_request(
                        1,
                        "tools/call",
                        {"name": "execute", "arguments": {"code": "  \n"}},
                    ),
                    rpc_request(
                        2,
                        "tools/call",
                        {"name": "other", "arguments": {"code": "pass"}},
                    ),
                ],
                daemon.socket_path,
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        responses = self.parse_responses(process)
        empty_result = responses[0]["result"]
        self.assertTrue(empty_result["isError"])
        self.assertEqual(
            empty_result["structuredContent"]["error"]["type"],
            "EmptyCodeError",
        )
        self.assertEqual(responses[1]["error"]["code"], -32602)

    def test_malformed_json_does_not_stop_following_requests(self):
        with FakeDaemon() as daemon:
            process = self.run_mcp(
                ["{not-json", rpc_request(7, "ping")],
                daemon.socket_path,
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        responses = self.parse_responses(process)
        self.assertEqual(responses[0]["error"]["code"], -32700)
        self.assertIsNone(responses[0]["id"])
        self.assertEqual(responses[1], {"jsonrpc": "2.0", "id": 7, "result": {}})

    def test_worker_stdout_cannot_corrupt_mcp_protocol(self):
        with FakeDaemon() as daemon:
            process = self.run_mcp(
                [
                    rpc_request(
                        1,
                        "tools/call",
                        {
                            "name": "execute",
                            "arguments": {
                                "code": (
                                    'import os\n'
                                    'print("python stdout")\n'
                                    'os.write(1, b"fd stdout\\n")\n'
                                    'emit("done")\n'
                                )
                            },
                        },
                    ),
                    rpc_request(2, "ping"),
                ],
                daemon.socket_path,
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        responses = self.parse_responses(process)
        self.assertEqual(len(responses), 2)
        envelope = responses[0]["result"]["structuredContent"]
        self.assertEqual(envelope["value"], "done")
        self.assertIn("python stdout", envelope["stdout"])
        self.assertIn("fd stdout", envelope["stdout"])
        self.assertEqual(responses[1], {"jsonrpc": "2.0", "id": 2, "result": {}})

    def test_internal_runner_error_does_not_stop_following_request(self):
        def failing_runner(code, config):
            raise RuntimeError("private detail")

        server = mcp.MCPServer(
            RunnerConfig(socket_path="/missing"),
            runner=failing_runner,
        )
        requests = [
            rpc_request(
                1,
                "tools/call",
                {"name": "execute", "arguments": {"code": "emit(1)"}},
            ),
            rpc_request(2, "ping"),
        ]
        input_stream = io.BytesIO(
            ("\n".join(json.dumps(item) for item in requests) + "\n").encode()
        )
        output_stream = io.StringIO()

        self.assertEqual(server.serve(input_stream, output_stream), 0)
        responses = [json.loads(line) for line in output_stream.getvalue().splitlines()]
        self.assertEqual(responses[0]["error"]["code"], -32603)
        self.assertNotIn("private detail", output_stream.getvalue())
        self.assertEqual(responses[1], {"jsonrpc": "2.0", "id": 2, "result": {}})

    def test_overlong_jsonl_frame_is_drained_before_next_request(self):
        server = mcp.MCPServer(RunnerConfig(socket_path="/missing"))
        following = json.dumps(rpc_request(9, "ping")).encode() + b"\n"
        input_stream = io.BytesIO(b"x" * 65 + b"\n" + following)
        output_stream = io.StringIO()

        with mock.patch.object(mcp, "MAX_REQUEST_BYTES", 64):
            self.assertEqual(server.serve(input_stream, output_stream), 0)

        responses = [json.loads(line) for line in output_stream.getvalue().splitlines()]
        self.assertEqual(responses[0]["error"]["code"], -32600)
        self.assertEqual(responses[1], {"jsonrpc": "2.0", "id": 9, "result": {}})

    def test_invalid_requests_methods_and_params_return_rpc_errors(self):
        process = self.run_mcp(
            [
                "[]",
                rpc_request(1, "missing/method"),
                rpc_request(2, "tools/call", []),
                rpc_request(
                    3,
                    "tools/call",
                    {"name": "execute", "arguments": {"code": 123}},
                ),
                rpc_request(
                    4,
                    "tools/call",
                    {
                        "name": "execute",
                        "arguments": {"code": "emit(1)", "timeout": 999},
                    },
                ),
                {"jsonrpc": "2.0", "id": None, "method": "ping"},
            ],
            os.path.join(tempfile.gettempdir(), "missing-accio-daemon.sock"),
        )

        self.assertEqual(process.returncode, 0, process.stderr)
        responses = self.parse_responses(process)
        self.assertEqual(
            [item["error"]["code"] for item in responses],
            [-32600, -32601, -32602, -32602, -32602, -32600],
        )
        self.assertEqual(
            [item["id"] for item in responses],
            [None, 1, 2, 3, 4, None],
        )

    def test_missing_and_oversized_code_are_rejected_before_daemon(self):
        oversized = "界" * ((1024 * 1024 // len("界".encode("utf-8"))) + 1)
        with FakeDaemon() as daemon:
            process = self.run_mcp(
                [
                    rpc_request(
                        1,
                        "tools/call",
                        {"name": "execute", "arguments": {}},
                    ),
                    rpc_request(
                        2,
                        "tools/call",
                        {"name": "execute", "arguments": {"code": oversized}},
                    ),
                ],
                daemon.socket_path,
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        responses = self.parse_responses(process)
        self.assertEqual([item["error"]["code"] for item in responses], [-32602, -32602])
        self.assertEqual(daemon.requests, [])

    def test_startup_budgets_cannot_be_overridden_by_tool_arguments(self):
        with FakeDaemon() as daemon:
            process = self.run_mcp(
                [
                    rpc_request(
                        1,
                        "tools/call",
                        {
                            "name": "execute",
                            "arguments": {"code": 'emit("no")', "max_calls": 100},
                        },
                    )
                ],
                daemon.socket_path,
                "--max-calls",
                "1",
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        response = self.parse_responses(process)[0]
        self.assertEqual(response["error"]["code"], -32602)
        self.assertEqual(daemon.requests, [])

    def test_startup_call_budget_is_enforced_by_execute(self):
        with FakeDaemon() as daemon:
            process = self.run_mcp(
                [
                    rpc_request(
                        1,
                        "tools/call",
                        {
                            "name": "execute",
                            "arguments": {
                                "code": (
                                    'get_app_state(app="Safari")\n'
                                    'get_app_state(app="Safari")\n'
                                )
                            },
                        },
                    )
                ],
                daemon.socket_path,
                "--max-calls",
                "1",
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        envelope = self.parse_responses(process)[0]["result"]["structuredContent"]
        self.assertEqual(envelope["error"]["type"], "CallBudgetExceeded")
        self.assertEqual(
            [request["method"] for request in daemon.requests],
            ["tools/list", "tools/call"],
        )

    def test_oversized_emitted_value_becomes_a_bounded_tool_error(self):
        with FakeDaemon() as daemon:
            process = self.run_mcp(
                [
                    rpc_request(
                        1,
                        "tools/call",
                        {
                            "name": "execute",
                            "arguments": {"code": 'emit("x" * 4096)'},
                        },
                    )
                ],
                daemon.socket_path,
                "--max-output-bytes",
                "1024",
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        result = self.parse_responses(process)[0]["result"]
        self.assertTrue(result["isError"])
        self.assertEqual(
            result["structuredContent"]["error"]["type"],
            "WorkerProtocolError",
        )
        self.assertLess(len(process.stdout.encode("utf-8")), 4096)

    def test_legacy_option_value_named_mcp_keeps_json_error_on_stdout(self):
        process = subprocess.run(
            [
                sys.executable,
                str(CLI_PATH),
                "--socket",
                "mcp",
                "--timeout",
                "nan",
            ],
            input="emit(1)\n",
            text=True,
            capture_output=True,
            timeout=3,
            check=False,
        )

        self.assertEqual(process.returncode, 2)
        self.assertEqual(json.loads(process.stdout)["error"]["type"], "UsageError")
        self.assertEqual(process.stderr, "")

    def test_initialize_and_tools_list_do_not_require_daemon(self):
        process = self.run_mcp(
            [rpc_request(1, "initialize"), rpc_request(2, "tools/list")],
            os.path.join(tempfile.gettempdir(), "missing-accio-daemon.sock"),
        )

        self.assertEqual(process.returncode, 0, process.stderr)
        responses = self.parse_responses(process)
        self.assertEqual([item["id"] for item in responses], [1, 2])
        self.assertEqual(responses[1]["result"]["tools"][0]["name"], "execute")

    def test_eof_exits_without_protocol_output(self):
        process = subprocess.run(
            [sys.executable, str(CLI_PATH), "mcp"],
            input="",
            text=True,
            capture_output=True,
            timeout=3,
            check=False,
        )

        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stdout, "")

    def test_invalid_mcp_startup_options_never_write_protocol_stdout(self):
        cases = [
            ("--timeout", "nan"),
            ("--max-calls", "0"),
            ("--max-calls", "2", "--max-trace-bytes", "4096"),
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                process = subprocess.run(
                    [sys.executable, str(CLI_PATH), "mcp", *arguments],
                    input="",
                    text=True,
                    capture_output=True,
                    timeout=3,
                    check=False,
                )
                self.assertEqual(process.returncode, 2)
                self.assertEqual(process.stdout, "")
                self.assertTrue(process.stderr)

    def test_only_emitted_run_artifact_images_are_attached_once(self):
        png = b"\x89PNG\r\n\x1a\nfixture"

        def result_with_image(name, arguments):
            return {
                "content": [
                    {"type": "text", "text": "state"},
                    {
                        "type": "image",
                        "mimeType": "image/png",
                        "data": base64.b64encode(png).decode("ascii"),
                    },
                ],
                "isError": False,
            }

        with tempfile.TemporaryDirectory() as temporary:
            untrusted = Path(temporary) / "untrusted.png"
            untrusted.write_bytes(png)
            with FakeDaemon(result_with_image) as daemon:
                process = self.run_mcp(
                    [
                        rpc_request(
                            1,
                            "tools/call",
                            {
                                "name": "execute",
                                "arguments": {
                                    "code": (
                                        'state = get_app_state(app="Safari")\n'
                                        'emit({"paths": state.screenshot_paths * 2, '
                                        '"untrusted": %r})\n' % str(untrusted)
                                    )
                                },
                            },
                        ),
                        rpc_request(
                            2,
                            "tools/call",
                            {
                                "name": "execute",
                                "arguments": {
                                    "code": (
                                        'get_app_state(app="Safari")\n'
                                        'emit("artifact was not emitted")\n'
                                    )
                                },
                            },
                        ),
                    ],
                    daemon.socket_path,
                )

        self.assertEqual(process.returncode, 0, process.stderr)
        responses = self.parse_responses(process)
        first_images = [
            item
            for item in responses[0]["result"]["content"]
            if item["type"] == "image"
        ]
        second_images = [
            item
            for item in responses[1]["result"]["content"]
            if item["type"] == "image"
        ]
        self.assertEqual(len(first_images), 1)
        self.assertEqual(base64.b64decode(first_images[0]["data"]), png)
        self.assertEqual(second_images, [])


if __name__ == "__main__":
    unittest.main()
