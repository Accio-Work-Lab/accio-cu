import errno
import unittest

from accio_cu_code.transport import _connection_error_message


class TransportDiagnosticsTests(unittest.TestCase):
    def test_permission_error_explains_command_sandbox_recovery(self):
        error = PermissionError(errno.EPERM, "Operation not permitted")

        message = _connection_error_message("/tmp/accio/daemon.sock", error)

        self.assertIn("Operation not permitted", message)
        self.assertIn("command sandbox", message)
        self.assertIn("Re-run only the accio-computer-use command", message)
        self.assertIn("restarting the daemon will not fix", message)

    def test_connection_refused_keeps_the_general_daemon_message(self):
        error = ConnectionRefusedError(errno.ECONNREFUSED, "Connection refused")

        message = _connection_error_message("/tmp/accio/daemon.sock", error)

        self.assertIn("cannot connect to Accio daemon", message)
        self.assertNotIn("command sandbox", message)


if __name__ == "__main__":
    unittest.main()
