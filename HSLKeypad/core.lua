-- HSL Keypad agent: protocol core (see Control4/PROTOCOL.md).
--
-- Pure logic, no Control4 calls: everything Control4-specific comes in
-- through `deps`, so this file runs unchanged on a controller and in the
-- Mac-side emulator/tests.
--
-- deps = {
--   platform = {
--     info()                          -> { project=, os=, address=, netmask= }
--     catalog()                       -> { rooms=, lights=, fans=, scenes=, macros=, watch=, listen= }
--     state(kind, id)                 -> { on=, level=, speed=, active= } or nil
--     command(kind, id, action, msg)  -> true | false, "message"
--   },
--   store = { get(key) -> value, set(key, value) },   -- persists across reboots
--   send(handle, line), close(handle),                -- to one connected Mac
--   later(seconds, fn),                                -- one-shot timer
--   now() -> seconds, random(m, n) -> integer,
--   log(message),                                      -- optional
--   pairingChanged(),                                  -- optional: tokens changed
-- }

local json = require("json")

local Core = {}
Core.__index = Core

Core.VERSION = "0.0.3"
Core.MAX_LINE = 64 * 1024
Core.MAX_BAD_CODES = 5      -- wrong pairing codes before a lockout
Core.LOCKOUT_SECONDS = 60

local KINDS = { light = true, fan = true, scene = true, macro = true, watch = true, listen = true }

local function hex(random, n)
  local out = {}
  for i = 1, n do out[i] = string.format("%x", random(0, 15)) end
  return table.concat(out)
end

local function uuid(random)
  local h = hex(random, 32)
  return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-4" .. h:sub(14, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end

function Core.new(deps)
  local self = setmetatable({ deps = deps, clients = {}, badCodes = 0, lockedUntil = 0 }, Core)
  local store = deps.store
  self.controllerId = store.get("controllerId")
  if not self.controllerId then
    self.controllerId = uuid(deps.random)
    store.set("controllerId", self.controllerId)
  end
  self.tokens = store.get("tokens") or {}          -- token -> { device=, paired= }
  self.pairingCode = store.get("pairingCode") or self:newPairingCode()
  self.revision = (store.get("revision") or 0) + 1  -- restart = new revision
  store.set("revision", self.revision)
  return self
end

function Core:log(message)
  if self.deps.log then self.deps.log(message) end
end

-- Pairing ---------------------------------------------------------------------

function Core:newPairingCode()
  self.pairingCode = string.format("%06d", self.deps.random(0, 999999))
  self.deps.store.set("pairingCode", self.pairingCode)
  if self.deps.pairingChanged then self.deps.pairingChanged() end
  return self.pairingCode
end

--- Paired Macs, for the Composer property: { {device=, paired=}, ... }
function Core:pairedDevices()
  local list = {}
  for _, info in pairs(self.tokens) do list[#list + 1] = info end
  table.sort(list, function(a, b) return (a.paired or 0) < (b.paired or 0) end)
  return list
end

--- Forgets every Mac (or one by device name) and disconnects it.
function Core:revoke(device)
  for token, info in pairs(self.tokens) do
    if device == nil or info.device == device then self.tokens[token] = nil end
  end
  self.deps.store.set("tokens", self.tokens)
  if self.deps.pairingChanged then self.deps.pairingChanged() end
  for handle, client in pairs(self.clients) do
    if client.token and not self.tokens[client.token] then self:reject(handle, "This Mac was unpaired in Composer.") end
  end
end

-- Connections -----------------------------------------------------------------

function Core:connected(handle)
  self.clients[handle] = { buffer = "", authed = false, watch = {} }
end

function Core:disconnected(handle)
  self.clients[handle] = nil
end

--- Raw bytes from a client; split on newlines (use :line if the transport
--- already delivers one message per call).
function Core:data(handle, chunk)
  local client = self.clients[handle]
  if not client then
    self:connected(handle)
    client = self.clients[handle]
  end
  client.buffer = client.buffer .. chunk
  while true do
    local nl = client.buffer:find("\n", 1, true)
    if not nl then break end
    local line = client.buffer:sub(1, nl - 1)
    client.buffer = client.buffer:sub(nl + 1)
    self:line(handle, line)
    if not self.clients[handle] then return end
  end
  if #client.buffer > Core.MAX_LINE then
    self:reject(handle, "Message too long.")
  end
end

function Core:send(handle, message)
  self.deps.send(handle, json.encode(message) .. "\n")
end

--- Sends an error, then closes once it has had time to go out (closing at
--- once can drop it — see PROTOCOL.md).
function Core:reject(handle, message)
  self:send(handle, { type = "error", code = "unauthorized", message = message })
  local client = self.clients[handle]
  if client then client.authed = false end
  self.deps.later(0.5, function()
    self.clients[handle] = nil
    self.deps.close(handle)
  end)
end

function Core:line(handle, line)
  line = line:gsub("\r$", "")
  if line == "" then return end
  local client = self.clients[handle]
  if not client then
    self:connected(handle)
    client = self.clients[handle]
  end
  local ok, msg = pcall(json.decode, line)
  if not ok or type(msg) ~= "table" then
    self:log("bad message from " .. tostring(handle) .. ": " .. tostring(msg))
    return
  end
  local kind = msg.type
  if kind == "hello" then return self:hello(handle, client, msg) end
  if kind == "ping" then return self:send(handle, { type = "pong" }) end
  if kind == "pong" then return end
  if not client.authed then return self:reject(handle, "Say hello first.") end
  if kind == "catalog" then return self:sendCatalog(handle, msg.ref) end
  if kind == "watch" then return self:watch(handle, client, msg) end
  if kind == "command" then return self:command(handle, msg) end
  self:log("unknown message type " .. tostring(kind))
end

function Core:hello(handle, client, msg)
  local now = self.deps.now()
  local token = type(msg.token) == "string" and msg.token or nil
  if token and self.tokens[token] then
    client.token = token
  elseif type(msg.pairingCode) == "string" then
    if now < self.lockedUntil then
      return self:reject(handle, "Too many wrong pairing codes. Try again in a minute.")
    end
    if msg.pairingCode ~= self.pairingCode then
      self.badCodes = self.badCodes + 1
      if self.badCodes >= Core.MAX_BAD_CODES then
        self.badCodes = 0
        self.lockedUntil = now + Core.LOCKOUT_SECONDS
      end
      return self:reject(handle, "Wrong pairing code.")
    end
    self.badCodes = 0
    token = hex(self.deps.random, 40)
    local device = type(msg.device) == "string" and msg.device or "Mac"
    self.tokens[token] = { device = device, paired = now }
    self.deps.store.set("tokens", self.tokens)
    client.token = token
    if self.deps.pairingChanged then self.deps.pairingChanged() end
    self:log("paired " .. device)
  else
    return self:reject(handle, "This Mac isn't paired. Pair it again in Settings → Control4.")
  end

  client.authed = true
  local info = self.deps.platform.info() or {}
  self:send(handle, {
    type = "welcome",
    controllerId = self.controllerId,
    project = info.project,
    agentVersion = Core.VERSION,
    os = info.os,
    token = client.token,
    address = info.address,
    netmask = info.netmask,
    update = info.update,  -- { version, url } when a newer release exists
  })
  self:sendCatalog(handle)
end

-- Catalog and state -------------------------------------------------------------

function Core:catalogMessage(ref)
  local c = self.deps.platform.catalog() or {}
  return {
    type = "catalog",
    ref = ref,
    revision = self.revision,
    rooms = json.array(c.rooms or {}),
    lights = json.array(c.lights or {}),
    fans = json.array(c.fans or {}),
    scenes = json.array(c.scenes or {}),
    macros = json.array(c.macros or {}),
    watch = json.array(c.watch or {}),
    listen = json.array(c.listen or {}),
  }
end

function Core:sendCatalog(handle, ref)
  self:send(handle, self:catalogMessage(ref))
end

--- Sends a message to every paired, connected Mac.
function Core:broadcast(message)
  for handle, client in pairs(self.clients) do
    if client.authed then self:send(handle, message) end
  end
end

--- The project changed: bump the revision and send everyone the full catalog.
function Core:catalogChanged()
  self.revision = self.revision + 1
  self.deps.store.set("revision", self.revision)
  local message = self:catalogMessage(nil)
  for handle, client in pairs(self.clients) do
    if client.authed then self:send(handle, message) end
  end
end

local function key(kind, id) return kind .. ":" .. tostring(id) end

function Core:stateMessage(kind, id, state)
  local m = { type = "state", kind = kind, id = id }
  for k, v in pairs(state or {}) do m[k] = v end
  return m
end

function Core:watch(handle, client, msg)
  client.watch = {}
  for _, t in ipairs(msg.targets or {}) do
    if KINDS[t.kind] and type(t.id) == "number" then
      client.watch[key(t.kind, t.id)] = true
      local state = self.deps.platform.state(t.kind, t.id)
      if state then self:send(handle, self:stateMessage(t.kind, t.id, state)) end
    end
  end
end

--- A device changed: tell every Mac watching it.
function Core:stateChanged(kind, id, state)
  local k = key(kind, id)
  local message
  for handle, client in pairs(self.clients) do
    if client.authed and client.watch[k] then
      message = message or self:stateMessage(kind, id, state)
      self:send(handle, message)
    end
  end
end

function Core:command(handle, msg)
  local ref = msg.ref
  if not KINDS[msg.kind] or type(msg.id) ~= "number" or type(msg.action) ~= "string" then
    return self:send(handle, { type = "result", ref = ref, ok = false, message = "Malformed command." })
  end
  local ok, result, message = pcall(self.deps.platform.command, msg.kind, msg.id, msg.action, msg)
  if not ok then
    self:log("command failed: " .. tostring(result))
    return self:send(handle, { type = "result", ref = ref, ok = false, message = "The agent hit an error running that." })
  end
  if result then
    self:send(handle, { type = "result", ref = ref, ok = true })
  else
    self:send(handle, { type = "result", ref = ref, ok = false, message = message or "That didn't work." })
  end
end

return Core
