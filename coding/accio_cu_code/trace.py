import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import stat
import tempfile

from .action_metadata import validated_action_metadata
from .errors import ArtifactBudgetExceeded, DaemonProtocolError
from .feedback import project_call_feedback


SENSITIVE_ARGUMENTS = {
    "api_key",
    "authorization",
    "credential",
    "password",
    "secret",
    "text",
    "token",
    "value",
}


class TraceRecorder:
    def __init__(
        self,
        artifacts_dir=None,
        full_results=False,
        max_artifact_bytes=128 * 1024 * 1024,
        max_trace_bytes=64 * 1024 * 1024,
    ):
        base = _prepare_base_directory(artifacts_dir)
        self.directory = Path(tempfile.mkdtemp(prefix="accio-run-", dir=str(base)))
        os.chmod(str(self.directory), 0o700)
        self._directory_fd = os.open(
            str(self.directory),
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
        self.trace_path = self.directory / "trace.jsonl"
        trace_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_APPEND
        trace_flags |= getattr(os, "O_NOFOLLOW", 0)
        self._trace_fd = os.open(
            "trace.jsonl", trace_flags, 0o600, dir_fd=self._directory_fd
        )
        self._trace_bytes = 0
        self._artifact_bytes = 0
        self._redaction_key = os.urandom(32)
        self.full_results = full_results
        self.max_artifact_bytes = max_artifact_bytes
        self.max_trace_bytes = max_trace_bytes
        self.calls = []
        self.artifact_paths = []
        self.artifact_sha256 = {}
        self.feedback_events = []

    def close(self):
        if self._trace_fd is not None:
            os.close(self._trace_fd)
            self._trace_fd = None
        if self._directory_fd is not None:
            os.close(self._directory_fd)
            self._directory_fd = None

    def process_result(self, result, call_index):
        if not isinstance(result, dict):
            raise DaemonProtocolError("tools/call result must be an object")
        content = result.get("content")
        if not isinstance(content, list):
            raise DaemonProtocolError("tools/call result is missing a content array")

        processed_content = []
        call_artifacts = []
        for item_index, item in enumerate(content):
            if not isinstance(item, dict):
                raise DaemonProtocolError("tools/call content item must be an object")
            copied = dict(item)
            if copied.get("type") == "image" and "data" in copied:
                path = self._save_image(copied, call_index, item_index)
                copied.pop("data", None)
                copied["path"] = str(path)
                call_artifacts.append(str(path))
                self.artifact_paths.append(str(path))
            processed_content.append(copied)

        processed = dict(result)
        processed["content"] = processed_content
        processed["isError"] = bool(result.get("isError", False))
        return processed, call_artifacts

    def record_call(
        self,
        index,
        kind,
        tool,
        arguments,
        duration_ms,
        is_mutation=False,
        result=None,
        artifact_paths=None,
        error=None,
    ):
        artifact_paths = list(artifact_paths or [])
        result_summary = (
            summarize_result(result, expected_tool=tool)
            if result is not None
            else None
        )
        success = (
            error is None
            and result is not None
            and not bool(result.get("isError", False))
        )
        redacted_arguments = redact_arguments(arguments, self._redaction_key)
        redacted_arguments = _compact_arguments(redacted_arguments)
        compact_error = _compact_error(error)
        call = {
            "index": index,
            "origin": "MODEL_CODE",
            "kind": kind,
            "mutation": bool(is_mutation),
            "tool": tool,
            "arguments": redacted_arguments,
            "duration_ms": duration_ms,
            "success": success,
            "result_summary": result_summary,
            "artifact_paths": artifact_paths,
            "error": compact_error,
        }
        trace_entry = dict(call)
        if self.full_results and result is not None:
            trace_entry["result"] = result
        try:
            self._write_trace(trace_entry)
        except ArtifactBudgetExceeded:
            if "result" not in trace_entry:
                raise
            trace_entry.pop("result", None)
            trace_entry["full_result_omitted"] = "trace budget exceeded"
            self._write_trace(trace_entry)
        self.calls.append(call)
        self.feedback_events.append(
            project_call_feedback(
                index=index,
                tool=tool,
                is_mutation=is_mutation,
                result=result,
                artifact_paths=artifact_paths,
                error=error,
            )
        )
        return call

    def _write_trace(self, entry):
        encoded = (
            json.dumps(
                entry, ensure_ascii=False, separators=(",", ":"), allow_nan=False
            )
            + "\n"
        ).encode("utf-8")
        if self._trace_bytes + len(encoded) > self.max_trace_bytes:
            raise ArtifactBudgetExceeded(
                "trace exceeded %d bytes" % self.max_trace_bytes
            )
        _write_all(self._trace_fd, encoded)
        self._trace_bytes += len(encoded)

    def _save_image(self, item, call_index, item_index):
        mime_type = item.get("mimeType")
        if mime_type != "image/png":
            raise DaemonProtocolError("unsupported image MIME type: %s" % mime_type)
        try:
            image_bytes = base64.b64decode(item["data"], validate=True)
        except (ValueError, TypeError) as error:
            raise DaemonProtocolError("invalid base64 image: %s" % error)
        if self._artifact_bytes + len(image_bytes) > self.max_artifact_bytes:
            raise ArtifactBudgetExceeded(
                "screenshots exceeded %d bytes" % self.max_artifact_bytes
            )
        filename = "call-%04d-image-%02d.png" % (call_index, item_index + 1)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(filename, flags, 0o600, dir_fd=self._directory_fd)
        try:
            _write_all(descriptor, image_bytes)
        finally:
            os.close(descriptor)
        self._artifact_bytes += len(image_bytes)
        path = self.directory / filename
        self.artifact_sha256[str(path)] = hashlib.sha256(image_bytes).hexdigest()
        return path


def redact_arguments(arguments, redaction_key):
    return _redact_value(arguments, redaction_key, key_name=None)


def _redact_value(value, redaction_key, key_name):
    if key_name is not None and key_name.lower() in SENSITIVE_ARGUMENTS:
        if isinstance(value, str):
            encoded = value.encode("utf-8")
            return {
                "redacted": True,
                "length": len(value),
                "run_hmac_sha256": hmac.new(
                    redaction_key, encoded, hashlib.sha256
                ).hexdigest(),
            }
        return {"redacted": True, "type": type(value).__name__}
    if isinstance(value, dict):
        return {
            str(key): _redact_value(item, redaction_key, str(key))
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_redact_value(item, redaction_key, key_name=None) for item in value]
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    return repr(value)


def summarize_result(result, expected_tool=None):
    text = ""
    for item in result.get("content", []):
        if item.get("type") == "text" and isinstance(item.get("text"), str):
            text = item["text"]
            break
    action = validated_action_metadata(
        (result.get("structuredContent") or {}).get("action"),
        expected_tool=expected_tool,
    )
    action_summary = {
        key: action[key]
        for key in ("route", "changed")
        if isinstance(action.get(key), str)
    }
    return {
        "is_error": bool(result.get("isError", False)),
        "text_chars": len(text),
        "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        **action_summary,
    }


def _compact_arguments(arguments):
    try:
        encoded = json.dumps(
            arguments, ensure_ascii=False, separators=(",", ":"), allow_nan=False
        ).encode("utf-8")
    except (TypeError, ValueError):
        encoded = repr(arguments).encode("utf-8", errors="replace")
    if len(encoded) <= 2048:
        return arguments
    return {
        "truncated": True,
        "json_bytes": len(encoded),
        "sha256": hashlib.sha256(encoded).hexdigest(),
    }


def _compact_error(error):
    if error is None:
        return None
    error_type = str(error.get("type", "CodingError"))[:128]
    message = str(error.get("message", ""))
    if len(message) > 1024:
        message = message[:1024] + "…"
    return {"type": error_type, "message": message}


def _prepare_base_directory(artifacts_dir):
    if artifacts_dir is None:
        return Path(tempfile.gettempdir())
    base = Path(artifacts_dir).expanduser()
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = os.lstat(str(base))
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ValueError("artifacts base must be a real directory")
    if metadata.st_uid != os.getuid():
        raise ValueError("artifacts base must be owned by the current user")
    return base


def _write_all(descriptor, payload):
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise OSError("short write")
        offset += written
