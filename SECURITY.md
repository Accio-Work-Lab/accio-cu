# Security Policy

Accio Computer Use is a high-privilege local automation tool. It can receive
Accessibility and Screen Recording access, inject input, capture interface
state, and run explicitly enabled Python coding blocks with the current user's
filesystem, environment, network, and session permissions.

## Supported versions

Security fixes are provided for the latest release on the `main` branch.

## Reporting a vulnerability

Do not open a public issue for a vulnerability or attach screenshots, logs,
traces, credentials, or private application data to a public report.

Use GitHub's private vulnerability reporting for this repository:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Include the affected version, impact, reproduction steps, and a minimal
   proof of concept with sensitive values removed.

The maintainers will acknowledge a report within five business days and will
coordinate disclosure after a fix is available.

## Trust boundaries

- The daemon socket is a same-user boundary. Other processes running as the
  same macOS user may be able to reach it.
- Coding mode is not a sandbox. Enable `code mcp` only for trusted clients and
  trusted code. Use a dedicated macOS account or isolated VM for untrusted
  agents.
- Screen images, accessibility state, logs, and traces may contain sensitive
  data. Treat all generated artifacts as private.
- Some background input routes use unsupported Apple SkyLight APIs. They may
  stop working or behave differently after macOS updates.
- The source installer uses ad-hoc signing by default. For a stable macOS TCC
  identity across rebuilds, use the same persistent signing identity.

## Safe deployment defaults

- Keep the coding MCP disabled unless it is explicitly needed.
- Install the daemon only in a dedicated, trusted user session.
- Review every MCP client's tool-approval policy.
- Pause automation from the Accio menu bar before handling sensitive UI.
- Do not expose daemon or MCP transports to a network.
