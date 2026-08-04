import Foundation
import Testing

@Test("installer defaults to persistent local signing and keeps adhoc explicit")
func installerDefaultsToLocalSigning() throws {
    let installerURL = repositoryRoot().appendingPathComponent("scripts/install-macos.sh")
    let installer = try String(contentsOf: installerURL, encoding: .utf8)

    #expect(installer.contains("SIGNING_MODE=\"${ACCIO_SIGNING_MODE:-local}\""))
    #expect(installer.contains("accio_ensure_local_signing_identity"))
    #expect(installer.contains("--signing-mode MODE"))
    #expect(installer.contains("SIGNING_IDENTITY=\"-\""))

    let policyURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let policy = try String(contentsOf: policyURL, encoding: .utf8)
    #expect(policy.contains("security add-trusted-cert -r trustRoot -p codeSign"))
    #expect(!policy.contains("security add-trusted-cert -d -r trustRoot"))
    #expect(policy.contains("AccioComputerUseLocal.keychain-db"))
    #expect(policy.contains("signing-keychain-password"))
    #expect(policy.contains("accio_add_keychain_to_user_search_list"))
    #expect(policy.contains("security set-key-partition-list"))
    #expect(policy.contains("apple-tool:,apple:,codesign:"))
    #expect(!policy.contains("security import \"$archive\" -A"))
}

@Test("first-run onboarding is resumable and precedes daemon installation")
func firstRunOnboardingIsResumable() throws {
    let installerURL = repositoryRoot().appendingPathComponent("scripts/install-macos.sh")
    let installer = try String(contentsOf: installerURL, encoding: .utf8)
    let continuation = try #require(installer.range(of: "finish_onboarding()"))
    let functionBody = String(installer[continuation.lowerBound...])
    let permissionWait = try #require(functionBody.range(of: "setup --wait-for-permissions"))
    let daemonInstall = try #require(functionBody.range(
        of: "scripts/install-daemon.sh\" install"
    ))

    #expect(permissionWait.lowerBound < daemonInstall.lowerBound)
    #expect(installer.contains("--continue-install"))
    #expect(installer.contains("--no-onboarding"))
}

@Test("local signing identity selection requires an exact unique name")
func localSigningIdentitySelectionIsExact() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        security() {
          printf '%s\\n' \\
            '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Accio Computer Use Local Development"' \\
            '  2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Accio Computer Use Local Development Extra"' \\
            '     2 valid identities found'
        }
        [[ "$(accio_find_exact_codesigning_identity 'Accio Computer Use Local Development' /tmp/test.keychain)" == \\
           '0123456789ABCDEF0123456789ABCDEF01234567' ]]
        """,
        "bash",
        helperURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "identity selection failed: \(value)")
}

@Test("local signing uses an isolated persistent keychain and preserves the search list")
func localSigningKeychainIsIsolatedAndSearchable() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        test_home="$(mktemp -d '/tmp/accio signing home.XXXXXX')"
        trap 'rm -rf "$test_home"' EXIT
        export HOME="$test_home"
        calls="$test_home/security-calls"
        private_dir="$test_home/Library/Application Support/AccioComputerUse"
        mkdir -p "$private_dir"
        chmod 755 "$private_dir"
        security() {
          printf '%s\n' "$*" >> "$calls"
          case "$1 $2" in
            'create-keychain -p')
              mkdir -p "$(dirname "${@: -1}")"
              touch "${@: -1}"
              ;;
            'list-keychains -d')
              if [[ "$4" == -s ]]; then
                touch "$test_home/search-list-contains-accio"
              elif [[ -f "$test_home/search-list-contains-accio" ]]; then
                printf '    "%s"\n    "%s"\n' \
                  "$test_home/Library/Keychains/login.keychain-db" \
                  "$test_home/Library/Keychains/AccioComputerUseLocal.keychain-db"
              else
                printf '    "%s"\n' "$test_home/Library/Keychains/login.keychain-db"
              fi
              ;;
            'unlock-keychain -p') ;;
            *) return 64 ;;
          esac
        }

        keychain="$(accio_prepare_local_signing_keychain)"
        [[ "$keychain" == "$test_home/Library/Keychains/AccioComputerUseLocal.keychain-db" ]]
        [[ -f "$keychain" ]]
        password_file="$test_home/Library/Application Support/AccioComputerUse/signing-keychain-password"
        [[ -s "$password_file" ]]
        [[ "$(stat -f '%Lp' "$password_file")" == 600 ]]
        [[ "$(stat -f '%Lp' "$private_dir")" == 700 ]]
        grep -Fq "list-keychains -d user -s $test_home/Library/Keychains/login.keychain-db $keychain" "$calls"

        before="$(wc -l < "$calls")"
        keychain_again="$(accio_prepare_local_signing_keychain)"
        after="$(wc -l < "$calls")"
        [[ "$keychain_again" == "$keychain" ]]
        [[ "$((after - before))" -eq 2 ]]
        """,
        "bash",
        helperURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "local signing keychain setup failed: \(value)")
}

@Test("local signing refuses a symlinked private support directory")
func localSigningRejectsSymlinkedPrivateDirectory() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        test_root="$(mktemp -d /tmp/accio-private-directory.XXXXXX)"
        trap 'rm -rf "$test_root"' EXIT
        mkdir "$test_root/target"
        ln -s "$test_root/target" "$test_root/private"
        ! accio_prepare_private_directory "$test_root/private"
        """,
        "bash",
        helperURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "unsafe private directory was accepted: \(value)")
}

@Test("existing local signing keys receive non-interactive codesign access")
func existingLocalSigningKeyAccessIsRepaired() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        accio_default_keychain_path() { return 1; }
        accio_prepare_local_signing_keychain() { printf '/tmp/AccioComputerUseLocal.keychain-db\n'; }
        accio_local_signing_keychain_password() { printf 'test-password\n'; }
        accio_find_exact_codesigning_identity() { printf '0123456789ABCDEF0123456789ABCDEF01234567\n'; }
        security() { printf '%s\n' "$*" >> "$calls"; }

        calls="$(mktemp /tmp/accio-key-access.XXXXXX)"
        trap 'rm -f "$calls"' EXIT
        hash="$(accio_ensure_local_signing_identity 'Accio Computer Use Local Development')"
        [[ "$hash" == 0123456789ABCDEF0123456789ABCDEF01234567 ]]
        grep -Fxq \
          'set-key-partition-list -S apple-tool:,apple:,codesign: -s -k test-password /tmp/AccioComputerUseLocal.keychain-db' \
          "$calls"
        """,
        "bash",
        helperURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "codesign key access repair failed: \(value)")
}

@Test("TCC resets only when the signing requirement changes or reset is explicit")
func signingPlanProtectsPermissionIdentity() throws {
    #expect(try signingPlan(
        identity: "-",
        explicitReset: false,
        previousRequirement: "",
        newRequirement: "designated => cdhash NEW"
    ) == "adhoc|reset")
    #expect(try signingPlan(
        identity: "-",
        explicitReset: false,
        previousRequirement: "designated => cdhash OLD",
        newRequirement: "designated => cdhash NEW"
    ) == "adhoc|reset")
    #expect(try signingPlan(
        identity: "Developer ID Application: Example Team (ABCDE12345)",
        explicitReset: false,
        previousRequirement: "designated => anchor apple generic and identifier com.accio.computeruse",
        newRequirement: "designated => anchor apple generic and identifier com.accio.computeruse"
    ) == "stable|preserve")
    #expect(try signingPlan(
        identity: "Developer ID Application: Example Team (ABCDE12345)",
        explicitReset: false,
        previousRequirement: "designated => anchor OLD and identifier com.accio.computeruse",
        newRequirement: "designated => anchor NEW and identifier com.accio.computeruse"
    ) == "stable|reset")
    #expect(try signingPlan(
        identity: "Developer ID Application: Example Team (ABCDE12345)",
        explicitReset: true,
        previousRequirement: "designated => anchor SAME and identifier com.accio.computeruse",
        newRequirement: "designated => anchor SAME and identifier com.accio.computeruse"
    ) == "stable|reset")
}

@Test("daemon onboarding is entered only for the permission-pending exit code")
func daemonFailureRoutingIsSpecific() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        [[ "$(accio_daemon_reinstall_failure_action 2 false)" == onboard ]]
        [[ "$(accio_daemon_reinstall_failure_action 2 true)" == permission-pending ]]
        [[ "$(accio_daemon_reinstall_failure_action 1 false)" == fail ]]
        [[ "$(accio_daemon_reinstall_failure_action 78 false)" == fail ]]
        """,
        "bash",
        helperURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "daemon failure routing failed: \(value)")
}

@Test("LaunchAgent permission exits are propagated to installer onboarding")
func launchAgentPermissionExitIsPropagated() throws {
    let daemonInstaller = try String(
        contentsOf: repositoryRoot().appendingPathComponent("scripts/install-daemon.sh"),
        encoding: .utf8
    )
    let main = try String(
        contentsOf: repositoryRoot().appendingPathComponent(
            "apps/AccioComputerUse/Sources/AccioComputerUse/AccioComputerUseMain.swift"
        ),
        encoding: .utf8
    )

    #expect(daemonInstaller.contains("launch_agent_last_exit_code"))
    #expect(daemonInstaller.contains("[[ \"$last_exit\" == \"2\" ]]"))
    #expect(daemonInstaller.contains("health_status=2"))
    #expect(daemonInstaller.contains("launchctl bootout \"gui/$(id -u)/$LABEL\""))
    #expect(daemonInstaller.contains("rm -f \"$SOCKET_PATH\" \"$PLIST_PATH\""))
    #expect(main.contains("catch let error as DaemonStartupError"))
    #expect(main.contains("exit(error.exitCode)"))
}

@Test("verification checks daemon only when installation owns its running state")
func verificationRespectsDaemonInstallScope() throws {
    let installer = try String(
        contentsOf: repositoryRoot().appendingPathComponent("scripts/install-macos.sh"),
        encoding: .utf8
    )

    #expect(installer.contains("$NO_ONBOARDING\" != true && ! -f \"$DAEMON_PLIST\""))
    #expect(!installer.contains("! -f \"$DAEMON_PLIST\" || \"$VERIFY\" == true"))
    #expect(installer.contains("Opening the Accio app permission window"))
    let verifyBlock = try #require(installer.range(of: "if [[ \"$VERIFY\" == true ]]"))
    let verifyBody = String(installer[verifyBlock.lowerBound...])
    #expect(verifyBody.contains("Running persistent daemon health check..."))
    #expect(verifyBody.contains(
        "if [[ \"$REINSTALL_DAEMON\" == true || \"$ONBOARDING_COMPLETED\" == true ]]"
    ))
    #expect(verifyBody.contains(
        "Skipping persistent daemon health check: --no-onboarding did not request daemon installation."
    ))
    #expect(verifyBody.contains(
        "Skipping persistent daemon health check: the LaunchAgent was intentionally unloaded before installation."
    ))
}

@Test("TCC reset helper touches only Accio Accessibility and Screen Recording grants")
func tccResetIsScopedToExpectedServices() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        "source \"$1\"; accio_tccutil() { printf '%s\\n' \"$*\"; }; accio_reset_scoped_tcc_permissions \"$2\"",
        "bash",
        helperURL.path,
        "com.accio.computeruse",
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(process.terminationStatus == 0, "TCC reset helper failed: \(value)")
    #expect(value.split(separator: "\n").map(String.init) == [
        "reset Accessibility com.accio.computeruse",
        "reset ScreenCapture com.accio.computeruse",
    ])
}

@Test("LaunchAgent shutdown is verified and fails closed")
func launchAgentShutdownIsStateAware() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        loaded=true
        fail_bootout=false
        accio_current_uid() { printf '501\\n'; }
        accio_launchctl() {
          case "$1" in
            print) [[ "$loaded" == true ]] ;;
            bootout)
              [[ "$fail_bootout" == false ]] || return 1
              loaded=false
              ;;
            *) return 64 ;;
          esac
        }
        accio_stop_loaded_launch_agent com.accio.computeruse.daemon
        [[ "$loaded" == false ]]
        loaded=true
        fail_bootout=true
        ! accio_stop_loaded_launch_agent com.accio.computeruse.daemon
        [[ "$loaded" == true ]]
        """,
        "bash",
        helperURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "LaunchAgent state guard failed: \(value)")
}

@Test("Uninstall stops Accio and clears its scoped permissions before removing the app")
func uninstallClearsPermissionIdentityBeforeBundleRemoval() throws {
    let installerURL = repositoryRoot().appendingPathComponent("scripts/install-macos.sh")
    let installer = try String(contentsOf: installerURL, encoding: .utf8)
    let uninstallStart = try #require(installer.range(of: "if [[ \"$UNINSTALL\" == true ]]"))
    let uninstallEnd = try #require(installer.range(
        of: "if [[ \"$SKILL_ONLY\" == true ]]",
        range: uninstallStart.upperBound..<installer.endIndex
    ))
    let uninstallBlock = String(installer[uninstallStart.lowerBound..<uninstallEnd.lowerBound])

    let rejectLegacyStandalone = try #require(uninstallBlock.range(
        of: "accio_legacy_standalone_install_exists"
    ))
    let stopProcess = try #require(uninstallBlock.range(of: "quit_running_app_bundle"))
    let resetPermissions = try #require(uninstallBlock.range(
        of: "accio_reset_scoped_tcc_permissions \"$BUNDLE_ID\""
    ))
    let removeBundle = try #require(uninstallBlock.range(of: "rm -rf \"$APP_BUNDLE\""))

    #expect(rejectLegacyStandalone.lowerBound < stopProcess.lowerBound)
    #expect(stopProcess.lowerBound < resetPermissions.lowerBound)
    #expect(resetPermissions.lowerBound < removeBundle.lowerBound)
    #expect(uninstallBlock.contains("[[ -e \"$APP_BUNDLE\" ]] || [[ -L \"$APP_BUNDLE\" ]]"))
}

@Test("Upgrade uses the verified LaunchAgent guard instead of a best-effort bootout")
func upgradeStopsLoadedDaemonFailClosed() throws {
    let installerURL = repositoryRoot().appendingPathComponent("scripts/install-macos.sh")
    let installer = try String(contentsOf: installerURL, encoding: .utf8)
    #expect(installer.contains("if accio_launch_agent_is_loaded \"$DAEMON_LABEL\""))
    #expect(installer.contains("accio_stop_loaded_launch_agent \"$DAEMON_LABEL\""))
    #expect(!installer.contains("launchctl bootout \"gui/$(id -u)/$DAEMON_LABEL\" 2>/dev/null || true"))
    #expect(installer.contains("failed to restore the previously loaded daemon after installation failure"))
}

@Test("Installer revalidates executable identity immediately before TERM")
func installerRevalidatesPIDBeforeTermination() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let helper = try String(contentsOf: helperURL, encoding: .utf8)
    let terminationFunction = try #require(helper.range(of: "accio_terminate_exact_process()"))
    let functionBody = String(helper[terminationFunction.lowerBound...])
    let revalidation = try #require(functionBody.range(of: "accio_pid_matches_expected_executable"))
    let signal = try #require(functionBody.range(of: "kill -TERM"))
    #expect(revalidation.lowerBound < signal.lowerBound)
}

@Test("Installer fails closed when PID identity cannot be revalidated")
func installerRejectsIndeterminatePIDRevalidation() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        accio_exact_process_pids() { printf '4242\\n'; }
        accio_pid_matches_expected_executable() { return 2; }
        kill() { return 90; }
        diagnostic="$(accio_terminate_exact_process /tmp/example 1 1 0 2>&1)"
        status=$?
        [[ "$status" -ne 0 ]]
        [[ "$diagnostic" == *"unable to revalidate executable for PID 4242"* ]]
        """,
        "bash",
        helperURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "indeterminate PID identity was not rejected: \(value)")
}

@Test("Only the canonical app CLI symlink is accepted for a clean uninstall")
func uninstallRejectsExternalAndBrokenCLILinks() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        test_dir="$(mktemp -d /tmp/accio-cli-layout.XXXXXX)"
        trap 'rm -rf "$test_dir"' EXIT
        canonical="$test_dir/app-binary"
        external="$test_dir/external-binary"
        cli="$test_dir/accio-computer-use"
        touch "$canonical" "$external"
        chmod +x "$canonical" "$external"

        ln -s "$canonical" "$cli"
        ! accio_legacy_standalone_install_exists "$cli" "$canonical"

        rm "$cli"
        ln -s "$external" "$cli"
        accio_legacy_standalone_install_exists "$cli" "$canonical"

        rm "$cli" "$external"
        ln "$canonical" "$external"
        ln -s "$external" "$cli"
        accio_legacy_standalone_install_exists "$cli" "$canonical"

        rm "$cli" "$external"
        ln -s "$external" "$cli"
        accio_legacy_standalone_install_exists "$cli" "$canonical"

        rm "$cli" "$canonical"
        touch "$external"
        chmod +x "$external"
        ln -s "$external" "$canonical"
        ln -s "$canonical" "$cli"
        accio_legacy_standalone_install_exists "$cli" "$canonical"
        """,
        "bash",
        helperURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "CLI layout guard failed: \(value)")
}

@Test("persistent signing requirements bind both publisher and bundle identifier")
func persistentSigningRequirementRejectsWeakAnchors() throws {
    #expect(try stableRequirementIsAccepted(
        "designated => identifier \"com.accio.computeruse\" and anchor apple generic and certificate leaf[subject.OU] = TEAMID"
    ))
    #expect(try stableRequirementIsAccepted(
        "designated => identifier \"com.accio.computeruse\" and certificate leaf = H\"0123456789ABCDEF0123456789ABCDEF01234567\""
    ))
    #expect(try stableRequirementIsAccepted(
        "designated => identifier \"com.accio.computeruse\" and certificate root = H\"8d6636f5c33b21ac9125c0a4959ce2bcbf9d44af\""
    ))
    #expect(try stableRequirementIsAccepted(
        "designated => identifier \"com.accio.computeruse\" and anchor = H\"0123456789ABCDEF0123456789ABCDEF01234567\""
    ))
    #expect(!(try stableRequirementIsAccepted(
        "designated => identifier \"com.accio.computeruse\" and certificate root = H\"0123456789ABCDEF\""
    )))
    #expect(!(try stableRequirementIsAccepted(
        "designated => identifier \"com.accio.computeruse\" and anchor trusted"
    )))
    #expect(!(try stableRequirementIsAccepted(
        "designated => identifier \"com.example.impostor\" and anchor apple generic"
    )))
}

@Test("Launch Services registration failures propagate to the installer")
func launchServicesRegistrationFailureIsNotIgnored() throws {
    #expect(try registrationSucceeds(registrar: "/usr/bin/true"))
    #expect(!(try registrationSucceeds(registrar: "/usr/bin/false")))
}

@Test("Installer terminates the exact old app process before replacing its bundle")
func installerStopsExactOldAppProcess() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        """
        source "$1"
        test_dir="$(mktemp -d "/tmp/accio old process.XXXXXX")"
        test_binary="$test_dir/accio-old-process"
        test_symlink="/tmp/accio-old-process-$PPID"
        cp /usr/bin/yes "$test_binary"
        ln -s "$test_binary" "$test_symlink"
        "$test_binary" -psn_0_12345 >/dev/null &
        direct_pid=$!
        "$test_symlink" serve --socket test >/dev/null &
        symlink_pid=$!
        /bin/bash -c 'exec -a "$1" /usr/bin/yes decoy' bash "$test_binary" >/dev/null &
        decoy_pid=$!
        cleanup() {
          kill "$direct_pid" "$symlink_pid" "$decoy_pid" >/dev/null 2>&1 || true
          rm -f "$test_symlink"
          rm -rf "$test_dir"
        }
        trap cleanup EXIT
        accio_terminate_exact_process "$test_binary" 1 20 0.01 "$test_symlink"
        wait "$direct_pid" >/dev/null 2>&1 || true
        wait "$symlink_pid" >/dev/null 2>&1 || true
        ! kill -0 "$direct_pid" >/dev/null 2>&1
        ! kill -0 "$symlink_pid" >/dev/null 2>&1
        kill -0 "$decoy_pid" >/dev/null 2>&1
        """,
        "bash",
        helperURL.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "old app process guard failed: \(value)")
}

@Test("Installer fails closed when old process enumeration is unavailable")
func installerRejectsUnknownOldProcessState() throws {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        "source \"$1\"; accio_process_rows() { return 70; }; ! accio_terminate_exact_process /tmp/example 1 1 0.01",
        "bash",
        helperURL.path,
    ]
    try process.run()
    process.waitUntilExit()

    // The leading ! converts the helper's required failure into script success.
    // If enumeration is mistakenly treated as an empty process list, this fails.
    #expect(process.terminationStatus == 0)
}

private func signingPlan(
    identity: String,
    explicitReset: Bool,
    previousRequirement: String,
    newRequirement: String
) throws -> String {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        "source \"$1\"; accio_signing_plan \"$2\" \"$3\" \"$4\" \"$5\"",
        "bash",
        helperURL.path,
        identity,
        explicitReset ? "true" : "false",
        previousRequirement,
        newRequirement,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let value = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(process.terminationStatus == 0, "signing policy helper failed: \(value)")
    return value
}

private func stableRequirementIsAccepted(_ requirement: String) throws -> Bool {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        "source \"$1\"; accio_validate_stable_requirement \"$2\" \"$3\"",
        "bash",
        helperURL.path,
        requirement,
        "com.accio.computeruse",
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    _ = output.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus == 0
}

private func registrationSucceeds(registrar: String) throws -> Bool {
    let helperURL = repositoryRoot()
        .appendingPathComponent("scripts/lib/install-macos-signing-policy.sh")
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [
        "-c",
        "source \"$1\"; accio_register_app_bundle \"$2\" \"$3\"",
        "bash",
        helperURL.path,
        registrar,
        "/Applications/Accio Computer Use.app",
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    _ = output.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus == 0
}

private func repositoryRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    return url
}
