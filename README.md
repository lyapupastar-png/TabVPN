# TabVPN

A Firefox extension for a common problem: some internet resources
are unavailable from the IP address of the location you're browsing
from. Instead of switching between a separate VPN app and the
browser, TabVPN adds an "Open with VPN" item to the right-click
menu that opens the link through a VPN route immediately, without
touching any other tabs.

## The problem

Copying a link into another browser, or toggling a VPN on and off
for all your traffic, is slow and inconvenient. What's needed is a
targeted, per-link way to get around geo-blocking on one specific
resource, without affecting the rest of your browsing.

## The solution (v1)

A Firefox extension with an "Open with VPN" context-menu item. The
selected link opens in a separate, isolated container (Firefox
Containers), whose traffic is routed entirely through a local Tor
client — no paid servers or subscriptions required.

## Architecture

- **Extension (WebExtension)** — UI, context menu, container,
  proxy routing.
- **Native messaging host** — a local companion process that talks
  to Tor.
- **Tor client** — the transport that provides an exit IP in a
  different jurisdiction.

All components run entirely locally, on the user's machine. No
server infrastructure of our own is required — Tor uses the
existing network of volunteer-run relays.

## What v1 solves, and what it doesn't

There are two kinds of geo-blocking:
- **"Unavailable from my country"** (a negative/deny list) — this
  is solved: a random Tor exit node will almost always land outside
  the blocked country.
- **"Available only from one specific country"** (an allow list) —
  not solved in v1: that needs exit-country selection, which
  doesn't exist yet.

v1 covers only the first scenario. Choosing a specific exit country
is a deliberately deferred feature.

## Roadmap (post-v1)

- Exit-country selection (requires a pool of Tor instances with
  different `ExitNodes`, or alternative nodes).
- An optional P2P mode (bandwidth sharing between users) — with an
  explicit opt-in toggle for acting as an exit node, traffic-type
  restrictions (HTTP/HTTPS only), and safeguards against repeating
  the mistakes of the Hola/Luminati model (no reselling access to
  third parties, full transparency).
- Self-hosted/paid nodes for specific stubborn sites (to solve the
  "allow list" type of geo-blocking).
- A possible move to Electron if WebExtensions API limitations
  become a blocker.

## Tech stack

- WebExtensions API (Firefox): `contextMenus`, `contextualIdentities`,
  `proxy.onRequest`
- Native messaging host: Node.js
- Tor (Tor Expert Bundle)

## Explicitly out of scope for v1

- Exit-country selection
- P2P
- Chrome/Chromium support
- Mobile platforms
