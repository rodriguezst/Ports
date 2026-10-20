# Ports

Ports is a native macOS menu bar app for SSH local port forwarding. Enable a connection with one click; Ports keeps it connected through network interruptions and sleep.

Requires **macOS 13 or later**. Built with SwiftUI, AppKit, and the system `/usr/bin/ssh`, with no third-party dependencies.

## Build and run

On a Mac with Xcode or the Xcode Command Line Tools installed:

```sh
swift test
./scripts/build-app.sh
open build/Ports.app
```

The script builds a release executable, creates the app icon and `build/Ports.app`, and ad-hoc signs and verifies the bundle. You can copy `Ports.app` to `/Applications`. To create a universal app for Apple Silicon and Intel:

```sh
./scripts/build-app.sh --universal
```

Open `Package.swift` in Xcode to develop the app, or use `swift run Ports` on macOS. The bundled app is the recommended way to use saved Keychain credentials.

## GitHub Actions builds

[`.github/workflows/macos.yml`](.github/workflows/macos.yml) runs on pushes, pull requests, and manual dispatch. It tests and builds on macOS 15 runners for both Apple Silicon (`arm64`) and Intel (`x86_64`), checks the app metadata, architecture and signature, and uploads:

- `Ports-macOS-arm64` containing `Ports-macOS-arm64.zip`
- `Ports-macOS-x86_64` containing `Ports-macOS-x86_64.zip`

After pushing this project to GitHub, open **Actions → Build Ports for macOS → a successful run → Artifacts**. Download the artifact for your Mac, extract the artifact and app ZIP, and move `Ports.app` to Applications. The inner ZIP preserves app bundle permissions.

These builds are ad-hoc signed development builds, without notarization. For distribution, sign with your Developer ID and notarize using Apple's tools; `CODESIGN_IDENTITY` can select an installed signing certificate when running the build script. macOS may require you to allow a downloaded development build in System Settings → Privacy & Security.

The macOS UI and bundle must be compiled on macOS. The forwarding engine and its tests can also be compiled on Linux with `swift test`; process tests use `/usr/bin/python3` for one subprocess fixture.

## Use Ports

1. Launch Ports. Its arrow icon appears in the menu bar, and Settings opens on the first launch.
2. Add a forwarding and configure its label, local bind address and port, SSH host, SSH port, username and authentication, and destination address and port.
3. Verify the SSH host key. By default, the host must already be trusted in `~/.ssh/known_hosts`. **Copy Host Verification Command** gives you a command to run in Terminal to review and accept the fingerprint. You can instead explicitly select **Trust new hosts on first connection**. Both policies reject changed host keys.
4. Enable the forwarding in Settings or click it in the menu bar. A **tick means enabled**, including while it is connecting, retrying, or waiting for the network. The adjacent status shows whether the tunnel is connected.
5. Uncheck it to stop the tunnel and cancel retries. **Settings…** opens the configuration UI; **Quit Ports** stops all SSH processes while preserving your enabled choices for the next launch.

For example, forwarding `127.0.0.1:15432` through `deploy@bastion.example.com:22` to `db.internal:5432` lets local applications access the remote database at `127.0.0.1:15432`. The destination address is resolved by the SSH host; destination `localhost` refers to that remote host.

Bind to `127.0.0.1` or `::1` for access from your Mac. Binding to `0.0.0.0`, `::`, or a LAN interface makes the local listener accessible on those interfaces. IPv4 and IPv6 addresses are supported. Ports reports listener binding errors and prevents enabled entries with obviously overlapping local listeners.

## Authentication and storage

- **SSH agent / default keys** uses the agent available to the app and standard SSH key files. For encrypted keys, load them into your agent with `ssh-add` first.
- **Private key** uses your selected key file and an optional passphrase saved in Keychain. A path beginning with `~/` is supported. Leave the passphrase blank when editing to retain it, or use **Remove saved passphrase**.
- **Password** stores the SSH password in macOS Keychain. Leave it blank when editing to retain the existing password. This mode uses SSH password authentication; interactive MFA and keyboard-interactive authentication are not supported.

Passwords and passphrases are separate Keychain entries per forwarding and authentication type. OpenSSH retrieves them through Ports' askpass helper mode. Secrets are never written into the JSON configuration, command arguments, or environment variables. The app and helper use the same executable. Keychain may ask for access permission, especially after rebuilding or changing the code signature.

Connection settings and enabled flags are saved atomically to:

```text
~/Library/Application Support/Ports/forwardings.json
```

The file is readable only by its owner. An unreadable or unsupported configuration is preserved, and editing is blocked until you repair or move it and choose **Reload Configuration**. Deleting a forwarding also removes its saved credentials. Private key files stay at their original locations.

Ports supplies connection options directly and uses `-F /dev/null`, so `~/.ssh/config` host aliases, proxy commands, and extra forwarding directives are not loaded. Enter an actual hostname/IP address and SSH username. Standard `known_hosts` files are still used for host verification. The app runs outside the App Sandbox so it can launch OpenSSH and read the selected key.

## Reconnection behavior

Each forwarding has independent desired state, SSH process, status, timeout, and retry timer. Enabled entries are restored when Ports starts; Ports must be running to maintain them. It does not install a login item.

- Network path changes and Mac wake trigger reconnection. Offline or sleeping connections remain enabled without repeatedly launching SSH.
- SSH keepalives run every 15 seconds and disconnect an unresponsive session after three unanswered probes (approximately 45 seconds). This also catches failures when macOS still considers the network available.
- Unexpected exits, authentication failures, and occupied local ports retry after 1, 2, 4, 8, 16, then at most 30 seconds. A connection that stays up for 60 seconds resets the backoff.
- Connecting has a 45-second deadline. Reconnects wait for the old SSH process to exit before starting a replacement, and a stuck process is forcibly stopped after two seconds.
- Disabling or deleting a connection cancels all retries. Sleep suspends connections. Quitting waits for active and recently removed SSH processes to stop.

**Connected** means SSH authenticated and established the local listener. It does not imply that the destination service is healthy; a remote database or HTTP server can be unavailable while its SSH tunnel remains connected. The latest SSH failure is shown in Settings when a connection is retrying.

## Project layout and validation

- `Sources/Ports`: menu bar, settings/editor, network and sleep integration, Keychain and askpass.
- `Sources/PortsCore`: configuration validation and persistence, SSH command construction, process supervision and retry scheduling.
- `Tests/PortsCoreTests`: deterministic network/retry/lifecycle tests, real subprocess output and termination tests, configuration and SSH argument tests.
- `scripts/build-app.sh`: release app packaging and signing.

For a manual macOS check, add a forwarding to an SSH host you control, verify data reaches the destination, disconnect/reconnect Wi-Fi, sleep/wake your Mac, disable an entry while it is retrying, edit an enabled entry, and quit/reopen Ports. Confirm ticks persist through outages, disabled entries stay stopped, and no listener remains after quitting.

Implementation references: [Apple NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem), [OpenSSH client](https://man.openbsd.org/ssh.1), [OpenSSH connection options](https://man.openbsd.org/ssh_config.5), and [GitHub's macOS runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
