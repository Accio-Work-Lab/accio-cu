import argparse
import json
import math
import sys

from . import __version__
from .runner import RunnerConfig, run_code
from .transport import default_socket_path


MAX_CODE_BYTES = 1024 * 1024


class UsageError(Exception):
    pass


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def positive_float(value):
    try:
        parsed = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be a number")
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return parsed


def positive_int(value):
    try:
        parsed = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be an integer")
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return parsed


def build_parser():
    parser = JSONArgumentParser(
        prog="accio-computer-use code",
        description=(
            "Execute one Python coding block with Accio Computer Use "
            "helpers preloaded. Code is read from stdin, or use the mcp mode."
        ),
    )
    parser.add_argument(
        "mode",
        nargs="?",
        choices=("mcp",),
        help="run the stdio MCP server",
    )
    parser.add_argument(
        "--socket", default=default_socket_path(), help="Accio daemon Unix socket"
    )
    parser.add_argument(
        "--timeout",
        type=positive_float,
        default=60.0,
        help="whole-block timeout in seconds",
    )
    parser.add_argument(
        "--call-timeout",
        type=positive_float,
        default=45.0,
        help="per daemon call timeout in seconds",
    )
    parser.add_argument(
        "--max-calls", type=positive_int, default=50, help="maximum typed helper calls"
    )
    parser.add_argument("--artifacts-dir", help="directory for trace and screenshots")
    parser.add_argument(
        "--max-response-bytes", type=positive_int, default=32 * 1024 * 1024
    )
    parser.add_argument("--max-output-bytes", type=positive_int, default=1024 * 1024)
    parser.add_argument(
        "--max-artifact-bytes", type=positive_int, default=128 * 1024 * 1024
    )
    parser.add_argument(
        "--max-trace-bytes", type=positive_int, default=64 * 1024 * 1024
    )
    parser.add_argument(
        "--max-memory-bytes",
        type=positive_int,
        default=512 * 1024 * 1024,
        help="maximum resident memory for the Python worker (excludes child processes)",
    )
    parser.add_argument(
        "--python",
        default=sys.executable,
        help="Python executable for the disposable worker",
    )
    parser.add_argument(
        "--full-trace",
        action="store_true",
        help="persist full AX result text in trace (may contain sensitive data)",
    )
    parser.add_argument(
        "--pretty", action="store_true", help="pretty-print the result JSON"
    )
    parser.add_argument(
        "--version", action="version", version="%(prog)s " + __version__
    )
    return parser


def main(argv=None):
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    mcp_requested = bool(raw_argv and raw_argv[0] == "mcp")
    try:
        args = build_parser().parse_args(raw_argv)
    except UsageError as error:
        if mcp_requested:
            return _write_mcp_startup_error(str(error))
        return _write_error("UsageError", str(error), 2)

    config_error = _config_error(args)
    if args.mode == "mcp":
        if config_error is not None:
            return _write_mcp_startup_error(config_error)
        config = _runner_config(args)
        from .mcp import serve

        return serve(config, sys.stdin.buffer, sys.stdout)

    code_bytes = sys.stdin.buffer.read(MAX_CODE_BYTES + 1)
    if len(code_bytes) > MAX_CODE_BYTES:
        return _write_error(
            "CodeTooLargeError",
            "stdin code exceeded %d bytes" % MAX_CODE_BYTES,
            2,
            pretty=args.pretty,
        )
    try:
        code = code_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        return _write_error("InvalidUTF8Error", str(error), 2, pretty=args.pretty)
    if not code.strip():
        return _write_error(
            "EmptyCodeError",
            "read a non-empty Python coding block from stdin",
            2,
            pretty=args.pretty,
        )
    if config_error is not None:
        return _write_error(
            "UsageError",
            config_error,
            2,
            pretty=args.pretty,
        )

    config = _runner_config(args)
    envelope = run_code(code, config)
    _write_json(envelope, pretty=args.pretty)
    return 0 if envelope["success"] else 1


def _runner_config(args):
    return RunnerConfig(
        socket_path=args.socket,
        timeout=args.timeout,
        call_timeout=args.call_timeout,
        max_calls=args.max_calls,
        max_response_bytes=args.max_response_bytes,
        max_output_bytes=args.max_output_bytes,
        max_artifact_bytes=args.max_artifact_bytes,
        max_trace_bytes=args.max_trace_bytes,
        max_memory_bytes=args.max_memory_bytes,
        artifacts_dir=args.artifacts_dir,
        python_executable=args.python,
        full_trace=args.full_trace,
    )


def _config_error(args):
    minimum_trace_bytes = args.max_calls * 4096
    if args.max_trace_bytes < minimum_trace_bytes:
        return "--max-trace-bytes must be at least %d for --max-calls=%d" % (
            minimum_trace_bytes,
            args.max_calls,
        )
    return None


def _write_mcp_startup_error(message):
    sys.stderr.write("accio-computer-use code mcp: %s\n" % message)
    sys.stderr.flush()
    return 2


def _write_error(error_type, message, exit_code, pretty=False):
    envelope = {
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
    _write_json(envelope, pretty=pretty)
    return exit_code


def _write_json(value, pretty=False):
    if pretty:
        text = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)
    else:
        text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    sys.exit(main())
