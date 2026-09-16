--!nonstrict
-- MagicPods service — the headless [[service]] entry.
--
-- Owns the single long-lived connection to the MagicPodsCore daemon. The daemon
-- speaks WebSocket JSON and Luau has no WebSocket client, so the connection is a
-- child process (bridge.py) driven with:
--
--   noctalia.runStream(cmd, onLine)   long-lived: one daemon message per line
--   noctalia.runAsync(cmd, cb)        one-shot: send a single command
--
-- Parsed state is published for the bar widget and panel via noctalia.state; UI
-- entries push user actions back through the "mp.command" state key.

local STATE_DEVICES = "mp.devices" -- array of { name, address, connected, ... }
local STATE_INFO = "mp.info" -- active device incl. capabilities, or {}
local STATE_BLUETOOTH = "mp.bluetooth" -- adapter powered (bool)
local STATE_BRIDGE = "mp.bridge" -- bridge <-> daemon connected (bool)
local STATE_BAR = "mp.bar" -- pre-computed summary for the bar widget
local STATE_COMMAND = "mp.command" -- UI -> service command channel

-- Noise-control bitmask (see api-reference.md → "Noise control").
local ANC = {
  OFF = 1,
  TRANSPARENCY = 2,
  ADAPTIVE = 4,
  WIND = 8,
  NOISE_CANCELLATION = 16,
}

local model = {
  devices = {},
  info = {},
  bluetooth = false,
  bridge = false,
}

local function shellQuote(s)
  return "'" .. string.gsub(tostring(s), "'", "'\\''") .. "'"
end

local function daemonUrl()
  local url = noctalia.getConfig("daemon_url")
  if type(url) ~= "string" or noctalia.string.trim(url) == "" then
    return "ws://127.0.0.1:2020"
  end
  return noctalia.string.trim(url)
end

local function batterySource()
  local src = noctalia.getConfig("battery_source")
  if type(src) == "string" and src ~= "" then
    return src
  end
  return "auto"
end

-- Python interpreter: an explicit absolute path (for NixOS / immutable distros
-- where PATH may lack python3 in the Noctalia session), else "python3" on PATH.
local function pythonBin()
  local p = noctalia.getConfig("python_path")
  if type(p) == "string" and noctalia.string.trim(p) ~= "" then
    return noctalia.string.trim(p)
  end
  return "python3"
end

local function pythonAvailable(bin)
  if string.sub(bin, 1, 1) == "/" then
    return noctalia.fileExists(bin)
  end
  return noctalia.commandExists(bin)
end

local function bridgePath()
  local dir = noctalia.pluginDir()
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  return dir .. "/bridge.py"
end

-- Pick the battery entry to surface on the bar. "auto" shows the lowest of the
-- two earbuds (or the single-battery reading), which is what a user cares about.
local function pickBattery(battery, source)
  if type(battery) ~= "table" then
    return nil
  end
  local function avail(part)
    local p = battery[part]
    if type(p) == "table" and type(p.battery) == "number" and (p.status or 0) ~= 0 then
      return p
    end
    return nil
  end
  if source == "left" or source == "right" or source == "case" then
    return avail(source)
  end
  local best = nil
  for _, part in ipairs({ "left", "right", "single" }) do
    local p = avail(part)
    if p ~= nil and (best == nil or p.battery < best.battery) then
      best = p
    end
  end
  return best
end

local function activeCapabilities()
  local info = model.info
  if type(info) == "table" and type(info.capabilities) == "table" then
    return info.capabilities
  end
  return nil
end

local function isActiveConnected()
  local info = model.info
  return type(info) == "table" and info.connected == true and type(info.address) == "string"
end

local function publishBar()
  local caps = activeCapabilities()
  local battery = caps ~= nil and pickBattery(caps.battery, batterySource()) or nil
  local bar = {
    bridge = model.bridge,
    bluetooth = model.bluetooth,
    present = isActiveConnected(),
    name = (type(model.info) == "table" and model.info.name) or "",
    battery = battery ~= nil and battery.battery or -1,
    charging = battery ~= nil and battery.charging == true,
  }
  noctalia.state.set(STATE_BAR, bar)
end

local function publishAll()
  noctalia.state.set(STATE_DEVICES, model.devices)
  noctalia.state.set(STATE_INFO, model.info)
  noctalia.state.set(STATE_BLUETOOTH, model.bluetooth)
  noctalia.state.set(STATE_BRIDGE, model.bridge)
  publishBar()
end

local function applyDaemonMessage(msg)
  if type(msg) ~= "table" then
    return
  end

  -- Bridge lifecycle envelope, not a daemon payload.
  if type(msg._bridge) == "table" then
    model.bridge = msg._bridge.connected == true
    if not model.bridge then
      -- Daemon went away: drop stale device state so the UI shows "offline".
      model.info = {}
      model.devices = {}
    end
    publishAll()
    return
  end

  if msg.headphones ~= nil then
    model.devices = type(msg.headphones) == "table" and msg.headphones or {}
    noctalia.state.set(STATE_DEVICES, model.devices)
  end
  if msg.info ~= nil then
    model.info = type(msg.info) == "table" and msg.info or {}
    noctalia.state.set(STATE_INFO, model.info)
  end
  if type(msg.defaultbluetooth) == "table" and msg.defaultbluetooth.enabled ~= nil then
    model.bluetooth = msg.defaultbluetooth.enabled == true
    noctalia.state.set(STATE_BLUETOOTH, model.bluetooth)
  end
  publishBar()
end

local function startStream()
  local path = bridgePath()
  if path == nil then
    noctalia.log("magicpods: could not resolve plugin directory")
    return
  end
  local python = pythonBin()
  if not pythonAvailable(python) then
    noctalia.log("magicpods: python interpreter '" .. python .. "' not found; bridge cannot start")
    model.bridge = false
    publishAll()
    return
  end

  local cmd = string.format("%s %s --url %s stream", shellQuote(python), shellQuote(path), shellQuote(daemonUrl()))
  local ok = noctalia.runStream(cmd, function(line)
    line = noctalia.string.trim(line or "")
    if line == "" then
      return
    end
    local decoded = noctalia.json.decode(line)
    if decoded == nil then
      noctalia.log("magicpods: could not decode daemon line: " .. line)
      return
    end
    applyDaemonMessage(decoded)
  end)

  if not ok then
    noctalia.log("magicpods: failed to start bridge stream")
  end
end

-- Send a single request to the daemon via a one-shot bridge invocation.
local function sendToDaemon(request)
  local path = bridgePath()
  local python = pythonBin()
  if path == nil or not pythonAvailable(python) then
    return
  end
  local json = noctalia.json.encode(request)
  if json == nil then
    noctalia.log("magicpods: failed to encode request")
    return
  end
  local cmd = string.format(
    "%s %s --url %s send %s",
    shellQuote(python),
    shellQuote(path),
    shellQuote(daemonUrl()),
    shellQuote(json)
  )
  noctalia.runAsync(cmd, function(result)
    -- Any state change is delivered on the persistent stream; the one-shot
    -- response is only used for diagnostics.
    if type(result) == "table" and result.exitCode ~= 0 then
      noctalia.log("magicpods: send failed: " .. tostring(result.stderr))
    end
  end, 8000)
end

-- Command handlers invoked from the bar/panel through noctalia.state.
local function handleCommand(cmd)
  if type(cmd) ~= "table" or type(cmd.action) ~= "string" then
    return
  end
  local action = cmd.action

  if action == "connect" and type(cmd.address) == "string" then
    sendToDaemon({ method = "ConnectDevice", arguments = { address = cmd.address } })
  elseif action == "disconnect" and type(cmd.address) == "string" then
    sendToDaemon({ method = "DisconnectDevice", arguments = { address = cmd.address } })
  elseif action == "set_anc" and type(cmd.address) == "string" and type(cmd.selected) == "number" then
    sendToDaemon({
      method = "SetCapabilities",
      arguments = { address = cmd.address, capabilities = { anc = { selected = cmd.selected } } },
    })
  elseif action == "set_capability" and type(cmd.address) == "string" and type(cmd.capability) == "string" then
    local caps = {}
    caps[cmd.capability] = { selected = cmd.selected }
    sendToDaemon({ method = "SetCapabilities", arguments = { address = cmd.address, capabilities = caps } })
  elseif action == "set_bluetooth" then
    sendToDaemon({ method = cmd.selected and "EnableDefaultBluetoothAdapter" or "DisableDefaultBluetoothAdapter" })
  elseif action == "refresh" then
    sendToDaemon({ method = "GetAll" })
  else
    noctalia.log("magicpods: unknown command action '" .. action .. "'")
  end
end

noctalia.state.watch(STATE_COMMAND, handleCommand)

-- Seed empty state immediately so UI entries render a sane "connecting" view.
publishAll()
startStream()
