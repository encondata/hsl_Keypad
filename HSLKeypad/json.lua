-- Minimal JSON for the HSL Keypad agent (Lua 5.1, no dependencies).
-- Bundled so the agent doesn't rely on a built-in JSON API that may differ
-- between OS 3.4 and X4.
--
--   json.encode(value)  -> string
--   json.decode(string) -> value (raises on malformed input)
--   json.null           -> sentinel for JSON null
--   json.array(t)       -> marks t as an array (so {} encodes as [])
--   json.object(t)      -> marks t as an object (so {} encodes as {})

local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end })

local ARRAY, OBJECT = { "array" }, { "object" }

function json.array(t)
  return setmetatable(t or {}, { __jsontype = ARRAY })
end

function json.object(t)
  return setmetatable(t or {}, { __jsontype = OBJECT })
end

-- Encoding -------------------------------------------------------------------

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function isArray(t)
  local mt = getmetatable(t)
  if mt and mt.__jsontype == ARRAY then return true end
  if mt and mt.__jsontype == OBJECT then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  if n == 0 then return false end  -- {} is an object unless marked
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local encodeValue

local function encodeTable(t, seen)
  if seen[t] then error("json: cannot encode a cycle") end
  seen[t] = true
  local parts = {}
  if isArray(t) then
    for i = 1, #t do parts[#parts + 1] = encodeValue(t[i], seen) end
    seen[t] = nil
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(t) do
    if type(k) ~= "string" and type(k) ~= "number" then error("json: object keys must be strings") end
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)  -- stable output, easier to test and diff
  for _, k in ipairs(keys) do
    local v = t[k]
    if v == nil then v = t[tonumber(k)] end
    parts[#parts + 1] = encodeString(k) .. ":" .. encodeValue(v, seen)
  end
  seen[t] = nil
  return "{" .. table.concat(parts, ",") .. "}"
end

encodeValue = function(v, seen)
  local kind = type(v)
  if v == nil or v == json.null then return "null"
  elseif kind == "boolean" then return v and "true" or "false"
  elseif kind == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("json: cannot encode NaN or infinity") end
    if v % 1 == 0 and v > -1e15 and v < 1e15 then return string.format("%d", v) end
    return string.format("%.14g", v)
  elseif kind == "string" then return encodeString(v)
  elseif kind == "table" then return encodeTable(v, seen)
  end
  error("json: cannot encode a " .. kind)
end

function json.encode(value)
  return encodeValue(value, {})
end

-- Decoding -------------------------------------------------------------------

local function decodeError(str, pos, msg)
  error(string.format("json: %s at position %d", msg, pos), 0)
end

local function skip(str, pos)
  return str:find("[^ \t\r\n]", pos) or #str + 1
end

local decodeValue

local function codepointToUtf8(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40) end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  end
  return string.char(0xF0 + math.floor(n / 0x40000), 0x80 + math.floor(n / 0x1000) % 0x40,
    0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
end

local function decodeString(str, pos)
  local out, i = {}, pos + 1
  while true do
    local c = str:sub(i, i)
    if c == "" then decodeError(str, pos, "unterminated string") end
    if c == '"' then return table.concat(out), i + 1 end
    if c == "\\" then
      local e = str:sub(i + 1, i + 1)
      local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
      if simple[e] then
        out[#out + 1] = simple[e]
        i = i + 2
      elseif e == "u" then
        local hex = str:sub(i + 2, i + 5)
        if not hex:match("^%x%x%x%x$") then decodeError(str, i, "bad \\u escape") end
        local n = tonumber(hex, 16)
        i = i + 6
        -- surrogate pair
        if n >= 0xD800 and n <= 0xDBFF and str:sub(i, i + 1) == "\\u" then
          local lo = tonumber(str:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            n = 0x10000 + (n - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        out[#out + 1] = codepointToUtf8(n)
      else
        decodeError(str, i, "bad escape")
      end
    else
      local j = str:find('["\\]', i) or #str + 1
      out[#out + 1] = str:sub(i, j - 1)
      i = j
    end
  end
end

local function decodeNumber(str, pos)
  local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
  if not num or num == "" or num == "-" then decodeError(str, pos, "bad number") end
  local n = tonumber(num)
  if not n then decodeError(str, pos, "bad number") end
  return n, pos + #num
end

local function decodeArray(str, pos)
  local arr, i = json.array({}), skip(str, pos + 1)
  if str:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local v
    v, i = decodeValue(str, i)
    arr[#arr + 1] = v
    i = skip(str, i)
    local c = str:sub(i, i)
    if c == "]" then return arr, i + 1 end
    if c ~= "," then decodeError(str, i, "expected ',' or ']'") end
    i = skip(str, i + 1)
  end
end

local function decodeObject(str, pos)
  local obj, i = json.object({}), skip(str, pos + 1)
  if str:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    if str:sub(i, i) ~= '"' then decodeError(str, i, "expected a key") end
    local key
    key, i = decodeString(str, i)
    i = skip(str, i)
    if str:sub(i, i) ~= ":" then decodeError(str, i, "expected ':'") end
    local v
    v, i = decodeValue(str, skip(str, i + 1))
    obj[key] = v
    i = skip(str, i)
    local c = str:sub(i, i)
    if c == "}" then return obj, i + 1 end
    if c ~= "," then decodeError(str, i, "expected ',' or '}'") end
    i = skip(str, i + 1)
  end
end

decodeValue = function(str, pos)
  pos = skip(str, pos)
  local c = str:sub(pos, pos)
  if c == "{" then return decodeObject(str, pos) end
  if c == "[" then return decodeArray(str, pos) end
  if c == '"' then return decodeString(str, pos) end
  if c == "-" or c:match("%d") then return decodeNumber(str, pos) end
  if str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
  if str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
  if str:sub(pos, pos + 3) == "null" then return json.null, pos + 4 end
  decodeError(str, pos, "unexpected character")
end

function json.decode(str)
  if type(str) ~= "string" then error("json: decode expects a string", 2) end
  local value, pos = decodeValue(str, 1)
  pos = skip(str, pos)
  if pos <= #str then decodeError(str, pos, "trailing characters") end
  return value
end

return json
