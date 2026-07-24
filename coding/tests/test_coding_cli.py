import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest


CODING_ROOT = Path(__file__).resolve().parents[1]
CLI_PATH = CODING_ROOT / "runner.py"


TOOLS = [
    {
        "name": "get_app_state",
        "description": "Observe an app.",
        "annotations": {"readOnlyHint": True},
        "inputSchema": {
            "type": "object",
            "properties": {"app": {"type": "string"}},
            "required": ["app"],
            "additionalProperties": False,
        },
    },
    {
        "name": "type_text",
        "description": "Type text.",
        "annotations": {},
        "inputSchema": {
            "type": "object",
            "properties": {
                "app": {"type": "string"},
                "text": {"type": "string"},
                "stable_ref": {"type": "string"},
                "element_index": {"type": "string"},
                "element_text": {"type": "string"},
                "snapshot_id": {"type": "string"},
            },
            "required": ["app", "text"],
            "additionalProperties": False,
        },
    },
]


class FakeDaemon:
    def __init__(self, call_handler=None):
        self._tempdir = tempfile.TemporaryDirectory()
        self.socket_path = os.path.join(self._tempdir.name, "daemon.sock")
        self.call_handler = call_handler or self._default_call_handler
        self.requests = []
        self._server = None
        self._thread = None
        self._stop = threading.Event()

    def __enter__(self):
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(self.socket_path)
        os.chmod(self.socket_path, 0o600)
        self._server.listen(8)
        self._server.settimeout(0.1)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self._stop.set()
        if self._server is not None:
            self._server.close()
        if self._thread is not None:
            self._thread.join(timeout=2)
        self._tempdir.cleanup()

    def _serve(self):
        while not self._stop.is_set():
            try:
                connection, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                payload = b""
                while True:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    payload += chunk
                request = json.loads(payload.decode("utf-8").strip())
                self.requests.append(request)
                response = self._response_for(request)
                try:
                    connection.sendall((json.dumps(response) + "\n").encode("utf-8"))
                except BrokenPipeError:
                    pass

    def _response_for(self, request):
        method = request.get("method")
        if method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            params = request["params"]
            result = self.call_handler(params["name"], params["arguments"])
        else:
            return {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "error": {"code": -32601, "message": "unknown method"},
            }
        return {"jsonrpc": "2.0", "id": request.get("id"), "result": result}

    @staticmethod
    def _default_call_handler(name, arguments):
        return {
            "content": [{"type": "text", "text": "%s:%s" % (name, arguments["app"])}],
            "isError": False,
        }


class CodingCLITests(unittest.TestCase):
    def run_cli(self, code, daemon_socket, *extra_args, timeout=10):
        command = [
            sys.executable,
            str(CLI_PATH),
            "--socket",
            daemon_socket,
            *extra_args,
        ]
        return subprocess.run(
            command,
            input=code,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )

    def test_executes_stdin_code_with_preloaded_helper_and_emit(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                'state = get_app_state(app="Safari")\n'
                "print(state.text)\n"
                'emit({"observed": state.text})\n',
                daemon.socket_path,
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        envelope = json.loads(process.stdout)
        self.assertEqual(envelope["schema_version"], "accio.coding.v1")
        self.assertTrue(envelope["success"])
        self.assertEqual(envelope["stdout"], "get_app_state:Safari\n")
        self.assertEqual(envelope["value"], {"observed": "get_app_state:Safari"})
        self.assertEqual(envelope["metrics"]["tool_calls"], 1)
        self.assertEqual(envelope["calls"][0]["tool"], "get_app_state")
        self.assertEqual(envelope["calls"][0]["kind"], "OBSERVE")
        self.assertTrue(Path(envelope["artifacts"]["trace_path"]).is_file())
        self.assertEqual(
            [request["method"] for request in daemon.requests],
            ["tools/list", "tools/call"],
        )

    def test_action_metadata_is_visible_in_block_and_call_summary(self):
        def result_with_action(name, arguments):
            self.assertEqual(name, "type_text")
            return {
                "content": [{"type": "text", "text": "typed"}],
                "isError": False,
                "structuredContent": {
                    "action": {
                        "tool": "type_text",
                        "route": "keyboard_post_to_pid",
                        "changed": "confirmed",
                    }
                },
            }

        with FakeDaemon(result_with_action) as daemon:
            process = self.run_cli(
                'result = type_text(app="Numbers", text="94")\n'
                'emit({"route": result.route, "changed": result.changed})\n',
                daemon.socket_path,
            )

        self.assertEqual(process.returncode, 0, process.stderr)
        envelope = json.loads(process.stdout)
        self.assertEqual(
            envelope["value"],
            {"route": "keyboard_post_to_pid", "changed": "confirmed"},
        )
        self.assertEqual(
            envelope["calls"][0]["result_summary"]["route"],
            "keyboard_post_to_pid",
        )
        self.assertEqual(
            envelope["calls"][0]["result_summary"]["changed"],
            "confirmed",
        )

    def test_extracts_screenshot_and_redacts_sensitive_arguments(self):
        png = b"\x89PNG\r\n\x1a\nfixture"

        def result_with_image(name, arguments):
            self.assertEqual(name, "type_text")
            self.assertEqual(arguments["text"], "top secret")
            return {
                "content": [
                    {"type": "text", "text": "typed"},
                    {
                        "type": "image",
                        "mimeType": "image/png",
                        "data": base64.b64encode(png).decode("ascii"),
                    },
                ],
                "isError": False,
            }

        with (
            tempfile.TemporaryDirectory() as artifacts,
            FakeDaemon(result_with_image) as daemon,
        ):
            process = self.run_cli(
                'result = type_text(app="TextEdit", text="top secret")\nemit(result)\n',
                daemon.socket_path,
                "--artifacts-dir",
                artifacts,
            )
            envelope = json.loads(process.stdout)
            trace_text = Path(envelope["artifacts"]["trace_path"]).read_text()
            screenshot_path = Path(envelope["calls"][0]["artifact_paths"][0])

            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertTrue(screenshot_path.is_file())
            self.assertEqual(screenshot_path.read_bytes(), png)
            self.assertNotIn(base64.b64encode(png).decode("ascii"), process.stdout)
            self.assertNotIn(base64.b64encode(png).decode("ascii"), trace_text)
            self.assertNotIn("top secret", trace_text)
            redacted = envelope["calls"][0]["arguments"]["text"]
            self.assertTrue(redacted["redacted"])
            self.assertEqual(redacted["length"], 10)

    def test_default_trace_does_not_persist_full_result_text(self):
        def result_with_secret(name, arguments):
            return {
                "content": [{"type": "text", "text": "password is hunter2"}],
                "isError": False,
            }

        with FakeDaemon(result_with_secret) as daemon:
            process = self.run_cli(
                'get_app_state(app="Safari")\n',
                daemon.socket_path,
            )

        envelope = json.loads(process.stdout)
        trace_text = Path(envelope["artifacts"]["trace_path"]).read_text()
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertNotIn("hunter2", trace_text)
        self.assertIn("result_summary", trace_text)

    def test_artifact_base_directory_can_be_reused(self):
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

        with (
            tempfile.TemporaryDirectory() as artifacts,
            FakeDaemon(result_with_image) as daemon,
        ):
            first = self.run_cli(
                'get_app_state(app="Safari")\n',
                daemon.socket_path,
                "--artifacts-dir",
                artifacts,
            )
            second = self.run_cli(
                'get_app_state(app="Safari")\n',
                daemon.socket_path,
                "--artifacts-dir",
                artifacts,
            )

        first_envelope = json.loads(first.stdout)
        second_envelope = json.loads(second.stdout)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotEqual(
            first_envelope["artifacts"]["directory"],
            second_envelope["artifacts"]["directory"],
        )

    def test_python_signature_rejects_invalid_arguments_before_calling_daemon(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                'get_app_state(app="Safari", unexpected=True)\n',
                daemon.socket_path,
            )

        self.assertNotEqual(process.returncode, 0)
        envelope = json.loads(process.stdout)
        self.assertFalse(envelope["success"])
        self.assertEqual(envelope["error"]["type"], "TypeError")
        self.assertIn("unexpected keyword argument", envelope["error"]["message"])
        self.assertEqual(len(daemon.requests), 1)

    def test_python_signature_requires_mandatory_arguments_before_daemon_call(self):
        with FakeDaemon() as daemon:
            process = self.run_cli("get_app_state()\n", daemon.socket_path)

        self.assertNotEqual(process.returncode, 0)
        envelope = json.loads(process.stdout)
        self.assertEqual(envelope["error"]["type"], "TypeError")
        self.assertIn("required keyword-only argument", envelope["error"]["message"])
        self.assertEqual(len(daemon.requests), 1)

    def test_tool_error_is_traced_and_fails_the_block(self):
        def tool_error(name, arguments):
            return {
                "content": [{"type": "text", "text": "element not found"}],
                "isError": True,
            }

        with FakeDaemon(tool_error) as daemon:
            process = self.run_cli(
                'get_app_state(app="Missing")\n',
                daemon.socket_path,
            )

        self.assertNotEqual(process.returncode, 0)
        envelope = json.loads(process.stdout)
        self.assertEqual(envelope["error"]["type"], "ToolError")
        self.assertEqual(envelope["metrics"]["tool_calls"], 1)
        self.assertFalse(envelope["calls"][0]["success"])

    def test_model_code_can_catch_tool_error_and_recover(self):
        def tool_error(name, arguments):
            return {
                "content": [{"type": "text", "text": "not ready"}],
                "isError": True,
            }

        with FakeDaemon(tool_error) as daemon:
            process = self.run_cli(
                "try:\n"
                '    get_app_state(app="Safari")\n'
                "except ToolError as error:\n"
                '    emit({"recovered": error.result.text})\n',
                daemon.socket_path,
            )

        envelope = json.loads(process.stdout)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(envelope["success"])
        self.assertEqual(envelope["value"], {"recovered": "not ready"})
        self.assertFalse(envelope["calls"][0]["success"])

    def test_enforces_max_calls_in_supervisor(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                'get_app_state(app="Safari")\nget_app_state(app="Safari")\n',
                daemon.socket_path,
                "--max-calls",
                "1",
            )

        self.assertNotEqual(process.returncode, 0)
        envelope = json.loads(process.stdout)
        self.assertEqual(envelope["error"]["type"], "CallBudgetExceeded")
        self.assertEqual(envelope["metrics"]["tool_calls"], 1)
        self.assertEqual(len(daemon.requests), 2)

    def test_failed_calls_are_traced_and_consume_call_budget(self):
        def malformed_result(name, arguments):
            return {"isError": False}

        with FakeDaemon(malformed_result) as daemon:
            process = self.run_cli(
                "for _ in range(3):\n"
                "    try:\n"
                '        get_app_state(app="Safari")\n'
                "    except (DaemonProtocolError, CallBudgetExceeded):\n"
                "        pass\n"
                'emit("recovered")\n',
                daemon.socket_path,
                "--max-calls",
                "1",
            )

        envelope = json.loads(process.stdout)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(envelope["metrics"]["tool_calls"], 1)
        self.assertEqual(len(envelope["calls"]), 1)
        self.assertFalse(envelope["calls"][0]["success"])
        self.assertEqual(envelope["calls"][0]["error"]["type"], "DaemonProtocolError")
        self.assertEqual(
            [request["method"] for request in daemon.requests],
            ["tools/list", "tools/call"],
        )

    def test_daemon_unavailable_fails_closed(self):
        missing_socket = os.path.join(
            tempfile.gettempdir(), "missing-accio-daemon.sock"
        )
        process = self.run_cli("print('never runs')\n", missing_socket)

        self.assertNotEqual(process.returncode, 0)
        envelope = json.loads(process.stdout)
        self.assertFalse(envelope["success"])
        self.assertEqual(envelope["error"]["type"], "DaemonUnavailableError")
        self.assertNotIn("never runs", envelope["stdout"])

    def test_insecure_socket_permissions_are_rejected(self):
        with FakeDaemon() as daemon:
            os.chmod(daemon.socket_path, 0o666)
            process = self.run_cli("print('never runs')\n", daemon.socket_path)

        envelope = json.loads(process.stdout)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(envelope["error"]["type"], "DaemonUnavailableError")
        self.assertIn("permissions", envelope["error"]["message"])

    def test_stdout_is_capped(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                'print("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")\n',
                daemon.socket_path,
                "--max-output-bytes",
                "10",
            )

        envelope = json.loads(process.stdout)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(envelope["stdout"].startswith("x" * 10))
        self.assertIn("[output truncated]", envelope["stdout"])

    def test_non_finite_emitted_value_is_rejected_as_valid_json(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                'emit(float("nan"))\n',
                daemon.socket_path,
            )

        envelope = json.loads(
            process.stdout, parse_constant=lambda value: self.fail(value)
        )
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(envelope["error"]["type"], "SerializationError")

    def test_fd_level_stdout_does_not_corrupt_worker_protocol(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                'import os\nos.write(1, b"native output\\n")\nemit("done")\n',
                daemon.socket_path,
            )

        envelope = json.loads(process.stdout)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(envelope["value"], "done")
        self.assertIn("native output", envelope["stdout"])

    def test_full_python_imports_functions_and_introspection_work_by_default(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                "import inspect\n"
                "def observe(app):\n"
                "    return get_app_state(app=app)\n"
                "state = observe('Safari')\n"
                "emit({\n"
                "    'state': state.text,\n"
                "    'get_app_state': str(inspect.signature(get_app_state)),\n"
                "    'type_text': str(inspect.signature(type_text)),\n"
                "})\n",
                daemon.socket_path,
            )

        envelope = json.loads(process.stdout)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(envelope["value"]["state"], "get_app_state:Safari")
        self.assertEqual(envelope["value"]["get_app_state"], "(*, app)")
        self.assertEqual(
            envelope["value"]["type_text"],
            "(*, app, text, stable_ref=None, element_index: Optional[str] = None, "
            "element_text=None, snapshot_id=None)",
        )

    def test_helper_help_exposes_signature_and_docstring(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                "help(type_text)\n",
                daemon.socket_path,
            )

        envelope = json.loads(process.stdout)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("Help on function type_text", envelope["stdout"])
        self.assertIn("app", envelope["stdout"])
        self.assertIn("text", envelope["stdout"])
        self.assertIn("Type text", envelope["stdout"])

    def test_worker_inherits_environment_and_current_working_directory(self):
        parent_cwd = os.getcwd()
        variable_name = "ACCIO_CODING_INHERITED_ENV_TEST"
        previous = os.environ.get(variable_name)
        os.environ[variable_name] = "visible"
        try:
            with FakeDaemon() as daemon:
                process = self.run_cli(
                    "import os\n"
                    "emit({'cwd': os.getcwd(), 'env': "
                    f"os.environ.get('{variable_name}')}})\n",
                    daemon.socket_path,
                )
        finally:
            if previous is None:
                os.environ.pop(variable_name, None)
            else:
                os.environ[variable_name] = previous

        envelope = json.loads(process.stdout)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(envelope["value"], {"cwd": parent_cwd, "env": "visible"})

    def test_trace_budget_must_reserve_space_for_each_call(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                'print("never runs")\n',
                daemon.socket_path,
                "--max-calls",
                "2",
                "--max-trace-bytes",
                "4096",
            )

        envelope = json.loads(process.stdout)
        self.assertEqual(process.returncode, 2)
        self.assertEqual(envelope["error"]["type"], "UsageError")
        self.assertEqual(len(daemon.requests), 0)

    def test_non_finite_timeout_is_rejected_before_contacting_daemon(self):
        for value in ("nan", "inf"):
            with self.subTest(value=value), FakeDaemon() as daemon:
                process = self.run_cli(
                    'print("never runs")\n',
                    daemon.socket_path,
                    "--timeout",
                    value,
                )

                envelope = json.loads(process.stdout)
                self.assertEqual(process.returncode, 2)
                self.assertEqual(envelope["error"]["type"], "UsageError")
                self.assertIn("finite", envelope["error"]["message"])
                self.assertEqual(len(daemon.requests), 0)

    def test_empty_stdin_is_rejected_without_contacting_daemon(self):
        process = subprocess.run(
            [sys.executable, str(CLI_PATH)],
            input="  \n",
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(process.returncode, 2)
        envelope = json.loads(process.stdout)
        self.assertEqual(envelope["error"]["type"], "EmptyCodeError")

    def test_wall_timeout_terminates_worker(self):
        with FakeDaemon() as daemon:
            started = time.monotonic()
            process = self.run_cli(
                "while True:\n    pass\n",
                daemon.socket_path,
                "--timeout",
                "0.2",
            )
            elapsed = time.monotonic() - started

        self.assertNotEqual(process.returncode, 0)
        self.assertLess(elapsed, 3)
        envelope = json.loads(process.stdout)
        self.assertEqual(envelope["error"]["type"], "ExecutionTimeout")

    def test_wall_timeout_clamps_slow_daemon_call(self):
        def slow_result(name, arguments):
            time.sleep(1)
            return FakeDaemon._default_call_handler(name, arguments)

        with FakeDaemon(slow_result) as daemon:
            started = time.monotonic()
            process = self.run_cli(
                'get_app_state(app="Safari")\n',
                daemon.socket_path,
                "--timeout",
                "0.2",
                "--call-timeout",
                "2",
            )
            elapsed = time.monotonic() - started

        envelope = json.loads(process.stdout)
        self.assertNotEqual(process.returncode, 0)
        self.assertLess(elapsed, 0.8)
        self.assertIn(
            envelope["error"]["type"],
            {"ExecutionTimeout", "DaemonUnavailableError"},
        )

    def test_timeout_kills_worker_process_group(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                "import os, subprocess, sys\n"
                'child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])\n'
                'os.write(1, ("CHILD:%d\\n" % child.pid).encode())\n'
                "while True:\n"
                "    pass\n",
                daemon.socket_path,
                "--timeout",
                "1.0",
            )

        envelope = json.loads(process.stdout)
        child_line = next(
            line
            for line in envelope["stdout"].splitlines()
            if line.startswith("CHILD:")
        )
        child_pid = int(child_line.split(":", 1)[1])
        time.sleep(0.1)
        try:
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
        finally:
            try:
                os.kill(child_pid, 9)
            except ProcessLookupError:
                pass

    def test_memory_budget_terminates_worker(self):
        with FakeDaemon() as daemon:
            process = self.run_cli(
                "blob = bytearray(128 * 1024 * 1024)\nwhile True:\n    pass\n",
                daemon.socket_path,
                "--max-memory-bytes",
                str(48 * 1024 * 1024),
                "--timeout",
                "3",
            )

        envelope = json.loads(process.stdout)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(envelope["error"]["type"], "MemoryBudgetExceeded")


if __name__ == "__main__":
    unittest.main()
