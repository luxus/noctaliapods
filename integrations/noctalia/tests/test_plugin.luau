--!nonstrict
-- Plugin logic driver: feeds real MagicPodsCore protocol messages through the
-- service's stream callback and asserts the bar/panel render trees and the
-- daemon requests the service emits. Concatenated AFTER the entry scripts.

local failures = 0
local function check(name, cond)
  if cond then
    print("PASS: " .. name)
  else
    print("FAIL: " .. name)
    failures += 1
  end
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

-- 1) Bridge connects and the full state is ingested -------------------------
HOST.feed('{"_bridge":{"connected":true}}')
HOST.feed(GETALL)

check("service marks bridge connected", noctalia.state.get("mp.bridge") == true)
check("service marks bluetooth on", noctalia.state.get("mp.bluetooth") == true)
check("service ingests active device", (noctalia.state.get("mp.info") or {}).name == "AirPods Pro")
local barState = noctalia.state.get("mp.bar")
check("bar summary present", type(barState) == "table" and barState.present == true)
check("bar picks lowest earbud battery (72)", barState.battery == 72)

-- 2) Bar widget renders battery label ---------------------------------------
update() -- bar's global update()
check("bar renders 72% label", HOST.findLabel(barWidget.lastTree, "72%"))
check("bar shows headphones glyph", HOST.findGlyph(barWidget.lastTree, "headphones"))
check("bar tooltip mentions device", type(barWidget.lastTooltip) == "string" and barWidget.lastTooltip ~= "")

-- 3) Panel renders and noise-control switching sends the right command ------
onOpen() -- panel's global onOpen()
local ancOff = HOST.findByKey(panel.lastTree, "anc-1")
local ancAdaptive = HOST.findByKey(panel.lastTree, "anc-4")
local ancNoise = HOST.findByKey(panel.lastTree, "anc-16")
check("panel renders Off ANC button", ancOff ~= nil)
check("panel renders Adaptive ANC button", ancAdaptive ~= nil)
check("panel renders NoiseCancellation ANC button", ancNoise ~= nil)
check("selected ANC mode is highlighted", ancNoise ~= nil and ancNoise.props.variant == "primary")
check("unselected ANC mode is outlined", ancAdaptive ~= nil and ancAdaptive.props.variant == "outline")

HOST.click(ancAdaptive)
local req = HOST.lastSent()
check("clicking Adaptive sends SetCapabilities", req ~= nil and req.method == "SetCapabilities")
check("SetCapabilities targets active device", req ~= nil and req.arguments.address == "AA:BB:CC:DD:EE:FF")
check("SetCapabilities selects Adaptive (4)", req ~= nil and req.arguments.capabilities.anc.selected == 4)

-- 4) Battery rows rendered for available parts ------------------------------
check("panel renders a battery progress bar", HOST.findByKind(panel.lastTree, "progress") ~= nil)

-- 5) Connecting a disconnected device sends ConnectDevice -------------------
local gbRow = HOST.findByKey(panel.lastTree, "dev-11:22:33:44:55:66")
check("panel lists the disconnected device", gbRow ~= nil)
local gbButton = HOST.findByKind(gbRow, "button")
HOST.click(gbButton)
local creq = HOST.lastSent()
check("connect sends ConnectDevice", creq ~= nil and creq.method == "ConnectDevice")
check("connect targets the right address", creq ~= nil and creq.arguments.address == "11:22:33:44:55:66")

-- 6) Toggling a feature sends SetCapabilities -------------------------------
local caRow = HOST.findByKey(panel.lastTree, "tgl-conversationAwareness")
check("panel renders conversation-awareness toggle", caRow ~= nil)
local caToggle = HOST.findByKind(caRow, "toggle")
if caToggle ~= nil and type(caToggle.props.onChange) == "function" then
  caToggle.props.onChange("false")
end
local treq = HOST.lastSent()
check("toggle sends SetCapabilities", treq ~= nil and treq.method == "SetCapabilities")
check("toggle sets conversationAwareness=false",
  treq ~= nil and treq.arguments.capabilities.conversationAwareness.selected == false)

-- 7) Live broadcast updates the bar -----------------------------------------
HOST.feed('{"info":{"name":"AirPods Pro","address":"AA:BB:CC:DD:EE:FF","connected":true,"capabilities":{"battery":{"single":{"battery":0,"charging":false,"status":0},"left":{"battery":80,"charging":false,"status":2},"right":{"battery":50,"charging":false,"status":2},"case":{"battery":45,"charging":true,"status":3},"readonly":true},"anc":{"selected":4,"options":23,"readonly":false}}}}')
check("bar reflects live battery drop (50)", (noctalia.state.get("mp.bar") or {}).battery == 50)

-- 8) Daemon offline shows the offline panel ---------------------------------
HOST.feed('{"_bridge":{"connected":false}}')
onOpen()
local retry = nil
HOST.walk(panel.lastTree, function(node)
  if node.kind == "button" and node.props.onClick == "onRefresh" then
    retry = node
  end
end)
check("offline panel shows a retry button", retry ~= nil)
update()
check("bar shows headphones-off when offline", HOST.findGlyph(barWidget.lastTree, "headphones-off"))

if failures > 0 then
  error(string.format("%d plugin logic test(s) failed", failures))
end
print("\nAll plugin logic tests passed")
