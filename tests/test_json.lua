local json = require("json")

-- Encoding
check(json.encode({ type = "pong" }) == '{"type":"pong"}', "simple object")
check(json.encode({ 1, 2, 3 }) == "[1,2,3]", "array")
check(json.encode({}) == "{}", "empty table is an object")
check(json.encode(json.array({})) == "[]", "marked empty array")
check(json.encode({ a = json.array({}) }) == '{"a":[]}', "nested empty array")
check(json.encode(42) == "42" and json.encode(-7) == "-7", "integers have no decimal point")
check(json.encode(0.5) == "0.5", "fraction")
check(json.encode(true) == "true" and json.encode(json.null) == "null", "bool and null")
check(json.encode('a"b\\c\nd') == '"a\\"b\\\\c\\nd"', "string escapes")
check(json.encode("\1") == '"\\u0001"', "control character escape")
check(json.encode("Kitchen · Cans") == '"Kitchen · Cans"', "UTF-8 passes through")
check(json.encode({ b = 1, a = 2 }) == '{"a":2,"b":1}', "keys sorted")
check(not pcall(json.encode, { [true] = 1 }), "rejects non-string keys")
local cyc = {}; cyc.self = cyc
check(not pcall(json.encode, cyc), "rejects cycles")

-- Decoding
local m = json.decode('{"type":"hello","token":"abc","n":3,"f":1.5,"ok":true,"nil":null,"list":[1,"two",{"x":false}]}')
check(m.type == "hello" and m.token == "abc" and m.n == 3 and m.f == 1.5 and m.ok == true, "decode scalars")
check(m["nil"] == json.null, "decode null")
check(m.list[1] == 1 and m.list[2] == "two" and m.list[3].x == false, "decode nested array")
check(json.decode('  [ ]  ')[1] == nil and json.encode(json.decode("[]")) == "[]", "empty array round trip")
check(json.encode(json.decode("{}")) == "{}", "empty object round trip")
check(json.decode('"a\\u00e9\\n"') == "a\195\169\n", "unicode escape to UTF-8")
check(json.decode('"\\ud83d\\ude00"') == "\240\159\152\128", "surrogate pair")
check(json.decode("-12.5e2") == -1250, "exponent")
check(not pcall(json.decode, '{"a":1,}'), "rejects trailing comma")
check(not pcall(json.decode, '{"a":1} x'), "rejects trailing characters")
check(not pcall(json.decode, '"open'), "rejects unterminated string")
check(not pcall(json.decode, "{a:1}"), "rejects unquoted key")

-- Round trip of a real protocol message
local catalog = { type = "catalog", revision = 3, lights = json.array({ { id = 345, room = 12, name = "Cans", dimmable = true } }), macros = json.array({}) }
local back = json.decode(json.encode(catalog))
check(back.lights[1].name == "Cans" and back.revision == 3 and #back.macros == 0, "catalog round trip")
