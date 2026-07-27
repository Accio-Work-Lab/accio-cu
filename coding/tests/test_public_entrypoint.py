from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]


class PublicEntrypointTests(unittest.TestCase):
    def test_installer_exposes_only_accio_computer_use(self):
        installer = (REPO_ROOT / "scripts" / "install-macos.sh").read_text()

        self.assertNotIn('CODING_TARGET_PATH=', installer)
        self.assertNotIn('ln -sf "$CODING_BINARY"', installer)
        self.assertIn('LEGACY_CODE_COMMAND_PATH=', installer)

    def test_internal_runner_is_not_a_second_product_command(self):
        self.assertFalse((REPO_ROOT / "coding" / "accio-cu-code").exists())
        self.assertTrue((REPO_ROOT / "coding" / "runner.py").is_file())

    def test_installer_verifies_coding_mode_by_path_and_command_name(self):
        installer = (REPO_ROOT / "scripts" / "install-macos.sh").read_text()

        self.assertIn('"$TARGET_PATH" code --version', installer)
        self.assertIn(
            'env PATH="$INSTALL_DIR:$PATH" "$BINARY_NAME" code --version',
            installer,
        )

    def test_skill_teaches_the_unified_hybrid_entrypoints(self):
        skill = (REPO_ROOT / "Skills" / "accio-computer-use" / "SKILL.md").read_text()

        self.assertIn("`accio-computer-use` is the only public executable", skill)
        self.assertIn("`accio-computer-use code mcp`", skill)
        self.assertIn("runtime infrastructure, not a Codex MCP registration", skill)
        self.assertIn('ACCIO_CLI="$(command -v accio-computer-use)"', skill)
        self.assertIn('[Errno 1] Operation not permitted', skill)
        self.assertIn('sandbox_permissions: "require_escalated"', skill)
        self.assertIn("`accio-computer-use daemon-status`", skill)
        self.assertIn("daemon-health evidence", skill)
        self.assertNotIn("`accio-cu-code`", skill)

    def test_daemon_scripts_verify_live_health(self):
        daemon_installer = (REPO_ROOT / "scripts" / "install-daemon.sh").read_text()
        app_installer = (REPO_ROOT / "scripts" / "install-macos.sh").read_text()

        self.assertIn('daemon-status "$SOCKET_PATH"', daemon_installer)
        self.assertIn("Status: loaded but unhealthy", daemon_installer)
        self.assertIn("DAEMON_RESTART_HEALTHY", app_installer)
        self.assertIn('"$REPO_ROOT/scripts/install-daemon.sh" status', app_installer)

    def test_scroll_skill_prefers_precise_filtering_and_visual_recovery(self):
        skill = (
            REPO_ROOT
            / "Skills"
            / "accio-computer-use"
            / "interaction-skills"
            / "scrolling-and-dragging.md"
        ).read_text()

        self.assertIn("exact off-screen target text", skill)
        self.assertIn("Treat `changed=none` as inconclusive for scrolling", skill)
        self.assertIn("screenshot confirms no movement", skill)


if __name__ == "__main__":
    unittest.main()
