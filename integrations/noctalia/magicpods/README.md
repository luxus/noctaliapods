# MagicPods

Control AirPods, Beats and Galaxy Buds from Noctalia: battery, noise control and
connection management, backed by the [MagicPodsCore](https://github.com/steam3d/MagicPodsCore)
daemon.

- **Bar widget** — headphones glyph + active-device battery + charging cue.
- **Panel** — connect/disconnect, per-earbud battery, noise-control modes and
  feature toggles.
- **Service** — keeps one live connection to the daemon and updates the UI in
  real time.

## Requirements

- The MagicPodsCore daemon running on `ws://127.0.0.1:2020`.
- `python3` on `PATH` (the daemon speaks WebSocket; the bundled `bridge.py` is a
  dependency-free WebSocket client, since Luau has no WebSocket support).

## Usage

Enable the plugin, add the **MagicPods** widget to a bar, or toggle the panel:

```bash
noctalia msg panel-toggle steam3d/magicpods:panel
```

See [`../README.md`](../README.md) for the full install script (daemon build +
systemd service + plugin link) and troubleshooting.
