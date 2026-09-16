# TabVPN Privacy Policy

**Last updated:** September 2026

## Data Collection

TabVPN does **not** collect, store, or transmit any personal data.

## What TabVPN Does

- Routes traffic from specific browser tabs through the Tor network to bypass geo-blocking.
- Creates an isolated Firefox Container for VPN tabs with separate cookies and sessions.
- Communicates with a locally installed native application on your computer (`127.0.0.1`) to check the status of a local Tor client and request circuit changes.

## What TabVPN Does NOT Do

- **No analytics or telemetry** — the extension sends no data to the developer or any third-party service.
- **No user accounts** — no registration, login, or subscription required.
- **No remote servers** — the developer does not operate any server infrastructure. All traffic goes through the open Tor network (volunteer-run relays).
- **No data storage** — the extension does not store browsing history, URLs, or any user activity.
- **No tracking** — the extension does not use cookies, fingerprinting, or any tracking mechanism.

## Network Communication

The extension communicates **only** with:

1. **Local native messaging host** (`127.0.0.1`) — a Node.js process on your computer that bridges the extension and the local Tor client. This communication never leaves your machine.
2. **The Tor network** — when you choose to open a link with VPN, that tab's traffic is routed through the Tor network. This is the intended and only purpose of the extension.

## Permissions

All requested permissions are used exclusively for the core VPN-per-tab functionality. See the extension's AMO listing for a detailed justification of each permission.

## Open Source

TabVPN is open source. You can review the complete source code at:
https://github.com/lyapupastar-png/TabVPN

## Contact

If you have questions about this privacy policy, please open an issue on the GitHub repository.
