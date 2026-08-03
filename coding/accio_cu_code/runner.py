from dataclasses import dataclass
import ctypes
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

from .errors import (
    ArgumentValidationError,
    CallBudgetExceeded,
    ExecutionTimeout,
    WorkerProtocolError,
)
from .feedback import build_execution_feedback, is_mutating_tool
from .helpers import validate_runtime_contract
from .trace import TraceRecorder
from .transport import DaemonTransport
from .validation import tool_map, validate_arguments


@dataclass(frozen=True)
class RunnerConfig:
    socket_path: str
    timeout: float = 60.0
    call_timeout: float = 45.0
    max_calls: int = 50
    max_response_bytes: int = 32 * 1024 * 1024
    max_output_bytes: int = 1024 * 1024
    max_artifact_bytes: int = 128 * 1024 * 1024
    max_trace_bytes: int = 64 * 1024 * 1024
    max_memory_bytes: int = 512 * 1024 * 1024
    artifacts_dir: str = None
    python_executable: str = sys.executable
    full_trace: bool = False


@dataclass
class RunState:
    attempted_calls: int = 0


@dataclass
class WorkerHandle:
    process: subprocess.Popen
    channel: object
    stdout_capture: object
    stderr_capture: object
    memory_monitor: object
    working_directory: str


def run_code(code, config):
    started = time.monotonic()
    recorder = None
    handle = None
    state = RunState()
    finished = None
    fatal_error = None
    try:
        transport = DaemonTransport(
            socket_path=config.socket_path,
            timeout=config.call_timeout,
            max_response_bytes=config.max_response_bytes,
        )
        tools = transport.list_tools(timeout=_operation_timeout(config, started))
        tools_by_name = tool_map(tools)
        validate_runtime_contract(tools)
        recorder = TraceRecorder(
            config.artifacts_dir,
            full_results=config.full_trace,
            max_artifact_bytes=config.max_artifact_bytes,
            max_trace_bytes=config.max_trace_bytes,
        )
        handle = _start_worker(code, tools, config)
        finished = _supervise(
            handle,
            transport,
            tools_by_name,
            recorder,
            config,
            state,
            started,
        )
    except BaseException as error:
        fatal_error = {"type": type(error).__name__, "message": str(error)}
    finally:
        if handle is not None:
            _finish_worker(handle, graceful=finished is not None)

    if handle is not None and handle.memory_monitor.exceeded:
        finished = None
        fatal_error = {
            "type": "MemoryBudgetExceeded",
            "message": "coding worker exceeded %d bytes of resident memory"
            % config.max_memory_bytes,
        }

    if finished is not None:
        success = bool(finished["success"])
        value = finished.get("value")
        stdout = _merge_output(finished.get("stdout", ""), handle.stdout_capture.value)
        stderr = _merge_output(finished.get("stderr", ""), handle.stderr_capture.value)
        error = finished.get("error")
    else:
        success = False
        value = None
        stdout = handle.stdout_capture.value if handle is not None else ""
        stderr = handle.stderr_capture.value if handle is not None else ""
        error = fatal_error or {
            "type": "WorkerProtocolError",
            "message": "coding block ended without a result",
        }

    envelope = _envelope(
        success=success,
        value=value,
        stdout=stdout,
        stderr=stderr,
        error=error,
        recorder=recorder,
        state=state,
        started=started,
    )
    if recorder is not None:
        recorder.close()
    return envelope


def _start_worker(code, tools, config):
    worker_path = Path(__file__).with_name("worker.py")
    parent_socket, child_socket = socket.socketpair()
    protocol_max_bytes = max(
        4 * 1024 * 1024,
        config.max_response_bytes + config.max_output_bytes + 2 * 1024 * 1024,
    )
    working_directory = os.getcwd()
    environment = os.environ.copy()
    environment.update(
        {
            "ACCIO_PROTOCOL_FD": str(child_socket.fileno()),
            "ACCIO_PROTOCOL_MAX_BYTES": str(protocol_max_bytes),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    command = [config.python_executable, "-u", str(worker_path)]
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False,
            close_fds=True,
            pass_fds=(child_socket.fileno(),),
            cwd=working_directory,
            env=environment,
            start_new_session=True,
        )
    except BaseException:
        parent_socket.close()
        child_socket.close()
        raise
    child_socket.close()
    channel = ProtocolChannel(parent_socket, protocol_max_bytes)
    stdout_capture = StreamCollector(process.stdout, config.max_output_bytes)
    stderr_capture = StreamCollector(process.stderr, config.max_output_bytes)
    memory_monitor = ProcessMemoryMonitor(process, config.max_memory_bytes)
    stdout_capture.start()
    stderr_capture.start()
    memory_monitor.start()
    handle = WorkerHandle(
        process=process,
        channel=channel,
        stdout_capture=stdout_capture,
        stderr_capture=stderr_capture,
        memory_monitor=memory_monitor,
        working_directory=working_directory,
    )
    try:
        channel.send(
            {
                "type": "execute",
                "code": code,
                "tools": tools,
                "max_output_bytes": config.max_output_bytes,
                "timeout": config.timeout,
            }
        )
    except BaseException:
        _finish_worker(handle, graceful=False)
        raise
    return handle


def _supervise(handle, transport, tools_by_name, recorder, config, state, started):
    while True:
        deadline = started + config.timeout
        try:
            message = handle.channel.receive(deadline)
        except socket.timeout:
            raise ExecutionTimeout(
                "coding block exceeded %.3f seconds" % config.timeout
            )
        if not isinstance(message, dict):
            raise WorkerProtocolError("worker message must be an object")

        message_type = message.get("type")
        if message_type == "call":
            _handle_call(
                message,
                handle.channel,
                transport,
                tools_by_name,
                recorder,
                config,
                state,
                started,
            )
        elif message_type == "finished":
            return _validate_finished_message(message, config.max_output_bytes)
        else:
            raise WorkerProtocolError("unknown worker message type: %r" % message_type)


def _handle_call(
    message,
    channel,
    transport,
    tools_by_name,
    recorder,
    config,
    state,
    started,
):
    request_id = message.get("id")
    tool_name = message.get("tool")
    arguments = message.get("arguments")
    if not isinstance(request_id, int):
        raise WorkerProtocolError("tool call id must be an integer")
    if state.attempted_calls >= config.max_calls:
        _send_call_error(
            channel,
            request_id,
            CallBudgetExceeded(
                "coding block exceeded the %d tool-call budget" % config.max_calls
            ),
        )
        return

    state.attempted_calls += 1
    call_index = state.attempted_calls
    call_started = time.monotonic()
    kind = "INVALID"
    is_mutation = False
    try:
        if not isinstance(tool_name, str) or tool_name not in tools_by_name:
            raise ArgumentValidationError("unknown tool: %r" % tool_name)
        tool = tools_by_name[tool_name]
        is_mutation = is_mutating_tool(tool)
        kind = "GUI_ACTION" if is_mutation else "OBSERVE"
        validate_arguments(tool, arguments)
        raw_result = transport.call_tool(
            tool_name,
            arguments,
            timeout=_operation_timeout(config, started),
        )
        result, artifact_paths = recorder.process_result(raw_result, call_index)
        duration_ms = round((time.monotonic() - call_started) * 1000)
        recorder.record_call(
            index=call_index,
            kind=kind,
            tool=tool_name,
            arguments=arguments,
            duration_ms=duration_ms,
            is_mutation=is_mutation,
            result=result,
            artifact_paths=artifact_paths,
        )
        channel.send({"type": "call_result", "id": request_id, "result": result})
    except BaseException as error:
        duration_ms = round((time.monotonic() - call_started) * 1000)
        error_payload = {"type": type(error).__name__, "message": str(error)}
        try:
            recorder.record_call(
                index=call_index,
                kind=kind,
                tool=tool_name if isinstance(tool_name, str) else repr(tool_name),
                arguments=arguments,
                duration_ms=duration_ms,
                is_mutation=is_mutation,
                error=error_payload,
            )
        except BaseException:
            pass
        _send_call_error(channel, request_id, error)


def _send_call_error(channel, request_id, error):
    channel.send(
        {
            "type": "call_error",
            "id": request_id,
            "error": {"type": type(error).__name__, "message": str(error)},
        }
    )


def _operation_timeout(config, started):
    remaining = config.timeout - (time.monotonic() - started)
    if remaining <= 0:
        raise ExecutionTimeout("coding block exceeded %.3f seconds" % config.timeout)
    return min(config.call_timeout, remaining)


def _validate_finished_message(message, max_output_bytes):
    if not isinstance(message.get("success"), bool):
        raise WorkerProtocolError("finished.success must be boolean")
    for key in ("stdout", "stderr"):
        value = message.get(key)
        if not isinstance(value, str):
            raise WorkerProtocolError("finished.%s must be a string" % key)
        if len(value.encode("utf-8")) > max_output_bytes + 128:
            raise WorkerProtocolError("finished.%s exceeds its output limit" % key)
    error = message.get("error")
    if error is not None and not isinstance(error, dict):
        raise WorkerProtocolError("finished.error must be an object or null")
    _validate_finished_payload_size(
        "value", message.get("value"), max_output_bytes + 128
    )
    _validate_finished_payload_size("error", error, max_output_bytes + 64 * 1024)
    return message


def _validate_finished_payload_size(name, value, max_bytes):
    try:
        encoded = json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise WorkerProtocolError("finished.%s is not valid JSON: %s" % (name, error))
    if len(encoded) > max_bytes:
        raise WorkerProtocolError("finished.%s exceeds its output limit" % name)


def _finish_worker(handle, graceful):
    handle.channel.close()
    process = handle.process
    if graceful:
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
    _kill_process_group(process)
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)
    handle.stdout_capture.join(timeout=1)
    handle.stderr_capture.join(timeout=1)
    handle.memory_monitor.stop()
    handle.memory_monitor.join(timeout=1)


def _kill_process_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


def _envelope(success, value, stdout, stderr, error, recorder, state, started):
    calls = recorder.calls if recorder is not None else []
    feedback_events = recorder.feedback_events if recorder is not None else []
    artifacts = {
        "directory": str(recorder.directory) if recorder is not None else None,
        "trace_path": str(recorder.trace_path) if recorder is not None else None,
        "files": list(recorder.artifact_paths) if recorder is not None else [],
        "sha256": dict(recorder.artifact_sha256) if recorder is not None else {},
    }
    last_result = None
    for call in reversed(calls):
        if call.get("result_summary") is not None:
            last_result = call["result_summary"]
            break
    return {
        "schema_version": "accio.coding.v1",
        "success": bool(success),
        "value": value,
        "stdout": stdout or "",
        "stderr": stderr or "",
        "calls": calls,
        "last_result": last_result,
        "execution_feedback": build_execution_feedback(feedback_events),
        "artifacts": artifacts,
        "metrics": {
            "duration_ms": round((time.monotonic() - started) * 1000),
            "tool_calls": state.attempted_calls,
        },
        "error": error,
    }


def _merge_output(captured_python, captured_fd):
    return "%s%s" % (captured_fd or "", captured_python or "")


class ProtocolChannel:
    def __init__(self, connection, max_frame_bytes):
        self.connection = connection
        self.max_frame_bytes = max_frame_bytes

    def send(self, message):
        try:
            payload = json.dumps(
                message,
                ensure_ascii=False,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
        except (TypeError, ValueError) as error:
            raise WorkerProtocolError("cannot encode worker message: %s" % error)
        if len(payload) > self.max_frame_bytes:
            raise WorkerProtocolError(
                "worker protocol frame exceeded %d bytes" % self.max_frame_bytes
            )
        self.connection.sendall(struct.pack("!I", len(payload)) + payload)

    def receive(self, deadline):
        header = self._read_exact(4, deadline)
        length = struct.unpack("!I", header)[0]
        if length > self.max_frame_bytes:
            raise WorkerProtocolError(
                "worker protocol frame exceeded %d bytes" % self.max_frame_bytes
            )
        payload = self._read_exact(length, deadline)
        try:
            return json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as error:
            raise WorkerProtocolError("invalid worker JSON: %s" % error)

    def close(self):
        try:
            self.connection.close()
        except OSError:
            pass

    def _read_exact(self, length, deadline):
        chunks = []
        remaining_bytes = length
        while remaining_bytes:
            remaining_time = deadline - time.monotonic()
            if remaining_time <= 0:
                raise socket.timeout()
            self.connection.settimeout(remaining_time)
            chunk = self.connection.recv(remaining_bytes)
            if not chunk:
                raise WorkerProtocolError("coding worker closed its protocol channel")
            chunks.append(chunk)
            remaining_bytes -= len(chunk)
        return b"".join(chunks)


class StreamCollector(threading.Thread):
    def __init__(self, stream, max_bytes):
        super().__init__(daemon=True)
        self.stream = stream
        self.max_bytes = max_bytes
        self._parts = []
        self._size = 0
        self._truncated = False

    @property
    def value(self):
        value = b"".join(self._parts).decode("utf-8", errors="replace")
        if self._truncated:
            value += "\n[fd output truncated]\n"
        return value

    def run(self):
        if self.stream is None:
            return
        while True:
            chunk = self.stream.read(4096)
            if not chunk:
                break
            remaining = max(self.max_bytes - self._size, 0)
            if len(chunk) <= remaining:
                self._parts.append(chunk)
                self._size += len(chunk)
            elif remaining:
                self._parts.append(chunk[:remaining])
                self._size += remaining
                self._truncated = True
            else:
                self._truncated = True


class ProcessMemoryMonitor(threading.Thread):
    def __init__(self, process, max_memory_bytes):
        super().__init__(daemon=True)
        self.process = process
        self.max_memory_bytes = max_memory_bytes
        self.exceeded = False
        self._stop_event = threading.Event()

    def stop(self):
        self._stop_event.set()

    def run(self):
        while not self._stop_event.is_set() and self.process.poll() is None:
            resident = _resident_memory_bytes(self.process.pid)
            if resident is not None and resident > self.max_memory_bytes:
                self.exceeded = True
                _kill_process_group(self.process)
                return
            self._stop_event.wait(0.01)


class _ProcTaskInfo(ctypes.Structure):
    _fields_ = [
        ("virtual_size", ctypes.c_uint64),
        ("resident_size", ctypes.c_uint64),
        ("total_user", ctypes.c_uint64),
        ("total_system", ctypes.c_uint64),
        ("threads_user", ctypes.c_uint64),
        ("threads_system", ctypes.c_uint64),
        ("policy", ctypes.c_int32),
        ("faults", ctypes.c_int32),
        ("pageins", ctypes.c_int32),
        ("cow_faults", ctypes.c_int32),
        ("messages_sent", ctypes.c_int32),
        ("messages_received", ctypes.c_int32),
        ("syscalls_mach", ctypes.c_int32),
        ("syscalls_unix", ctypes.c_int32),
        ("context_switches", ctypes.c_int32),
        ("thread_count", ctypes.c_int32),
        ("running_threads", ctypes.c_int32),
        ("priority", ctypes.c_int32),
    ]


try:
    _LIBPROC = (
        ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        if sys.platform == "darwin"
        else None
    )
except OSError:
    _LIBPROC = None


def _resident_memory_bytes(process_id):
    if sys.platform == "darwin" and _LIBPROC is not None:
        try:
            info = _ProcTaskInfo()
            size = ctypes.sizeof(info)
            result = _LIBPROC.proc_pidinfo(process_id, 4, 0, ctypes.byref(info), size)
            return info.resident_size if result == size else None
        except (OSError, AttributeError):
            return None
    if sys.platform.startswith("linux"):
        try:
            fields = Path("/proc/%d/statm" % process_id).read_text().split()
            return int(fields[1]) * os.sysconf("SC_PAGE_SIZE")
        except (OSError, ValueError, IndexError):
            return None
    return None
