# Audit: MagicPods WebSocket API vs what lea needs

Findings only. This is not a feature port, not an Omarchy/QML rewrite, and not a panel plugin.

**Verdict:** `luxus/noctaliapods` is a byte-identical MagicPodsCore fork (`steam3d/MagicPodsCore` master, v2.0.9). It speaks a **WebSocket JSON RPC** on port 2020. Lea’s AirPods bar (`harveywuk/airpods`) speaks **librepods `status.json` + `librepods-ctl`**. Those contracts do not match. Do not implement the panel feed in this repo.

## What this repo is

MagicPodsCore daemon:

- L2CAP AAP for AirPods/Beats, RFCOMM for Galaxy Buds.
- Public API: WebSocket JSON at `:2020` (`api-reference.md`).
- Handshake `init` (`api` 0, `version` 2.0.9), then clients call `GetAll`.
- Live updates via uWebSockets topics (`info`, `headphones`, `defaultbluetooth`, `settings`, `animation`).
- `SetCapabilities` writes one capability object at a time.
- Bind: `listen(2020)` with no host (all interfaces). README still says `ws://172.0.1.0:2020/`.

It is **not** a librepods fork and **not** an omarchy-pods port.

## What lea actually consumes

Panel feed is **not** this repo’s job. luxusAi packages `harveywuk/librepods` (status.json + ctl) for `harveywuk/airpods`.

The plugin (`harveywuk/airpods` `service.luau`) does two things:

1. **Read** `$XDG_STATE_HOME/librepods/status.json` (fallback `~/.local/state/librepods/status.json`). Absent file means daemon down. Schema `schema_version` must be `1`.
2. **Write** by spawning `librepods-ctl <verb>` (or `ctl_path`).

Required status fields (schema 1):

| Field | Role |
| --- | --- |
| `schema_version` | Must be `1`; newer is a hard error |
| `connected`, `device_name`, `model_name` | Identity |
| `is_pro_series`, `is_headset` | Layout (buds vs Max) |
| `supports_noise_off`, `supports_noise_control`, `supports_adaptive`, `supports_conversational_awareness`, `supports_one_bud_anc` | Which rows to draw |
| `noise_mode` | `0` off, `1` anc, `2` transparency, `3` adaptive |
| `adaptive_noise_level` | `0–100` |
| `conversational_awareness`, `one_bud_anc_mode` | Toggles |
| `ear_detection_behavior` | `0` pause one out, `1` pause both out, `2` off |
| `lid_state` | `0` open, `1` closed, `2` unknown |
| `left` / `right` | `{available, level, charging, in_ear}` |
| `case` | `{available, level, charging}` |
| `headset` | Max single battery |

Required ctl verbs:

```
status
noise:off | noise:anc | noise:transparency | noise:adaptive
ca:on | ca:off
onebud:on | onebud:off
adaptive:<0-100>
ear:one | ear:both | ear:off
```

That contract comes from the patched librepods in `harveywuk/librepods` (same patches as `thisisgm/omarchy-pods` `daemon/`). Upstream `kavishdevar/librepods` does **not** have `status.json` or the `ca:` / `onebud:` / `adaptive:` / `ear:` verbs.

## Mapping: MagicPods WS vs lea

| Lea need | MagicPods WS today | Fit |
| --- | --- | --- |
| File watch on `status.json` | Push JSON on a live WebSocket after `GetAll` | **No.** Different transport. Luau has no WebSocket client. |
| `librepods-ctl` verbs | `{ "method": "SetCapabilities", "arguments": { "address", "capabilities": { … } } }` | **No.** Different CLI/IPC. |
| `ca:` | Capability `conversationAwareness.selected` (bool) | Semantics overlap; not the verb. |
| `onebud:` | Capability `ancOneAirPod.selected` (bool) | Semantics overlap; not the verb. |
| `adaptive:N` | Capability `adaptiveAudioNoise.selected` (`0–100`) | Semantics overlap; not the verb. |
| `ear:` (pause behavior) | **Not a WS capability.** Galaxy Buds has an internal ear watcher only. AirPods in-ear is not published on `info`. PulseAudio client does not implement ear-pause. | **Missing.** |
| `left.in_ear` / `right.in_ear` | Battery is `{battery, charging, status}` only | **Missing** on the public `info` object. BLE parse in `AppAnimationCapability` sees case/active bits for the pop-up animation, not as pod `in_ear`. |
| `lid_state` | Not on `info` | **Missing.** |
| Pro 3 model map | `AapModelIds::airpodspro3 = 0x2027`; `AapInitExt` includes it (Adaptive on) | **Present as Bluetooth product id**, not Apple `A3064`. Panel cannot use this id as `model_name`. |
| `supports_noise_off` (Pro 3 has none) | `AapSetAnc::GetAncModesFor` always includes Off for every `AapInitExt` model, including Pro 3 | **Wrong for Pro 3.** Packet is sent; device ignores it. Panel would still draw Off. |
| Capability-driven panel | Capabilities omitted until `isAvailable`; `anc.options` is a bitmask | **Partial.** No `supports_*` flags. Off/Adaptive come from product-id tables, not the device. First-gen Pro / Max 1 correctly get no Adaptive (`AapInitExt` excludes them). |
| Noise mode enum | Bit flags: Off=1, Transparency=2, Adaptive=4, ANC=16 | **Incompatible** with lea’s 0/1/2/3. |

### What MagicPods has that lea does not ask this repo for

- Galaxy Buds + Beats over the same WS.
- `ConnectDevice` / `DisconnectDevice` and Bluetooth adapter power.
- Stem/press settings, tone volume, personalized volume, codec switch, conversation-speaking readonly, case-open animation.
- TOML settings store (`~/.config/magicpods/config.toml`).

Those are real MagicPods features. They are not the lea bar contract. Do not drag them into `harveywuk/airpods`.

## Existing work in this repo (do not fight)

| Item | What it is | Action |
| --- | --- | --- |
| `luxus/noctaliapods` master | Identical to `steam3d/MagicPodsCore` 2.0.9 | Keep as the MagicPods WS daemon if Decky/Plasmoid-style clients still need it. |
| Draft PR #1 `cursor/noctalia-magicpods-plugin-871b` | Noctalia v5 Luau plugin + Python WS bridge + Nix flake | **Out of scope** for lea. It rebuilds a MagicPods panel instead of watching `status.json`. Leave draft; do not merge as the AirPods feed. |
| Issues | Disabled on this GitHub repo | Track follow-ups in PRs or elsewhere. |

No code changes in this PR. A sibling MagicPods audit can treat this document as the shared findings and stop.

## Who owns what

| Surface | Owner | This repo |
| --- | --- | --- |
| `status.json` + `librepods-ctl` (ca / onebud / adaptive / ear, Pro 3 map, `supports_*`) | `harveywuk/librepods` (package via luxusAi) | Do not reimplement |
| Noctalia bar/panel | `harveywuk/airpods` | Do not add a plugin here |
| Hi-res mic pin, BT DeviceID spoof, AVRCP dummy | luxusAi / librepods Rust rewrite (context only) | Do not edit |
| MagicPods WS daemon for non-lea clients | This fork, if kept | Docs + optional upstream sync only |

## Suggested follow-ups (not implemented here)

Shipable units if Helm still wants MagicPods alive as a *different* product. One unit each; none of these unblock lea.

1. **Decide keep-or-archive.** If lea is the only consumer, this fork is unused. If Decky/Plasmoid remain, keep syncing `steam3d/MagicPodsCore`.
2. **Do not add `status.json` to MagicPods.** That would fork the lea contract into a second daemon. Package `harveywuk/librepods` instead.
3. **Do not merge PR #1** as the AirPods panel. A WS bridge does not make MagicPods speak librepods.
4. **Optional MagicPods-only bugs** (only if this daemon stays): document bind address (`0.0.0.0:2020` vs README `172.0.1.0`); Pro 3 Off bit in `GetAncModesFor`; `AapAncModeToString(Anc)` currently prints `WindCancellation`.

## Sources (read, not copied)

- This tree: `api-reference.md`, `src/main.cpp`, `src/device/AapDevice.cpp`, `src/sdk/aap/enums/AapModelIds.h`, `src/sdk/aap/setters/AapSetAnc.cpp` / `AapInitExt.cpp`, capability classes under `src/device/capabilities/aap/`.
- `gh api repos/steam3d/MagicPodsCore/compare/…luxus:master` → identical.
- `harveywuk/airpods` `service.luau` (`parseStatus`, ctl verbs).
- `harveywuk/librepods` `main.cpp` `statusJson()`, `enums.h` model/capability map.
