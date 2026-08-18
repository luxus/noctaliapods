--!nonstrict
-- Test host: a faithful-enough stub of the Noctalia plugin runtime so the real
-- service/bar/panel scripts run unmodified under the standalone `luau` binary.
-- Concatenated BEFORE the entry scripts and the driver (see run.sh).

HOST = {
  config = {
    daemon_url = "ws://127.0.0.1:2020",
    battery_source = "auto",
    hide_when_disconnected = false,
    show_label = true,
  },
  logs = {},
  sent = {}, -- daemon requests the service tried to send (captured at json.encode)
  streamOnLine = nil,
  streamCmd = nil,
  toggled = nil,
}

-- Minimal JSON decoder (objects, arrays, strings, numbers, bool, null).
local function jsonDecode(str)
  if type(str) ~= "string" then
    return nil
  end
  local pos = 1
  local parseValue

  local function peek()
    return string.sub(str, pos, pos)
  end
  local function skipWs()
    while pos <= #str do
      local c = string.sub(str, pos, pos)
      if c == " " or c == "\t" or c == "\n" or c == "\r" then
        pos = pos + 1
      else
        break
      end
    end
  end
  local function parseString()
    pos = pos + 1 -- opening quote
    local buf = {}
    while pos <= #str do
      local c = string.sub(str, pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(buf)
      elseif c == "\\" then
        local n = string.sub(str, pos + 1, pos + 1)
        local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
        if map[n] then
          buf[#buf + 1] = map[n]
          pos = pos + 2
        elseif n == "u" then
          local code = tonumber(string.sub(str, pos + 2, pos + 5), 16) or 0
          buf[#buf + 1] = string.char(code % 256)
          pos = pos + 6
        else
          buf[#buf + 1] = n
          pos = pos + 2
        end
      else
        buf[#buf + 1] = c
        pos = pos + 1
      end
    end
    error("unterminated string")
  end
  local function parseNumber()
    local start = pos
    while pos <= #str do
      local c = string.sub(str, pos, pos)
      if string.find(c, "[%d%+%-%.eE]") then
        pos = pos + 1
      else
        break
      end
    end
    return tonumber(string.sub(str, start, pos - 1))
  end

  parseValue = function()
    skipWs()
    local c = peek()
    if c == "{" then
      pos = pos + 1
      local obj = {}
      skipWs()
      if peek() == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        skipWs()
        local key = parseString()
        skipWs()
        pos = pos + 1 -- ':'
        obj[key] = parseValue()
        skipWs()
        local d = peek()
        pos = pos + 1
        if d == "}" then
          return obj
        elseif d ~= "," then
          error("expected , or }")
        end
      end
    elseif c == "[" then
      pos = pos + 1
      local arr = {}
      skipWs()
      if peek() == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        arr[#arr + 1] = parseValue()
        skipWs()
        local d = peek()
        pos = pos + 1
        if d == "]" then
          return arr
        elseif d ~= "," then
          error("expected , or ]")
        end
      end
    elseif c == '"' then
      return parseString()
    elseif c == "t" then
      pos = pos + 4
      return true
    elseif c == "f" then
      pos = pos + 5
      return false
    elseif c == "n" then
      pos = pos + 4
      return nil
    else
      return parseNumber()
    end
  end

  local ok, result = pcall(parseValue)
  if not ok then
    return nil
  end
  return result
end

-- noctalia.state channel ------------------------------------------------------
local store = {}
local watchers = {}

-- ui.* constructors return inspectable nodes -----------------------------------
local function container(kind)
  return function(props, children)
    return { kind = kind, props = props or {}, children = children or {} }
  end
end
local function leaf(kind)
  return function(props)
    return { kind = kind, props = props or {}, children = {} }
  end
end

ui = {
  column = container("column"),
  row = container("row"),
  scroll = container("scroll"),
  label = leaf("label"),
  glyph = leaf("glyph"),
  button = leaf("button"),
  toggle = leaf("toggle"),
  slider = leaf("slider"),
  select = leaf("select"),
  input = leaf("input"),
  progress = leaf("progress"),
  separator = leaf("separator"),
  spacer = leaf("spacer"),
  image = leaf("image"),
  box = leaf("box"),
}

barWidget = {
  lastTree = nil,
  lastTooltip = nil,
  vertical = false,
  render = function(tree)
    barWidget.lastTree = tree
  end,
  setTooltip = function(text)
    barWidget.lastTooltip = text
  end,
  clearTooltip = function()
    barWidget.lastTooltip = nil
  end,
  isVertical = function()
    return barWidget.vertical
  end,
  setText = function() end,
  setGlyph = function() end,
  setImage = function() end,
}

panel = {
  lastTree = nil,
  closed = false,
  render = function(tree)
    panel.lastTree = tree
  end,
  close = function()
    panel.closed = true
  end,
}

noctalia = {
  setUpdateInterval = function() end,
  log = function(msg)
    table.insert(HOST.logs, tostring(msg))
  end,
  notify = function() end,
  notifyError = function() end,
  getConfig = function(key)
    return HOST.config[key]
  end,
  commandExists = function()
    return true
  end,
  pluginDir = function()
    return "/tmp/magicpods"
  end,
  togglePanel = function(id)
    HOST.toggled = id
  end,
  tr = function(key, subst)
    if type(subst) == "table" then
      local s = key
      for k, v in pairs(subst) do
        s = string.gsub(s, "{" .. k .. "}", tostring(v))
      end
      return s
    end
    return key
  end,
  trp = function(key)
    return key
  end,
  runStream = function(cmd, onLine)
    HOST.streamCmd = cmd
    HOST.streamOnLine = onLine
    return true
  end,
  runAsync = function(cmd, cb)
    HOST.lastAsyncCmd = cmd
    if cb then
      cb({ exitCode = 0, stdout = "", stderr = "", timedOut = false })
    end
    return true
  end,
  json = {
    decode = jsonDecode,
    encode = function(value)
      table.insert(HOST.sent, value)
      return "<encoded-json>"
    end,
  },
  string = {
    trim = function(s)
      return (string.gsub(tostring(s), "^%s*(.-)%s*$", "%1"))
    end,
    urlEncode = function(s)
      return tostring(s)
    end,
  },
  state = {
    set = function(key, value)
      store[key] = value
      local list = watchers[key]
      if list then
        for _, fn in ipairs(list) do
          fn(value)
        end
      end
    end,
    get = function(key)
      return store[key]
    end,
    watch = function(key, fn)
      watchers[key] = watchers[key] or {}
      table.insert(watchers[key], fn)
    end,
  },
}

-- Driver helpers --------------------------------------------------------------
function HOST.feed(line)
  if HOST.streamOnLine then
    HOST.streamOnLine(line)
  end
end

function HOST.lastSent()
  return HOST.sent[#HOST.sent]
end

function HOST.walk(node, visit)
  if type(node) ~= "table" then
    return
  end
  visit(node)
  if type(node.children) == "table" then
    for _, child in ipairs(node.children) do
      HOST.walk(child, visit)
    end
  end
end

function HOST.findByKey(tree, key)
  local found = nil
  HOST.walk(tree, function(node)
    if found == nil and type(node.props) == "table" and node.props.key == key then
      found = node
    end
  end)
  return found
end

function HOST.findByKind(tree, kind)
  local found = nil
  HOST.walk(tree, function(node)
    if found == nil and node.kind == kind then
      found = node
    end
  end)
  return found
end

function HOST.findLabel(tree, text)
  local found = false
  HOST.walk(tree, function(node)
    if node.kind == "label" and node.props.text == text then
      found = true
    end
  end)
  return found
end

function HOST.findGlyph(tree, name)
  local found = false
  HOST.walk(tree, function(node)
    if node.kind == "glyph" and node.props.name == name then
      found = true
    end
  end)
  return found
end

function HOST.click(node)
  local cb = node ~= nil and node.props ~= nil and node.props.onClick or nil
  if type(cb) == "function" then
    cb()
  elseif type(cb) == "string" then
    (_G[cb])()
  end
end
