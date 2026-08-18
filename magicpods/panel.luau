--!nonstrict
-- MagicPods panel — the [[panel]] entry.
--
-- The interactive control surface: connect/disconnect devices, read per-earbud
-- battery, switch noise-control modes and toggle extra AirPods/Beats features.
-- It renders the state published by the service and pushes user actions back
-- through the "mp.command" state channel.

local devices = {}
local info = {}
local bluetooth = false
local bridge = false
local seq = 0

-- Noise-control bitmask, matching api-reference.md.
local ANC = {
  { value = 1, key = "anc.off", glyph = "circle" },
  { value = 2, key = "anc.transparency", glyph = "ear" },
  { value = 4, key = "anc.adaptive", glyph = "adjustments" },
  { value = 16, key = "anc.noise_cancellation", glyph = "wave-square" },
}

-- Boolean capabilities worth a quick toggle in the panel.
local TOGGLES = {
  { key = "conversationAwareness", label = "toggles.conversation_awareness" },
  { key = "personalizedVolume", label = "toggles.personalized_volume" },
  { key = "ancOneAirPod", label = "toggles.anc_one_airpod" },
}

local BATTERY_PARTS = {
  { key = "left", label = "battery.left" },
  { key = "right", label = "battery.right" },
  { key = "case", label = "battery.case" },
  { key = "single", label = "battery.single" },
}

local function sendCommand(cmd)
  seq += 1
  cmd.seq = seq -- nonce so identical consecutive actions still fire the watcher
  noctalia.state.set("mp.command", cmd)
end

local function capabilities()
  if type(info) == "table" and type(info.capabilities) == "table" then
    return info.capabilities
  end
  return nil
end

local function isConnected(dev)
  return type(dev) == "table" and dev.connected == true
end

local function renderHeader()
  local title = noctalia.tr("panel.title")
  if type(info) == "table" and info.connected == true and type(info.name) == "string" and info.name ~= "" then
    title = info.name
  end
  return ui.row({ align = "center", justify = "space_between" }, {
    ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
      ui.glyph({ name = "headphones", color = "primary" }),
      ui.label({ text = title, fontSize = 16, fontWeight = "bold", color = "primary" }),
    }),
    ui.button({ glyph = "refresh", variant = "ghost", tooltip = noctalia.tr("panel.refresh"), onClick = "onRefresh" }),
  })
end

local function renderBatteryRow(part, label)
  local caps = capabilities()
  if caps == nil then
    return nil
  end
  local battery = caps.battery
  if type(battery) ~= "table" then
    return nil
  end
  local entry = battery[part]
  if type(entry) ~= "table" or type(entry.battery) ~= "number" or (entry.status or 0) == 0 then
    return nil
  end
  local pct = math.clamp(entry.battery, 0, 100)
  local color = (pct <= 20 and not entry.charging) and "error" or "primary"
  return ui.column({ gap = 2 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = noctalia.tr(label), color = "on_surface" }),
        entry.charging and ui.glyph({ name = "bolt", size = 12, color = "primary" }) or ui.spacer({ width = 0 }),
      }),
      ui.label({ text = string.format("%d%%", pct), fontWeight = "bold", color = color }),
    }),
    ui.progress({ progress = pct / 100, fill = color, height = 6, radius = 3 }),
  })
end

local function renderBattery()
  local caps = capabilities()
  if caps == nil or type(caps.battery) ~= "table" then
    return nil
  end
  local rows = { ui.label({ text = noctalia.tr("panel.battery"), fontWeight = "bold", color = "on_surface" }) }
  local any = false
  for _, part in ipairs(BATTERY_PARTS) do
    local row = renderBatteryRow(part.key, part.label)
    if row ~= nil then
      table.insert(rows, row)
      any = true
    end
  end
  if not any then
    return nil
  end
  return ui.column({ gap = 8 }, rows)
end

local function renderAnc()
  local caps = capabilities()
  if caps == nil or type(caps.anc) ~= "table" then
    return nil
  end
  local anc = caps.anc
  local options = type(anc.options) == "number" and anc.options or 0
  local selected = type(anc.selected) == "number" and anc.selected or 0
  local address = info.address

  local buttons = {}
  for _, mode in ipairs(ANC) do
    if bit32.band(options, mode.value) ~= 0 then
      local isSelected = selected == mode.value
      local modeValue = mode.value
      table.insert(buttons, ui.button({
        key = "anc-" .. tostring(mode.value),
        glyph = mode.glyph,
        text = noctalia.tr(mode.key),
        fontSize = 12,
        flexGrow = 1,
        variant = isSelected and "primary" or "outline",
        enabled = anc.readonly ~= true and type(address) == "string",
        onClick = function()
          sendCommand({ action = "set_anc", address = address, selected = modeValue })
        end,
      }))
    end
  end
  if #buttons == 0 then
    return nil
  end
  -- Two buttons per row so up to four modes fit a narrow panel without clipping.
  local rows = { ui.label({ text = noctalia.tr("panel.noise_control"), fontWeight = "bold", color = "on_surface" }) }
  local i = 1
  while i <= #buttons do
    local pair = { buttons[i] }
    if buttons[i + 1] ~= nil then
      table.insert(pair, buttons[i + 1])
    end
    table.insert(rows, ui.row({ key = "anc-row-" .. tostring(i), gap = 6 }, pair))
    i += 2
  end
  return ui.column({ gap = 6 }, rows)
end

local function renderToggles()
  local caps = capabilities()
  if caps == nil then
    return nil
  end
  local address = info.address
  local rows = {}
  for _, item in ipairs(TOGGLES) do
    local cap = caps[item.key]
    if type(cap) == "table" and type(cap.selected) == "boolean" then
      local capKey = item.key
      table.insert(rows, ui.row({ key = "tgl-" .. item.key, align = "center", justify = "space_between" }, {
        ui.label({ text = noctalia.tr(item.label), color = "on_surface", flexGrow = 1 }),
        ui.toggle({
          checked = cap.selected,
          enabled = cap.readonly ~= true and type(address) == "string",
          onChange = function(value)
            sendCommand({ action = "set_capability", address = address, capability = capKey, selected = value == "true" })
          end,
        }),
      }))
    end
  end
  if #rows == 0 then
    return nil
  end
  return ui.column({ gap = 8 }, {
    ui.label({ text = noctalia.tr("panel.features"), fontWeight = "bold", color = "on_surface" }),
    ui.column({ gap = 4 }, rows),
  })
end

local function renderDevices()
  if type(devices) ~= "table" or #devices == 0 then
    return nil
  end
  local rows = { ui.label({ text = noctalia.tr("panel.devices"), fontWeight = "bold", color = "on_surface" }) }
  for _, dev in ipairs(devices) do
    if type(dev) == "table" and type(dev.address) == "string" then
      local connected = isConnected(dev)
      local address = dev.address
      local name = type(dev.name) == "string" and dev.name ~= "" and dev.name or address
      table.insert(rows, ui.row({ key = "dev-" .. address, gap = 8, align = "center", justify = "space_between" }, {
        ui.row({ gap = 6, align = "center", flexGrow = 1 }, {
          ui.glyph({ name = connected and "bluetooth-connected" or "bluetooth", color = connected and "primary" or "on_surface_variant", size = 14 }),
          ui.label({ text = name, color = "on_surface" }),
        }),
        ui.button({
          text = connected and noctalia.tr("devices.disconnect") or noctalia.tr("devices.connect"),
          fontSize = 12,
          variant = connected and "outline" or "primary",
          onClick = function()
            sendCommand({ action = connected and "disconnect" or "connect", address = address })
          end,
        }),
      }))
    end
  end
  return ui.column({ gap = 6 }, rows)
end

local function renderOffline(message, showRetry)
  local children = {
    ui.glyph({ name = "plug-connected-x", size = 28, color = "on_surface_variant" }),
    ui.label({ text = message, color = "on_surface_variant", textAlign = "center" }),
  }
  if showRetry then
    table.insert(children, ui.button({ text = noctalia.tr("panel.retry"), variant = "primary", onClick = "onRefresh" }))
  end
  return ui.column({ gap = 12, align = "center", justify = "center", flexGrow = 1 }, children)
end

local function render()
  local body = {}

  if not bridge then
    table.insert(body, renderOffline(noctalia.tr("panel.no_daemon"), true))
  elseif not bluetooth then
    table.insert(body, renderOffline(noctalia.tr("panel.bluetooth_off"), false))
    table.insert(body, ui.row({ align = "center", justify = "space_between" }, {
      ui.label({ text = noctalia.tr("panel.bluetooth"), color = "on_surface", flexGrow = 1 }),
      ui.toggle({ checked = false, onChange = function(value)
        sendCommand({ action = "set_bluetooth", selected = value == "true" })
      end }),
    }))
  else
    local sections = {
      renderBattery(),
      renderAnc(),
      renderToggles(),
      renderDevices(),
    }
    local added = false
    for _, section in ipairs(sections) do
      if section ~= nil then
        table.insert(body, section)
        table.insert(body, ui.separator({ spacing = 2 }))
        added = true
      end
    end
    -- Drop the trailing separator.
    if added then
      table.remove(body)
    end
    if not added then
      table.insert(body, renderOffline(noctalia.tr("panel.no_device"), true))
    end
  end

  panel.render(ui.column({ gap = 12, padding = 16 }, {
    renderHeader(),
    ui.scroll({ gap = 12, flexGrow = 1 }, body),
  }))
end

local function refreshFromState()
  devices = noctalia.state.get("mp.devices") or {}
  info = noctalia.state.get("mp.info") or {}
  bluetooth = noctalia.state.get("mp.bluetooth") == true
  bridge = noctalia.state.get("mp.bridge") == true
end

function onOpen(_context)
  refreshFromState()
  render()
end

function onRefresh()
  sendCommand({ action = "refresh" })
end

noctalia.state.watch("mp.devices", function(value)
  devices = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("mp.info", function(value)
  info = type(value) == "table" and value or {}
  render()
end)

noctalia.state.watch("mp.bluetooth", function(value)
  bluetooth = value == true
  render()
end)

noctalia.state.watch("mp.bridge", function(value)
  bridge = value == true
  render()
end)
