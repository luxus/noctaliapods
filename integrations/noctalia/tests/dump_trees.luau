--!nonstrict
-- Emits the plugin's ACTUAL render trees as JSON on stdout (functions omitted),
-- for the approximate layout preview in render_preview.py. Concatenated after
-- host_stub + entry scripts.

local function esc(s)
  return (string.gsub(tostring(s), '[%z\1-\31"\\]', function(c)
    if c == '"' then
      return '\\"'
    elseif c == "\\" then
      return "\\\\"
    elseif c == "\n" then
      return "\\n"
    else
      return string.format("\\u%04x", string.byte(c))
    end
  end))
end

local function toJson(v)
  local t = type(v)
  if t == "table" then
    local isArray = true
    local count = 0
    for k in pairs(v) do
      count += 1
      if type(k) ~= "number" then
        isArray = false
      end
    end
    if isArray and count > 0 then
      local parts = {}
      for _, e in ipairs(v) do
        parts[#parts + 1] = toJson(e)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do
      if type(val) ~= "function" then
        parts[#parts + 1] = '"' .. esc(k) .. '":' .. toJson(val)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return '"' .. esc(v) .. '"'
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  end
  return "null"
end

local GETALL = [[
{"headphones":[
  {"name":"AirPods Pro","address":"AA:BB:CC:DD:EE:FF","vendor":76,"model":8207,"color":0,"connected":true},
  {"name":"Galaxy Buds 3","address":"11:22:33:44:55:66","vendor":117,"model":9,"color":0,"connected":false}],
 "defaultbluetooth":{"enabled":true},
 "info":{"name":"AirPods Pro","address":"AA:BB:CC:DD:EE:FF","vendor":76,"model":8207,"color":0,"connected":true,
   "capabilities":{
     "battery":{"single":{"battery":0,"charging":false,"status":0},
       "left":{"battery":80,"charging":false,"status":2},
       "right":{"battery":72,"charging":false,"status":2},
       "case":{"battery":45,"charging":true,"status":3},"readonly":true},
     "anc":{"selected":16,"options":23,"readonly":false},
     "conversationAwareness":{"selected":true,"readonly":false},
     "personalizedVolume":{"selected":false,"readonly":false}}}}
]]

-- Use the real English labels for the preview (the test stub returns raw keys).
local T = {
  ["panel.battery"] = "Battery",
  ["panel.noise_control"] = "Noise control",
  ["panel.features"] = "Features",
  ["panel.devices"] = "Devices",
  ["panel.refresh"] = "Refresh",
  ["battery.left"] = "Left",
  ["battery.right"] = "Right",
  ["battery.case"] = "Case",
  ["battery.single"] = "Battery",
  ["anc.off"] = "Off",
  ["anc.transparency"] = "Transparency",
  ["anc.adaptive"] = "Adaptive",
  ["anc.noise_cancellation"] = "Noise cancel",
  ["toggles.conversation_awareness"] = "Conversation awareness",
  ["toggles.personalized_volume"] = "Personalized volume",
  ["toggles.anc_one_airpod"] = "Noise cancellation with one AirPod",
  ["devices.connect"] = "Connect",
  ["devices.disconnect"] = "Disconnect",
}
noctalia.tr = function(key, subst)
  local v = T[key] or key
  if type(subst) == "table" then
    for k, val in pairs(subst) do
      v = string.gsub(v, "{" .. k .. "}", tostring(val))
    end
  end
  return v
end

HOST.feed('{"_bridge":{"connected":true}}')
HOST.feed(GETALL)
onOpen()
print("PANEL_CONNECTED=" .. toJson(panel.lastTree))
update()
print("BAR_CONNECTED=" .. toJson(barWidget.lastTree))
