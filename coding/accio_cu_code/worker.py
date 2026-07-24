"""Disposable full-Python worker for one Accio coding block."""

import contextlib
import io
import json
import math
import os
import resource
import socket
import struct
import sys
import traceback

try:
    from .action_metadata import validated_action_metadata
    from . import helpers as helper_api
except ImportError:  # Executed directly by runner.py.
    from action_metadata import validated_action_metadata
    import helpers as helper_api


sys.dont_write_bytecode = True


class CodingError(Exception):
    pass


class SerializationError(CodingError):
    pass


class ArgumentValidationError(CodingError):
    pass


class CallBudgetExceeded(CodingError):
    pass


class DaemonUnavailableError(CodingError):
    pass


class DaemonProtocolError(CodingError):
    pass


class ResponseTooLargeError(CodingError):
    pass


class ArtifactBudgetExceeded(CodingError):
    pass


class ToolError(CodingError):
    def __init__(self, message, result):
        super().__init__(message)
        self.result = result


class ToolResult:
    def __init__(self, payload):
        self._payload = payload
        self.content = list(payload.get("content", []))
        self.is_error = bool(payload.get("isError", False))
        self.structured_content = dict(payload.get("structuredContent") or {})

    @property
    def text(self):
        for item in self.content:
            if item.get("type") == "text":
                return item.get("text", "")
        return ""

    @property
    def screenshot_paths(self):
        return [
            item["path"]
            for item in self.content
            if item.get("type") == "image" and isinstance(item.get("path"), str)
        ]

    @property
    def state(self):
        return dict(self.structured_content.get("state") or {})

    @property
    def action(self):
        return validated_action_metadata(self.structured_content.get("action"))

    @property
    def route(self):
        value = self.action.get("route")
        return value if isinstance(value, str) else None

    @property
    def changed(self):
        value = self.action.get("changed")
        return value if isinstance(value, str) else None

    @property
    def snapshot_id(self):
        value = self.state.get("snapshot_id")
        return value if isinstance(value, str) else None

    def to_dict(self):
        return dict(self._payload)

    def __repr__(self):
        return "ToolResult(is_error=%r, text=%r, screenshots=%r)" % (
            self.is_error,
            self.text,
            self.screenshot_paths,
        )


class CappedTextIO(io.TextIOBase):
    def __init__(self, max_bytes):
        self.max_bytes = max_bytes
        self._parts = []
        self._bytes = 0
        self.truncated = False

    def writable(self):
        return True

    def write(self, text):
        if not isinstance(text, str):
            text = str(text)
        remaining = max(self.max_bytes - self._bytes, 0)
        if remaining == 0:
            self.truncated = True
            return len(text)
        # Slice before encoding so a large fd-level value does not create a
        # second full-sized byte copy merely to discover it exceeds the cap.
        candidate = text[:remaining]
        encoded = candidate.encode("utf-8")
        if len(encoded) <= remaining:
            self._parts.append(candidate)
            self._bytes += len(encoded)
            if len(candidate) != len(text):
                self.truncated = True
            return len(text)
        clipped = encoded[:remaining].decode("utf-8", errors="ignore")
        self._parts.append(clipped)
        self._bytes += len(clipped.encode("utf-8"))
        self.truncated = True
        return len(text)

    def getvalue(self):
        value = "".join(self._parts)
        if self.truncated:
            value += "\n[output truncated]\n"
        return value


class ProtocolChannel:
    def __init__(self):
        try:
            descriptor = int(os.environ["ACCIO_PROTOCOL_FD"])
            self.max_frame_bytes = int(os.environ["ACCIO_PROTOCOL_MAX_BYTES"])
        except (KeyError, ValueError) as error:
            raise DaemonProtocolError(
                "missing worker protocol configuration"
            ) from error
        self.connection = socket.socket(fileno=descriptor)

    def send(self, message):
        payload = json.dumps(
            message,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        if len(payload) > self.max_frame_bytes:
            raise DaemonProtocolError(
                "worker protocol frame exceeded %d bytes" % self.max_frame_bytes
            )
        self.connection.sendall(struct.pack("!I", len(payload)) + payload)

    def receive(self):
        header = self._read_exact(4)
        length = struct.unpack("!I", header)[0]
        if length > self.max_frame_bytes:
            raise DaemonProtocolError(
                "worker protocol frame exceeded %d bytes" % self.max_frame_bytes
            )
        payload = self._read_exact(length)
        message = json.loads(payload.decode("utf-8"))
        if not isinstance(message, dict):
            raise DaemonProtocolError("supervisor message must be an object")
        return message

    def _read_exact(self, length):
        chunks = []
        remaining = length
        while remaining:
            chunk = self.connection.recv(remaining)
            if not chunk:
                raise DaemonProtocolError("supervisor closed the worker protocol")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)


_channel = None
_request_id = 0
_emitted_value = None


def _send(message):
    _channel.send(message)


def _receive():
    return _channel.receive()


def _call_tool(tool_name, arguments):
    global _request_id
    _request_id += 1
    request_id = _request_id
    _send({"type": "call", "id": request_id, "tool": tool_name, "arguments": arguments})
    response = _receive()
    if response.get("id") != request_id:
        raise DaemonProtocolError("supervisor response id mismatch")
    if response.get("type") == "call_error":
        error = response.get("error") or {}
        error_class = globals().get(error.get("type"), CodingError)
        if not isinstance(error_class, type) or not issubclass(error_class, Exception):
            error_class = CodingError
        raise error_class(error.get("message", "tool call failed"))
    if response.get("type") != "call_result":
        raise DaemonProtocolError("unexpected supervisor response")
    result = ToolResult(response.get("result") or {})
    if result.is_error:
        raise ToolError(result.text or "%s failed" % tool_name, result)
    return result


def emit(value):
    global _emitted_value
    _emitted_value = value


def _json_safe(value):
    if isinstance(value, ToolResult):
        return value.to_dict()
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise SerializationError("emitted floats must be finite")
        return value
    if isinstance(value, list):
        return [_json_safe(item) for item in value]
    if isinstance(value, tuple):
        return [_json_safe(item) for item in value]
    if isinstance(value, dict):
        return {str(key): _json_safe(item) for key, item in value.items()}
    return repr(value)


def _apply_resource_limits(timeout, max_output_bytes):
    cpu_seconds = max(1, int(math.ceil(timeout)) + 1)
    file_bytes = max(16 * 1024 * 1024, max_output_bytes * 2)
    limits = [
        (resource.RLIMIT_CPU, cpu_seconds),
        (resource.RLIMIT_FSIZE, file_bytes),
        (resource.RLIMIT_NOFILE, 64),
    ]
    for resource_name, limit in limits:
        try:
            resource.setrlimit(resource_name, (limit, limit))
        except (OSError, ValueError):
            pass


def _execute(initial):
    code = initial.get("code")
    tools = initial.get("tools")
    max_output_bytes = initial.get("max_output_bytes")
    timeout = initial.get("timeout")
    if not isinstance(code, str) or not isinstance(tools, list):
        raise DaemonProtocolError("invalid execute message")
    if not isinstance(max_output_bytes, int) or max_output_bytes < 1:
        raise DaemonProtocolError("invalid output limit")
    if not isinstance(timeout, (int, float)) or timeout <= 0:
        raise DaemonProtocolError("invalid timeout")
    _apply_resource_limits(timeout, max_output_bytes)

    namespace = {
        "__name__": "__accio_code__",
        "emit": emit,
        "ToolError": ToolError,
        "CodingError": CodingError,
        "ArgumentValidationError": ArgumentValidationError,
        "CallBudgetExceeded": CallBudgetExceeded,
        "DaemonUnavailableError": DaemonUnavailableError,
        "DaemonProtocolError": DaemonProtocolError,
        "ResponseTooLargeError": ResponseTooLargeError,
        "ArtifactBudgetExceeded": ArtifactBudgetExceeded,
    }
    namespace.update(helper_api.configure(_call_tool, tools))

    user_stdout = CappedTextIO(max_output_bytes)
    user_stderr = CappedTextIO(max_output_bytes)
    error_payload = None
    try:
        compiled = compile(code, "<accio-coding>", "exec")
        with (
            contextlib.redirect_stdout(user_stdout),
            contextlib.redirect_stderr(user_stderr),
        ):
            exec(compiled, namespace, namespace)
        emitted = _json_safe(_emitted_value)
    except BaseException as error:
        emitted = None
        error_payload = {
            "type": type(error).__name__,
            "message": str(error),
            "traceback": "".join(
                traceback.format_exception(type(error), error, error.__traceback__)
            ),
        }

    return {
        "type": "finished",
        "success": error_payload is None,
        "value": emitted,
        "stdout": user_stdout.getvalue(),
        "stderr": user_stderr.getvalue(),
        "error": error_payload,
    }


def main():
    global _channel
    try:
        _channel = ProtocolChannel()
        initial = _receive()
        if initial.get("type") != "execute":
            raise DaemonProtocolError("worker expected an execute message")
        result = _execute(initial)
        _send(result)
        return 0 if result["success"] else 1
    except BaseException as error:
        if _channel is not None:
            try:
                _send(
                    {
                        "type": "finished",
                        "success": False,
                        "value": None,
                        "stdout": "",
                        "stderr": "",
                        "error": {"type": type(error).__name__, "message": str(error)},
                    }
                )
            except BaseException:
                pass
        return 1


if __name__ == "__main__":
    sys.exit(main())
