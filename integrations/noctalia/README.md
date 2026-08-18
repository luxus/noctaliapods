# MagicPods for Noctalia

A [Noctalia v5](https://noctalia.dev) plugin that brings AirPods / Beats / Galaxy
Buds control to Noctalia's bar and panels, backed by the **MagicPodsCore** daemon
in this repository.

It is inspired by [tomycostantino/omarchpods](https://github.com/tomycostantino/omarchpods)
(a MagicPodsCore front-end for Omarchy), rebuilt for Noctalia's native Luau
plugin system.

## What you get

- A **bar widget** showing a headphones glyph and the active device's battery,
  with a charging indicator.
- A **control panel** to:
  - connect / disconnect paired headphones,
  - read per-earbud and case battery levels,
  - switch noise-control modes (Off / Transparency / Adaptive / Noise
    cancellation),
  - toggle extra AirPods/Beats features (conversation awareness, personalized
    volume, noise cancellation with one AirPod),
  - turn the Bluetooth adapter on when it is off.
- A **headless service** that keeps a single live connection to the daemon and
  pushes updates to the UI in real time.

## Architecture

```
 Noctalia (Luau, no WebSocket)          MagicPodsCore daemon (WebSocket JSON)
 ┌───────────────────────────┐          ┌──────────────────────────────────┐
 │ service.luau  ── runStream ┼── bridge.py ── ws://127.0.0.1:2020 ──────────┤
 │   │  publishes state       │          │  BlueZ / D-Bus / PulseAudio        │
 │   ▼  noctalia.state        │          └──────────────────────────────────┘
 │ bar.luau     panel.luau    │
 └───────────────────────────┘
```

Noctalia's Luau runtime can spawn processes and make HTTP requests, but it has
**no WebSocket client**, and MagicPodsCore only speaks WebSocket. `bridge.py` (a
dependency-free, pure-`python3` RFC 6455 client) is the glue: the service runs it
under `noctalia.runStream` to receive a JSON line per daemon message, and via
`noctalia.runAsync` to send one-shot commands.

## Requirements

- Noctalia v5 (plugin API ≥ 9).
- `python3` on `PATH` (standard library only — no pip packages).
- The MagicPodsCore daemon running and listening on `ws://127.0.0.1:2020`.

## Install

From the repository root:

```bash
bash integrations/noctalia/install.sh
```

This builds the daemon, installs it to `~/.local/bin/magicpodscore`, enables the
`magicpodscore` **systemd user service**, and links the plugin into
`~/.local/share/noctalia/plugins/magicpods`.

Then, in Noctalia: **Settings → Plugins → enable “MagicPods”**, and add the bar
widget from the Add-widget picker (or bind `noctalia msg panel-toggle
steam3d/magicpods:panel`).

### Manual daemon control

If you prefer not to use the service, run the daemon yourself:

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
./build/magicpodscore
```

> The upstream docs mention `172.0.1.0:2020`; the daemon actually listens on all
> interfaces, so `127.0.0.1:2020` is the right address for a local desktop.

## Settings

Configured under **Settings → Plugins → MagicPods** (gear icon):

| Setting | Meaning |
| --- | --- |
| Daemon URL | WebSocket address of the daemon (default `ws://127.0.0.1:2020`). |
| Bar battery source | Which battery the bar shows: lowest earbud, left, right, or case. |
| Hide when disconnected | Hide the bar widget when nothing is connected. |
| Show battery label | Show the battery percentage next to the icon (per widget). |

## Troubleshooting

- **Panel says “daemon not reachable”** — check the service:
  `systemctl --user status magicpodscore.service` and
  `journalctl --user -u magicpodscore.service -f`.
- **Nothing updates** — confirm `python3 -V` works and the daemon URL matches.
  You can test the bridge directly:
  `python3 integrations/noctalia/magicpods/bridge.py stream`.
- **No devices listed** — MagicPodsCore only sees headphones already paired in
  BlueZ. Pair them first (e.g. `bluetoothctl`).

## Development / tests

`integrations/noctalia/tests/` contains a mock daemon and a Luau harness that
execute the plugin logic against the real protocol without a running compositor:

```bash
bash integrations/noctalia/tests/run.sh
```
