# AUDIT: MagicPodsCore vs omarchy / Noctalia AirPods IPC

**Decision: park this repo as a Noctalia bar backend.**

`luxus/noctaliapods` is a GitHub fork of [steam3d/MagicPodsCore](https://github.com/steam3d/MagicPodsCore), not a port of [thisisgm/omarchy-pods](https://github.com/thisisgm/omarchy-pods). Master is an unmodified MagicPodsCore **2.0.9** (`11422817ed`). There are no luxus commits on `master`.

The Noctalia v5 bar already has a plugin that speaks the omarchy `status.json` + `librepods-ctl` contract. MagicPods speaks a different WebSocket JSON API. Do **not** rewrite MagicPods into a second `status.json`. The lea ship gate is packaging the patched Qt librepods daemon (harveywuk / omarchy) and enabling the community plugin.

Issues cannot be opened here (`has_issues: false` on the fork; enabling it 403s for this agent). This file is the issue map.

---

## 1. What this repo is

| Item | Fact |
| --- | --- |
| Parent | `steam3d/MagicPodsCore` |
| Language / binary | C++20 `magicpodscore` |
| IPC | WebSocket text frames, JSON, port **2020** (uWebSockets). README says `ws://172.0.1.0:2020/`; `main.cpp` listens on port 2020 with `LIBUS_LISTEN_EXCLUSIVE_PORT` (all interfaces, not a Unix socket). |
| Protocol | Apple AAP over L2CAP PSM `0x1001`; Galaxy Buds over RFCOMM; Beats via the same AAP path. |
| UI | None in this tree. Frontends are [MagicPodsDecky](https://github.com/steam3d/MagicPodsDecky) and [MagicPodsPlasmoid](https://github.com/steam3d/MagicPodsPlasmoid). |
| Config | `~/.config/magicpods/config.toml` (IRK/enc keys, log level, per-device settings). |
| Tests | In-process only under `#ifdef DEBUG`: `TestsSgb`, `TestsAapBle`. No CTest, no CI on master. |
| Nix | None on master. A flake exists only on draft PR #1. |
| Bundled daemon for Noctalia? | No. Master is the upstream daemon plus Docker build. |

Push model: after `GetAll`, the daemon broadcasts `info` / `headphones` / `defaultbluetooth` / `animation` / `settings` on change. That is closer to “watch” than poll **on its own socket**. It is not a file watch, and Luau has no WebSocket client.

### Capability names MagicPods already exposes

From `AapDevice::Create` and `api-reference.md`:

| WS capability | Meaning |
| --- | --- |
| `battery` | left / right / case / single: percent, charging, status (readonly) |
| `anc` | selected + options bitmask: Off=1, Transparency=2, Adaptive=4, WindCancellation=8, NoiseCancellation=16 |
| `conversationAwareness` | bool |
| `conversationAwarenessSpeaking` | readonly bool (talking now) |
| `ancOneAirPod` | one-bud ANC bool |
| `adaptiveAudioNoise` | 0–100 |
| `bluetoothCodec` | PulseAudio card profile |
| `volumeSwipe`, `volumeSwipeLength`, `pressSpeed`, `pressAndHoldDuration`, `toneVolume`, `personalizedVolume`, `endCall` | stem / call extras |
| `animation` | empty capability body; separate `animation` broadcast from BLE ads (case-open popup) |

AirPods Pro 3 is a first-class model (`AapModelIds::airpodspro3 = 0x2027`) and is in `AapInitExt::IsSupported`, so Adaptive handshake is sent.

---

## 2. What lea needs for Noctalia

The feature-steal target is two pieces, already written:

1. **Daemon:** [thisisgm/omarchy-pods](https://github.com/thisisgm/omarchy-pods) `daemon/` (patched Qt librepods) **or** the extracted fork [harveywuk/librepods](https://github.com/harveywuk/librepods).
2. **Bar / panel:** [noctalia-dev/community-plugins](https://github.com/noctalia-dev/community-plugins) `airpods/` — plugin id `harveywuk/airpods`, also published as [harveywuk/airpods](https://github.com/harveywuk/airpods). Port of the Omarchy widget.

The plugin **never talks Bluetooth**. It reads one JSON line and runs `librepods-ctl`:

| Contract | Detail |
| --- | --- |
| Status file | `$XDG_STATE_HOME/librepods/status.json` (fallback `~/.local/state/librepods/status.json`). Daemon writes on change, **deletes on quit**. |
| Schema | `schema_version: 1`. Newer is refused, not guessed. |
| Control | `librepods-ctl` → `$XDG_RUNTIME_DIR/librepods.sock` |
| Verbs | `noise:off` `noise:anc` `noise:transparency` `noise:adaptive` `ca:on` `ca:off` `onebud:on` `onebud:off` `adaptive:N` `ear:one` `ear:both` `ear:off` plus `status` |
| Capability flags | `supports_noise_off`, `supports_noise_control`, `supports_adaptive`, `supports_conversational_awareness`, `supports_one_bud_anc`, `is_headset`, `is_pro_series` |
| Per-pod | `left`/`right`: `available`, `level`, `charging`, `in_ear` |
| Case | `case.level` / `charging` plus `lid_state` (0 open, 1 closed, 2 unknown) |
| Headset | AirPods Max: `headset` battery, no case row, no One-Bud ANC |

Omarchy’s widget **watches the file** (idle desktop runs no extra process). The Noctalia community plugin **polls every 2s** (`POLL_INTERVAL_MS = 2000` in `service.luau`) because Luau has `readFile` + interval, not inotify. That is a plugin limitation. It still requires the omarchy file and verbs. Do not invent another format to “fix” the poll.

Canonical status line (from omarchy `Model.js`):

```json
{
  "schema_version": 1,
  "connected": true,
  "device_name": "…",
  "model_name": "AirPods Pro 3",
  "model_number": "A3064",
  "is_pro_series": true,
  "supports_noise_off": false,
  "supports_noise_control": true,
  "supports_adaptive": true,
  "supports_conversational_awareness": true,
  "supports_one_bud_anc": true,
  "noise_mode": 1,
  "adaptive_noise_level": 50,
  "conversational_awareness": true,
  "one_bud_anc_mode": true,
  "ear_detection_behavior": 0,
  "lid_state": 2,
  "left": {"available": true, "level": 79, "charging": false, "in_ear": false},
  "right": {"available": true, "level": 100, "charging": true, "in_ear": false},
  "case": {"available": true, "level": 100, "charging": false}
}
```

---

## 3. Feature matrix

Legend: **yes** = MagicPods already has an equivalent on its own API. **no** = missing for the Noctalia plugin. **partial** = protocol bits exist but are not published the way the plugin needs.

| Need (omarchy / `harveywuk/airpods`) | MagicPodsCore 2.0.9 | Notes |
| --- | --- | --- |
| `status.json` watchable file | **no** | WS broadcasts only. No `$XDG_STATE_HOME`, no delete-on-quit file. |
| `librepods-ctl` + `ca:` `onebud:` `adaptive:` `ear:` `noise:` | **no** | Control is `SetCapabilities` JSON over WS. No Unix socket. |
| Conversation Awareness | **yes** | `conversationAwareness` get/set. Speaking state is extra (`conversationAwarenessSpeaking`). |
| One-bud ANC | **yes** | `ancOneAirPod`. |
| Adaptive listening mode | **yes** | `anc` bit 2. |
| Adaptive noise level 0–100 | **yes** | `adaptiveAudioNoise`. |
| AirPods Pro 3 in the model map | **yes** | `0x2027`, Adaptive init sent. |
| `supports_noise_off` (Pro 3 dropped Off) | **no** | `AapSetAnc::GetAncModesFor` always includes `Off` for every `AapInitExt` model, Pro 3 included. Sending Off is ignored on hardware. |
| Capability-driven UI flags | **partial** | Capabilities appear in `info` only after the first device packet (`isAvailable`). There are no `supports_*` keys. ANC/CA/one-bud are **always registered** on every AAP device, including AirPods 1/2/3 with no listening modes. |
| Ear-detection **behavior** (`ear:one/both/off`) | **no** | No AAP setter, no WS field. Galaxy Buds has `GalaxyBudsEarDetectionWatcher` (tested) but `GalaxyBudsDevice::Create` never attaches it as a capability. |
| Per-pod `in_ear` | **no** | Battery JSON has percent/charging/status only. BLE UTP flags (`_bothAirPodsInCase`, `_twoAirPodActive`) are used for popup animation, not published as in-ear. |
| Case lid | **partial** | BLE manufacturer data is parsed for **animation** (lid-open popup + battery). No `lid_state` in `info`. |
| Case / pod battery | **yes** | AAP watchers + BLE public/private battery in animation path. |
| Connect / disconnect | **yes** (MagicPods extra) | `ConnectDevice` / `DisconnectDevice` via BlueZ. Omarchy/Noctalia plugins leave this to the stock Bluetooth panel. |
| Galaxy Buds / Beats extras | **yes** (MagicPods extra) | Not consumed by `harveywuk/airpods`. |
| `--headless` systemd user unit | **no** on master | Draft PR #1 added `magicpodscore.service`; not the librepods unit the plugin looks for. |
| Single AAP client | **conflict** | AirPods accept **one** L2CAP `0x1001` client. Running MagicPods beside librepods means one of them goes stale. |

Pro 3 Off is the sharp hardware mismatch: omarchy taught the panel to hide Off when `supports_noise_off` is false. MagicPods would draw Off and send `0x01`.

---

## 4. Keep / park

**Park MagicPods as the Noctalia daemon.** It is not a dead project — it is the wrong IPC for the bar that lea actually wants.

Do not:

- Teach MagicPods to write omarchy `status.json` (second implementation of a format that already has a daemon).
- Land draft PR #1 (Luau plugin + Python WebSocket bridge) as the lea path.
- Run MagicPods and librepods at the same time.

Keep this fork only as:

- A **protocol reference** (CA, one-bud, adaptive level, Pro 3 model id, BLE animation parse, Galaxy Buds).
- An optional **non-Noctalia** frontend path (Decky / Plasma) if someone wants MagicPods’ extra Beats/Galaxy surface.

If MagicPods were the only Linux AAP daemon, a WS→file adapter might be justified. It is not: harveywuk/librepods already is the omarchy daemon extracted for this plugin.

---

## 5. lea packaging (owned by another agent)

Today on lea (from the task, not re-verified here — `luxus/luxusAi` 404s for this agent):

- `pkgs/librepods` packages the **Rust iced tray app** from [librepods-org/librepods PR #655](https://github.com/librepods-org/librepods/pull/655) (`linux/rust`, high-res AACP microphone).
- That app does **not** publish `status.json` or `ca:`/`onebud:`/`adaptive:`/`ear:` verbs.
- nixpkgs `librepods` is the **unpatched Qt 0.2.5** tray (`pkgs/by-name/li/librepods/package.nix`) — same gap.

What lea needs instead:

1. Package **harveywuk/librepods** (or `thisisgm/omarchy-pods/daemon`) as the user daemon: `librepods.service` `--headless`, `librepods-ctl` on `PATH`, status file in `$XDG_STATE_HOME`.
2. Enable Noctalia community plugin **`harveywuk/airpods`** (already in `noctalia-dev/community-plugins`).
3. Do **not** point that plugin at MagicPods or at the iced tray.

`luxusAi` is the right repo for that PR. This agent cannot open it.

---

## 6. Issue map (GitHub issues disabled)

Priorities if issues are enabled later. None of these should be implemented **here** unless the park decision is reversed.

| P | Title | Where it actually lives |
| --- | --- | --- |
| P0 | lea: package harveywuk/librepods (status.json + ctl verbs), not iced PR #655, as the AirPods daemon | luxusAi `pkgs/librepods` |
| P0 | lea: enable `harveywuk/airpods` on Noctalia | luxusAi / Noctalia host config |
| P1 | Do not run two AAP clients (MagicPods vs librepods) | ops / docs |
| P2 | Park/close noctaliapods PR #1 (MagicPods Luau + Python WS bridge) | this repo, draft PR |
| P3 | Upstream MagicPods: Pro 3 should not advertise Off | steam3d/MagicPodsCore `AapSetAnc::GetAncModesFor` |
| P3 | Upstream MagicPods: hardcoded BlueZ `hci0` crash loop | [steam3d#22](https://github.com/steam3d/MagicPodsCore/issues/22) |
| P3 | Community plugin polls `status.json` every 2s; omarchy watches | noctalia-dev/community-plugins `airpods/service.luau` — only after the daemon exists |
| — | Rewrite MagicPods → status.json | **won’t do** |

P0s are blocked on luxusAi access and on hardware for end-to-end AirPods verification. This audit is the deliverable for **this** repo.

---

## 7. Existing work in this fork

[PR #1](https://github.com/luxus/noctaliapods/pull/1) (draft, 2026-08-18): Noctalia v5 Luau plugin (`magicpods/`), `bridge.py` (stdlib WebSocket client), Nix flake, HM/hjem modules, mock-daemon tests.

It is a competent MagicPods frontend. It is the wrong stack for lea:

- Invents a parallel plugin (`steam3d/magicpods`) next to the already-merged `harveywuk/airpods`.
- Needs a long-lived Python process because Luau cannot speak WebSocket.
- Still would not give Pro 3 `supports_noise_off`, `ear:`, `in_ear`, or `lid_state`.

Leave it draft. Do not merge as the production path.

---

## 8. Evidence in this tree

| Claim | Where |
| --- | --- |
| Fork of MagicPodsCore, WS API | `README.md`, `api-reference.md`, `src/main.cpp` (`WEBSOCKET_PORT = 2020`) |
| CA / one-bud / adaptive | `src/device/AapDevice.cpp`, matching `src/device/capabilities/aap/*` |
| Pro 3 id + Adaptive init | `src/sdk/aap/enums/AapModelIds.h`, `src/sdk/aap/setters/AapInitExt.cpp` |
| Off always in Adaptive models | `src/sdk/aap/setters/AapSetAnc.cpp` `GetAncModesFor` |
| No AAP ear-detection capability | no `*Ear*` under `src/device/capabilities/aap/`; SGB watcher unused by `GalaxyBudsDevice::Create` |
| BLE used for animation, not lid/in-ear IPC | `src/device/capabilities/aap/AppAnimationCapability.cpp` |
| Battery has no `in_ear` | `src/device/structs/DeviceBatteryData.h` |
| Tests are DEBUG-only | `src/main.cpp` `#ifdef DEBUG`, `src/tests/` |

Omarchy / plugin contract cited from:

- https://github.com/thisisgm/omarchy-pods `README.md`, `daemon/UPSTREAM.md`, `Model.js`
- https://github.com/harveywuk/librepods `README.md`
- https://github.com/noctalia-dev/community-plugins `airpods/README.md`, `airpods/service.luau`

---

## 9. Hardware

No AirPods, BlueZ adapter, or running librepods on this agent VM. Protocol and IPC conclusions are from source. Do not treat this audit as a live Pro 3 Off-mode test.
