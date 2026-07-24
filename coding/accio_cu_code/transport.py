import json
import os
import socket
import stat
import struct
import time

from .errors import (
    DaemonProtocolError,
    DaemonUnavailableError,
    ResponseTooLargeError,
)


def default_socket_path():
    return "/tmp/accio-computer-use-%d/daemon.sock" % os.getuid()


class DaemonTransport:
    """One JSON-RPC request per Unix socket connection.

    This deliberately mirrors the existing Swift DaemonClient contract. It
    never falls back to in-process ComputerUseService execution.
    """

    def __init__(self, socket_path, timeout=45.0, max_response_bytes=32 * 1024 * 1024):
        self.socket_path = socket_path
        self.timeout = timeout
        self.max_response_bytes = max_response_bytes
        self._next_id = 1

    def list_tools(self, timeout=None):
        result = self.request("tools/list", {}, timeout=timeout)
        tools = result.get("tools")
        if not isinstance(tools, list):
            raise DaemonProtocolError("tools/list response is missing a tools array")
        return tools

    def call_tool(self, name, arguments, timeout=None):
        return self.request(
            "tools/call", {"name": name, "arguments": arguments}, timeout=timeout
        )

    def request(self, method, params, timeout=None):
        operation_timeout = (
            self.timeout if timeout is None else min(self.timeout, timeout)
        )
        deadline = time.monotonic() + operation_timeout
        request_id = self._next_id
        self._next_id += 1
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }
        payload = (
            json.dumps(request, separators=(",", ":"), allow_nan=False) + "\n"
        ).encode("utf-8")

        self._validate_socket_path()
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(_remaining(deadline))
        try:
            try:
                connection.connect(self.socket_path)
            except (
                FileNotFoundError,
                ConnectionRefusedError,
                PermissionError,
                socket.timeout,
                OSError,
            ) as error:
                raise DaemonUnavailableError(
                    "cannot connect to Accio daemon at %s: %s"
                    % (self.socket_path, error)
                )
            self._validate_peer(connection)
            connection.settimeout(_remaining(deadline))
            connection.sendall(payload)
            connection.shutdown(socket.SHUT_WR)
            response_bytes = self._read_response(connection, deadline)
        except socket.timeout:
            raise DaemonUnavailableError(
                "Accio daemon timed out after %.3f seconds" % operation_timeout
            )
        finally:
            connection.close()

        try:
            response_text = response_bytes.decode("utf-8")
            response_line = next(
                line for line in response_text.splitlines() if line.strip()
            )
            response = json.loads(response_line)
        except (UnicodeDecodeError, ValueError, StopIteration) as error:
            raise DaemonProtocolError("invalid JSON-RPC response: %s" % error)

        if not isinstance(response, dict):
            raise DaemonProtocolError("JSON-RPC response must be an object")
        if response.get("id") != request_id:
            raise DaemonProtocolError("JSON-RPC response id does not match request")
        if "error" in response:
            error = response.get("error") or {}
            raise DaemonProtocolError(
                str(error.get("message", "daemon returned an RPC error"))
            )
        result = response.get("result")
        if not isinstance(result, dict):
            raise DaemonProtocolError("JSON-RPC response is missing an object result")
        return result

    def _read_response(self, connection, deadline):
        response = bytearray()
        while True:
            connection.settimeout(_remaining(deadline))
            chunk = connection.recv(65536)
            if not chunk:
                break
            response.extend(chunk)
            if len(response) > self.max_response_bytes:
                raise ResponseTooLargeError(
                    "daemon response exceeded %d bytes" % self.max_response_bytes
                )
        if not response:
            raise DaemonProtocolError("daemon closed the connection without a response")
        return bytes(response)

    def _validate_socket_path(self):
        try:
            metadata = os.lstat(self.socket_path)
        except FileNotFoundError as error:
            raise DaemonUnavailableError(
                "Accio daemon socket does not exist at %s" % self.socket_path
            ) from error
        if not stat.S_ISSOCK(metadata.st_mode):
            raise DaemonUnavailableError("daemon path is not a Unix socket")
        if metadata.st_uid != os.getuid():
            raise DaemonUnavailableError(
                "daemon socket is not owned by the current user"
            )
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise DaemonUnavailableError(
                "daemon socket permissions must be 0600 or stricter"
            )

    @staticmethod
    def _validate_peer(connection):
        if hasattr(connection, "getpeereid"):
            peer_uid, _ = connection.getpeereid()
        elif hasattr(socket, "LOCAL_PEERCRED"):
            credentials = connection.getsockopt(0, socket.LOCAL_PEERCRED, 8)
            _, peer_uid = struct.unpack("II", credentials)
        elif hasattr(socket, "SO_PEERCRED"):
            credentials = connection.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
            )
            _, peer_uid, _ = struct.unpack("3i", credentials)
        else:
            raise DaemonUnavailableError("platform cannot authenticate the daemon peer")
        if peer_uid != os.getuid():
            raise DaemonUnavailableError("daemon peer is not the current user")


def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise socket.timeout()
    return remaining
