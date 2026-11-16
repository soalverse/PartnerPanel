-- Unit tests for src/Protocol.lua (pure Lua, runs outside WoW).
-- Run from the project root:  luajit tests/test_protocol.lua
local ns = {}
local chunk = assert(loadfile("src/Protocol.lua"))
chunk("PartnerPanel", ns)
local P = ns.Protocol

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. name .. "\n      " .. tostring(err))
    end
end
local function eq(actual, expected, label)
    if actual ~= expected then
        error(("%sexpected %q, got %q"):format(label and (label .. ": ") or "", tostring(expected), tostring(actual)), 2)
    end
end

test("encode/decode round trip", function()
    local kind, fields = P.Decode(P.Encode("HELLO", "0.1.0", "x"))
    eq(kind, "HELLO")
    eq(#fields, 2)
    eq(fields[1], "0.1.0")
    eq(fields[2], "x")
end)

test("nil fields encode as empty", function()
    local kind, fields = P.Decode(P.Encode("X", nil, "b"))
    eq(kind, "X")
    eq(fields[1], "")
    eq(fields[2], "b")
end)

test("message with no fields", function()
    local kind, fields = P.Decode(P.Encode("UNLINK"))
    eq(kind, "UNLINK")
    eq(#fields, 0)
end)

test("decode rejects garbage and other versions", function()
    eq(P.Decode(nil), nil)
    eq(P.Decode(""), nil)
    eq(P.Decode("hello there"), nil)
    eq(P.Decode("2\tHELLO\tx"), nil)
    eq(P.Decode("1\t"), nil)
end)

test("clean strips tabs, newlines, pipes and trims", function()
    eq(P.Clean("  a\tb\nc|d  "), "a b c d")
    eq(P.Clean(nil), "")
    eq(P.Clean(42), "42")
end)

test("user text can't inject extra fields", function()
    local kind, fields = P.Decode(P.Encode("STATUS", "a\tb"))
    eq(kind, "STATUS")
    eq(#fields, 1)
end)

test("truncate keeps whole UTF-8 characters", function()
    eq(P.Truncate("abc", 5), "abc")
    eq(P.Truncate("abcdef", 3), "abc")
    -- "é" is 2 bytes: cutting after its first byte must drop it entirely
    eq(P.Truncate("ab\195\169", 3), "ab")
    eq(P.Truncate("ab\195\169", 4), "ab\195\169")
    -- a 3-byte character cut in the middle
    eq(P.Truncate("a\226\130\172b", 3), "a")
end)

test("address / unaddress", function()
    local msg = P.Address("Demo Chan", "1\tHELLO")
    local to, body = P.Unaddress(msg)
    eq(to, "Demo Chan")
    eq(body, "1\tHELLO")
    local none, raw = P.Unaddress("1\tHELLO")
    eq(none, nil)
    eq(raw, "1\tHELLO")
end)

test("forever names normalize and compare", function()
    eq(P.NormalizeName("demo chan", true), "Demo Chan")
    eq(P.NormalizeName("Demo-Chan", true), "Demo Chan")
    eq(P.NormalizeName("  Demo   Chan ", true), "Demo Chan")
    eq(P.NormalizeName("McKenzie Rose", true), "McKenzie Rose")
    eq(P.NormalizeName("", true), nil)
    eq(P.NormalizeName(nil, true), nil)
    eq(P.SameName("demo-chan", "Demo Chan", true), true)
    eq(P.SameName("Demo Chan", "Demo Chen", true), false)
    eq(P.SameName(nil, "Demo Chan", true), false)
end)

test("classic names keep their realm", function()
    eq(P.NormalizeName("bob-Stormrage", false), "Bob-Stormrage")
    eq(P.SameName("Bob-Stormrage", "bob-stormrage", false), true)
end)

test("flags round trip", function()
    local flags = P.DecodeFlags(P.EncodeFlags({ afk = true, combat = true }))
    eq(flags.afk, true)
    eq(flags.combat, true)
    eq(flags.dead, nil)
    eq(P.EncodeFlags(nil), "")
end)

test("status round trip", function()
    local kind, fields = P.Decode(P.EncodeStatus({
        level = 12, class = "PALADIN", zone = "Elwynn Forest", subzone = "Goldshire",
        flags = { resting = true }, hp = 87.6, mood = "hi <3",
    }))
    eq(kind, "STATUS")
    local s = P.DecodeStatus(fields)
    eq(s.level, 12)
    eq(s.class, "PALADIN")
    eq(s.zone, "Elwynn Forest")
    eq(s.subzone, "Goldshire")
    eq(s.flags.resting, true)
    eq(s.hp, 88)
    eq(s.mood, "hi <3")
end)

test("status without health or class", function()
    local _, fields = P.Decode(P.EncodeStatus({ zone = "Westfall", flags = { combat = true } }))
    local s = P.DecodeStatus(fields)
    eq(s.hp, nil)
    eq(s.class, nil)
    eq(s.level, nil)
    eq(s.flags.combat, true)
end)

test("decoded status is sanitized and clamped", function()
    local s = P.DecodeStatus({ "5", "MAGE", "Zone|cffff0000", "", "", "250", "x|ry" })
    eq(s.zone, "Zone cffff0000")
    eq(s.hp, 100)
    eq(s.mood, "x ry")
end)

test("long moods are capped", function()
    local _, fields = P.Decode(P.EncodeStatus({ mood = string.rep("a", 200), flags = {} }))
    eq(#P.DecodeStatus(fields).mood, P.MOOD_MAX)
end)

test("worst-case addressed status fits in one addon message", function()
    local msg = P.Address(string.rep("N", 30), P.EncodeStatus({
        level = 60, class = "DEATHKNIGHT", zone = string.rep("z", 100), subzone = string.rep("s", 100),
        flags = { afk = true, dnd = true, combat = true, dead = true, ghost = true, resting = true },
        hp = 100, mood = string.rep("m", 100),
    }))
    assert(#msg <= P.MAX_LEN, "message is " .. #msg .. " bytes")
end)

test("Battle.net envelope round trip", function()
    local msg = P.WrapBNet("Demo Chan", "Ally Rose", "1\tHELLO\t0.2.0")
    local to, from, body = P.UnwrapBNet(msg)
    eq(to, "Demo Chan")
    eq(from, "Ally Rose")
    eq(body, "1\tHELLO\t0.2.0")
end)

test("Battle.net unwrap rejects group-style and garbage", function()
    eq(P.UnwrapBNet("@Demo Chan:1\tHELLO"), nil)
    eq(P.UnwrapBNet("1\tHELLO"), nil)
    eq(P.UnwrapBNet(nil), nil)
end)

test("old group parser ignores Battle.net envelopes (no cross-talk)", function()
    local to = P.Unaddress(P.WrapBNet("Demo Chan", "Ally Rose", "1\tHELLO"))
    assert(to ~= "Demo Chan", "a v0.1 reader must not treat it as addressed to Demo Chan")
end)

test("worst-case Battle.net status fits in one message", function()
    local msg = P.WrapBNet(string.rep("N", 30), string.rep("F", 30), P.EncodeStatus({
        level = 60, class = "DEATHKNIGHT", zone = string.rep("z", 100), subzone = string.rep("s", 100),
        flags = { afk = true, dnd = true, combat = true, dead = true, ghost = true, resting = true },
        hp = 100, mood = string.rep("m", 100),
    }))
    assert(#msg <= P.MAX_LEN, "message is " .. #msg .. " bytes")
end)

-- Pings
test("ping round trip keeps the spot to a hair", function()
    local kind, fields = P.Decode(P.EncodePing({ kind = "come", map = 1453, x = 0.66785669, y = 0.72329741 }))
    eq(kind, "PING")
    local p = P.DecodePing(fields)
    eq(p.kind, "come")
    eq(p.map, 1453)
    assert(math.abs(p.x - 0.66785669) < 0.0001 and math.abs(p.y - 0.72329741) < 0.0001, p.x .. "," .. p.y)
    eq(p.label, nil)
end)

test("ping carries a label, cleaned and capped", function()
    local _, fields = P.Decode(P.EncodePing({ kind = "watch", map = 1, x = 0.5, y = 0.5,
        label = "Hogger|r\t" .. string.rep("x", 100) }))
    local p = P.DecodePing(fields)
    eq(p.label:sub(1, 8), "Hogger r")
    assert(#p.label <= P.LABEL_MAX, #p.label)
end)

test("ping stop needs no place", function()
    local _, fields = P.Decode(P.EncodePing({ kind = "stop" }))
    eq(P.DecodePing(fields).kind, "stop")
end)

test("ping rejects unknown kinds and bad places", function()
    eq(P.DecodePing({ "dance", "1", "5000", "5000" }), nil)
    eq(P.DecodePing({ "come", "", "5000", "5000" }), nil)
    eq(P.DecodePing({ "come", "0", "5000", "5000" }), nil)
    eq(P.DecodePing({ "come", "1", "-1", "5000" }), nil)
    eq(P.DecodePing({ "come", "1", "5000", "10001" }), nil)
    eq(P.DecodePing({}), nil)
end)

test("ping spot off the map edge is pulled back onto it", function()
    local _, fields = P.Decode(P.EncodePing({ kind = "come", map = 1, x = 1.5, y = -0.2 }))
    local p = P.DecodePing(fields)
    eq(p.x, 1)
    eq(p.y, 0)
end)

test("worst-case Battle.net ping fits in one message", function()
    local msg = P.WrapBNet(string.rep("N", 30), string.rep("F", 30),
        P.EncodePing({ kind = "follow", map = 99999, x = 0.123456, y = 0.654321, label = string.rep("L", 100) }))
    assert(#msg <= P.MAX_LEN, "message is " .. #msg .. " bytes")
end)

-- "Should I keep this?"
test("item string comes out of a full item link", function()
    local link = "|cffffffff|Hitem:19422::::::::60:::::|h[Darkmoon Faire Fortune]|h|r"
    eq(P.ItemString(link), "item:19422::::::::60")
    eq(P.ItemID(P.ItemString(link)), 19422)
end)

test("item string survives the trip, links do not", function()
    local item = P.ItemString("|Hitem:12345:0:0:0|h[Sword]|h")
    local _, fields = P.Decode(P.Encode("ASK", item))
    eq(fields[1], "item:12345:0:0:0")
    eq(P.ItemID(fields[1]), 12345)
end)

test("item string rejects text with no item in it", function()
    eq(P.ItemString("just some words"), nil)
    eq(P.ItemString(nil), nil)
    eq(P.ItemString("item:"), nil)
    eq(P.ItemID("item:0"), nil)
end)

test("only the four answers are answers", function()
    assert(P.IsAnswer("equip") and P.IsAnswer("sell") and P.IsAnswer("keep") and P.IsAnswer("bank"))
    assert(not P.IsAnswer("Keep") and not P.IsAnswer("eat") and not P.IsAnswer(nil))
end)

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
