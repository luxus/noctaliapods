--!nonstrict
-- MagicPods bar widget — the [[widget]] entry.
--
-- A thin client of the service: it watches the pre-computed "mp.bar" summary and
-- renders a headphones glyph plus the active device's battery. Clicking it opens
-- the control panel.

local PANEL_ID = "steam3d/magicpods:panel"

local bar = {
  bridge = false,
  bluetooth = false,
  present = false,
  name = "",
  battery = -1,
  charging = false,
}
local isVertical = false

local function batteryColor()
  if bar.battery >= 0 and bar.battery <= 20 and not bar.charging then
    return "error"
  end
  if bar.charging then
    return "primary"
  end
  return "on_surface"
end

local function tooltipText()
  if not bar.bridge then
    return noctalia.tr("tooltip.no_daemon")
  end
  if not bar.present then
    return noctalia.tr("tooltip.disconnected")
  end
  local name = bar.name ~= "" and bar.name or noctalia.tr("tooltip.headphones")
  if bar.battery >= 0 then
    local suffix = bar.charging and " " .. noctalia.tr("tooltip.charging") or ""
    return noctalia.tr("tooltip.battery", { name = name, battery = tostring(bar.battery) }) .. suffix
  end
  return name
end

local function render()
  local hideWhenDisconnected = noctalia.getConfig("hide_when_disconnected") == true
  local showLabel = noctalia.getConfig("show_label") ~= false
  local hidden = hideWhenDisconnected and not bar.present

  local container = isVertical and ui.column or ui.row

  -- Glyph reflects connection state at a glance.
  local glyphName = bar.present and "headphones" or "headphones-off"
  local glyphColor = bar.present and "primary" or "on_surface/0.5"

  local children = { ui.glyph({ name = glyphName, color = glyphColor }) }

  if bar.present and showLabel and bar.battery >= 0 and not isVertical then
    table.insert(children, ui.label({
      text = string.format("%d%%", bar.battery),
      fontWeight = "bold",
      color = batteryColor(),
    }))
  end

  -- A charging bolt is a compact universal cue and works on a vertical bar too.
  if bar.present and bar.charging then
    table.insert(children, ui.glyph({ name = "bolt", size = 12, color = "primary" }))
  end

  barWidget.render(container({ gap = 6, align = "center", visible = not hidden }, children))
  barWidget.setTooltip(tooltipText())
end

function update()
  isVertical = barWidget.isVertical()
  render()
end

noctalia.state.watch("mp.bar", function(value)
  if type(value) == "table" then
    bar = value
  end
  render()
end)

function onClick()
  noctalia.togglePanel(PANEL_ID)
end
