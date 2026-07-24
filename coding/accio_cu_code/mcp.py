"""Stdio MCP entry point for the Accio Computer Use coding harness."""

import base64
import json
import os
from pathlib import Path
import stat

from . import __version__
from .runner import run_code


PROTOCOL_VERSION = "2026-05-20"
SERVER_NAME = "accio-computer-use"
TOOL_NAME = "execute"
MAX_CODE_BYTES = 1024 * 1024
MAX_REQUEST_BYTES = 8 * 1024 * 1024


TOOL_DEFINITION = {
    "name": TOOL_NAME,
    "title": "Execute Accio computer-use code",
    "description": (
        "Execute one Python coding block with Accio Computer Use helpers preloaded. "
        "The code runs with the server process's filesystem, environment, network, "
        "and user-session access; it is not sandboxed."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "code": {
                "type": "string",
                "minLength": 1,
                "description": "Python source for one disposable coding block.",
            }
        },
        "required": ["code"],
        "additionalProperties": False,
    },
    "annotations": {
        "readOnlyHint": False,
        "destructiveHint": True,
        "idempotentHint": False,
        "openWorldHint": True,
    },
}


class MCPServer:
    def __init__(self, config, runner=run_code):
        self.config = config
        self.runner = runner

    def serve(self, input_stream, output_stream):
        while True:
            line = input_stream.readline(MAX_REQUEST_BYTES + 1)
            if not line:
                return 0
            if len(line) > MAX_REQUEST_BYTES:
                self._drain_line(input_stream, line)
                self._write(
                    output_stream,
                    _rpc_error(None, -32600, "request exceeded the JSONL frame limit"),
                )
                continue

            try:
                message = json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                self._write(output_stream, _rpc_error(None, -32700, "parse error"))
                continue

            response = self._dispatch(message)
            if response is not None:
                self._write(output_stream, response)

    def _dispatch(self, message):
        if not isinstance(message, dict):
            return _rpc_error(None, -32600, "request must be an object")
        request_id = message.get("id")
        if message.get("jsonrpc") != "2.0" or not isinstance(
            message.get("method"), str
        ):
            return _rpc_error(_valid_response_id(request_id), -32600, "invalid request")

        method = message["method"]
        if "id" not in message:
            return self._handle_notification(method)
        if request_id is None or _valid_response_id(request_id) is None:
            return _rpc_error(None, -32600, "request id must be a string or integer")

        try:
            result = self._handle_request(method, message.get("params"))
        except InvalidParams as error:
            return _rpc_error(request_id, -32602, str(error))
        except MethodNotFound:
            return _rpc_error(request_id, -32601, "method not found")
        except Exception:
            return _rpc_error(request_id, -32603, "internal error")
        return {"jsonrpc": "2.0", "id": request_id, "result": result}

    @staticmethod
    def _handle_notification(method):
        if method in {
            "notifications/initialized",
            "notifications/cancelled",
            "notifications/turn-ended",
        }:
            return None
        return None

    def _handle_request(self, method, params):
        if method == "initialize":
            if params is not None and not isinstance(params, dict):
                raise InvalidParams("initialize params must be an object")
            return {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": __version__},
            }
        if method == "ping":
            if params not in (None, {}):
                raise InvalidParams("ping does not accept params")
            return {}
        if method == "tools/list":
            if params not in (None, {}):
                raise InvalidParams("tools/list does not accept params")
            return {"tools": [TOOL_DEFINITION]}
        if method == "tools/call":
            return self._call_tool(params)
        raise MethodNotFound()

    def _call_tool(self, params):
        if not isinstance(params, dict):
            raise InvalidParams("tools/call params must be an object")
        unexpected_params = set(params) - {"name", "arguments", "_meta"}
        if unexpected_params:
            raise InvalidParams("tools/call contains unsupported params")
        if params.get("name") != TOOL_NAME:
            raise InvalidParams("unknown tool")
        arguments = params.get("arguments")
        if not isinstance(arguments, dict):
            raise InvalidParams("tool arguments must be an object")
        if set(arguments) != {"code"}:
            raise InvalidParams("execute accepts only the code argument")
        code = arguments["code"]
        if not isinstance(code, str):
            raise InvalidParams("code must be a string")
        if len(code.encode("utf-8")) > MAX_CODE_BYTES:
            raise InvalidParams("code exceeded %d UTF-8 bytes" % MAX_CODE_BYTES)

        if not code.strip():
            envelope = _error_envelope(
                "EmptyCodeError", "execute requires a non-empty Python coding block"
            )
        else:
            envelope = self.runner(code, self.config)
        return _tool_result(envelope, self.config.max_artifact_bytes)

    @staticmethod
    def _drain_line(input_stream, first_chunk):
        if first_chunk.endswith(b"\n"):
            return
        while True:
            chunk = input_stream.readline(MAX_REQUEST_BYTES + 1)
            if not chunk or chunk.endswith(b"\n"):
                return

    @staticmethod
    def _write(output_stream, response):
        encoded = json.dumps(
            response,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        )
        output_stream.write(encoded + "\n")
        output_stream.flush()


class InvalidParams(Exception):
    pass


class MethodNotFound(Exception):
    pass


def serve(config, input_stream, output_stream):
    return MCPServer(config).serve(input_stream, output_stream)


def _tool_result(envelope, max_artifact_bytes):
    envelope_text = json.dumps(
        envelope,
        ensure_ascii=False,
        separators=(",", ":"),
        allow_nan=False,
    )
    content = [{"type": "text", "text": envelope_text}]
    content.extend(_emitted_images(envelope, max_artifact_bytes))
    return {
        "content": content,
        "structuredContent": envelope,
        "isError": not bool(envelope.get("success")),
    }


def _emitted_images(envelope, max_artifact_bytes):
    artifacts = envelope.get("artifacts")
    if not isinstance(artifacts, dict) or not isinstance(artifacts.get("files"), list):
        return []
    trusted_paths = {path for path in artifacts["files"] if isinstance(path, str)}
    referenced_paths = _collect_strings(envelope.get("value"))
    images = []
    seen = set()
    for path in referenced_paths:
        if path in seen or path not in trusted_paths or not path.lower().endswith(".png"):
            continue
        seen.add(path)
        image_bytes = _read_png(path, max_artifact_bytes)
        if image_bytes is None:
            continue
        images.append(
            {
                "type": "image",
                "mimeType": "image/png",
                "data": base64.b64encode(image_bytes).decode("ascii"),
            }
        )
    return images


def _collect_strings(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        result = []
        for item in value:
            result.extend(_collect_strings(item))
        return result
    if isinstance(value, dict):
        result = []
        for item in value.values():
            result.extend(_collect_strings(item))
        return result
    return []


def _read_png(path, max_bytes):
    descriptor = None
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(str(Path(path)), flags)
        file_stat = os.fstat(descriptor)
        if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_uid != os.getuid():
            return None
        if file_stat.st_size < 8 or file_stat.st_size > max_bytes:
            return None
        data = bytearray()
        while len(data) <= max_bytes:
            chunk = os.read(descriptor, min(1024 * 1024, max_bytes + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        image_bytes = bytes(data)
        if len(image_bytes) > max_bytes or not image_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
            return None
        return image_bytes
    except (OSError, ValueError, TypeError):
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _valid_response_id(value):
    if isinstance(value, bool):
        return None
    if value is None or isinstance(value, (int, str)):
        return value
    return None


def _rpc_error(request_id, code, message):
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": code, "message": message},
    }


def _error_envelope(error_type, message):
    return {
        "schema_version": "accio.coding.v1",
        "success": False,
        "value": None,
        "stdout": "",
        "stderr": "",
        "calls": [],
        "last_result": None,
        "artifacts": {"directory": None, "trace_path": None, "files": []},
        "metrics": {"duration_ms": 0, "tool_calls": 0},
        "error": {"type": error_type, "message": message},
    }
