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
        self.assertNotIn("`accio-cu-code`", skill)


if __name__ == "__main__":
    unittest.main()
