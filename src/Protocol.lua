-- Partner Panel: the wire format and name helpers.
-- Pure Lua with no WoW API calls, so tests/test_protocol.lua can run it outside the game.
local _, ns = ...

local P = {}
ns.Protocol = P

P.VERSION = "1"          -- bump when the message format changes incompatibly
P.PREFIX = "PartnerPanel" -- addon message prefix (WoW allows 16 chars)
P.SEP = "\t"
P.MAX_LEN = 255          -- WoW's addon message limit, in bytes
P.MOOD_MAX = 60
P.TEXT_MAX = 40          -- zone / subzone (leaves room for the Battle.net envelope)

-- Cuts a string to at most n bytes without splitting a UTF-8 character.
function P.Truncate(s, n)
    if #s <= n then
        return s
    end
    s = s:sub(1, n)
    local i = #s
    while i > 0 do
        local b = s:byte(i)
        if b < 128 then
            return s -- ends on plain ASCII
        end
        if b >= 192 then -- lead byte of the last character
            local need = (b >= 240 and 4) or (b >= 224 and 3) or 2
            if #s - i + 1 < need then
                return s:sub(1, i - 1)
            end
            return s
        end
        i = i - 1
    end
    return s
end

-- Makes text safe to send: no tabs/newlines/control chars (they'd break the format)
-- and no "|" (WoW's chat escape character), trimmed, optionally length-capped.
function P.Clean(text, maxLen)
    if text == nil then
        return ""
    end
    text = tostring(text)
    text = text:gsub("[%c|]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    if maxLen then
        text = P.Truncate(text, maxLen)
    end
    return text
end

local function split(s, sep)
    local out, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then
            out[#out + 1] = s:sub(start)
            return out
        end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + #sep
    end
end

-- "1<TAB>KIND<TAB>field<TAB>field..."  (nil fields become "")
function P.Encode(kind, ...)
    local parts = { P.VERSION, kind }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = P.Clean((select(i, ...)))
    end
    return table.concat(parts, P.SEP)
end

-- Returns kind, fields  -- or nil if it isn't a message we understand.
function P.Decode(msg)
    if type(msg) ~= "string" or msg == "" then
        return nil
    end
    local parts = split(msg, P.SEP)
    if parts[1] ~= P.VERSION or not parts[2] or parts[2] == "" then
        return nil
    end
    local fields = {}
    for i = 3, #parts do
        fields[#fields + 1] = parts[i]
    end
    return parts[2], fields
end

-- Messages sent on the group channel are heard by everyone in the group, so they're
-- addressed: "@Demo Chan:<message>". Everyone else drops them.
function P.Address(to, msg)
    return "@" .. to .. ":" .. msg
end

function P.Unaddress(msg)
    local to, rest = msg:match("^@([^:]+):(.*)$")
    if to then
        return to, rest
    end
    return nil, msg
end

-- Messages sent through Battle.net also carry who they are from, because Battle.net
-- only tells the receiver an account number, not a character name:
-- "@Demo Chan>Ally Rose:<message>".
function P.WrapBNet(to, from, msg)
    return "@" .. to .. ">" .. from .. ":" .. msg
end

-- Returns to, from, message  -- or nil if it is not a Battle.net envelope.
function P.UnwrapBNet(msg)
    if type(msg) ~= "string" then
        return nil
    end
    return msg:match("^@([^:>]+)>([^:>]+):(.*)$")
end

-- Names. WoW Forever names are a first name + surname, unique per region, no realm:
-- "Demo Chan" (sometimes seen as "Demo-Chan"). Classic-style names are "Name-Realm".
-- `unique` = the client uses Forever-style names.
function P.NormalizeName(name, unique)
    if type(name) ~= "string" then
        return nil
    end
    name = name:gsub("^%s+", "")
    name = name:gsub("%s+$", "")
    if name == "" then
        return nil
    end
    if unique then
        name = name:gsub("%-", " ")
        name = name:gsub("%s+", " ")
        -- capitalize each word's first letter (typed "demo chan" -> "Demo Chan"), keep the rest as-is
        name = name:gsub("(%S)(%S*)", function(first, rest)
            return first:upper() .. rest
        end)
    else
        name = name:sub(1, 1):upper() .. name:sub(2)
    end
    return name
end

function P.SameName(a, b, unique)
    a, b = P.NormalizeName(a, unique), P.NormalizeName(b, unique)
    return a ~= nil and b ~= nil and a:lower() == b:lower()
end

-- Status flags packed as letters.
local FLAGS = {
    { key = "afk", char = "a" },
    { key = "dnd", char = "d" },
    { key = "combat", char = "c" },
    { key = "dead", char = "x" },
    { key = "ghost", char = "g" },
    { key = "resting", char = "r" },
}

function P.EncodeFlags(flags)
    local out = {}
    if flags then
        for _, f in ipairs(FLAGS) do
            if flags[f.key] then
                out[#out + 1] = f.char
            end
        end
    end
    return table.concat(out)
end

function P.DecodeFlags(s)
    local flags = {}
    if type(s) == "string" then
        for _, f in ipairs(FLAGS) do
            if s:find(f.char, 1, true) then
                flags[f.key] = true
            end
        end
    end
    return flags
end

-- STATUS fields: level, class, zone, subzone, flags, hp%, mood
function P.EncodeStatus(s)
    local hp = ""
    if type(s.hp) == "number" then
        hp = tostring(math.floor(s.hp + 0.5))
    end
    return P.Encode("STATUS",
        s.level or "",
        s.class or "",
        P.Clean(s.zone, P.TEXT_MAX),
        P.Clean(s.subzone, P.TEXT_MAX),
        P.EncodeFlags(s.flags),
        hp,
        P.Clean(s.mood, P.MOOD_MAX))
end

function P.DecodeStatus(fields)
    local hp = tonumber(fields[6])
    if hp then
        hp = math.max(0, math.min(100, hp))
    end
    local class = P.Clean(fields[2])
    return {
        level = tonumber(fields[1]),
        class = class ~= "" and class or nil,
        zone = P.Clean(fields[3], P.TEXT_MAX),
        subzone = P.Clean(fields[4], P.TEXT_MAX),
        flags = P.DecodeFlags(fields[5]),
        hp = hp,
        mood = P.Clean(fields[7], P.MOOD_MAX),
    }
end
