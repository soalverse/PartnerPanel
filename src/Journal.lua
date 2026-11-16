-- Partner Panel: the partner journal. A scrapbook of your firsts together, shared by
-- every character on the account, one page per partner.
--   Each page keeps: the links (which of your characters, from when to when, and time
--   spent online together), and the firsts (date, words, and which character saw it).
-- Nothing is sent anywhere: each of you keeps your own journal from what your game sees.
local _, ns = ...

local Journal = {}
ns.Journal = Journal

local TICK = 60 -- seconds between "still together" counts

local function call(fn, ...)
    if not fn then
        return nil
    end
    local ok, a, b = pcall(fn, ...)
    if ok then
        return a, b
    end
    return nil
end

local function plain(v)
    return v ~= nil and not ns.IsSecret(v)
end

local function store()
    return ns.accountDB and ns.accountDB.journal
end

function Journal.Key(name)
    return type(name) == "string" and name:lower() or nil
end

-- A partner's page, made if it is not there yet.
function Journal.Page(name)
    local j = store()
    local key = Journal.Key(name)
    if not (j and key) then
        return nil
    end
    local p = j[key]
    if not p then
        p = { name = name, links = {}, firsts = {}, seen = {} }
        j[key] = p
    end
    return p
end

local function me()
    return ns.MyName()
end

local function myClassName()
    local ok, localized = pcall(UnitClass, "player")
    if ok and type(localized) == "string" and plain(localized) then
        return localized
    end
    return nil
end

local function openLink(p, my)
    for i = #p.links, 1, -1 do
        local l = p.links[i]
        if l.me == my and not l.to then
            return l
        end
    end
    return nil
end

-- `known` is false for a link made before the journal existed: its real date is lost.
local function startLink(name, known)
    local my = me()
    local p = my and Journal.Page(name)
    if not p then
        return nil
    end
    local l = openLink(p, my)
    if l then
        return l
    end
    l = { me = my, myClass = myClassName(), from = time(), fromKnown = known and true or false, together = 0 }
    p.links[#p.links + 1] = l
    p.lastAt = time()
    ns.Fire("JOURNAL_UPDATED")
    return l
end

local function endLink(name)
    local j, my = store(), me()
    local p = j and my and j[Journal.Key(name)]
    local l = p and openLink(p, my)
    if l then
        l.to = time()
        p.lastAt = time()
        ns.Fire("JOURNAL_UPDATED")
    end
end

-- Writes a first on the current partner's page, once: `seenKey` stops it repeating.
function Journal.Record(seenKey, text)
    local partner = ns.db and ns.db.partner
    if not partner or (ns.Demo and ns.Demo.active) then
        return false
    end
    local p = Journal.Page(partner)
    if not p or p.seen[seenKey] then
        return false
    end
    p.seen[seenKey] = time()
    p.firsts[#p.firsts + 1] = { at = time(), text = text, me = me() }
    p.lastAt = time()
    ns.Fire("JOURNAL_UPDATED")
    return true
end

---------------------------------------------------------------------------
-- Noticing firsts
---------------------------------------------------------------------------
local function partnerStatus()
    local st = ns.partnerState
    return st and st.online and st.status or nil
end

local function grouped()
    return ns.db and ns.db.partner and ns.FindGroupUnit(ns.db.partner) ~= nil
end

-- Zones, dungeons and raids: both of you in the same place at the same time.
local function checkPlace()
    local s = partnerStatus()
    local zone = call(GetRealZoneText)
    if not (s and type(zone) == "string" and plain(zone) and zone ~= "" and s.zone == zone) then
        return
    end
    local name, kind = call(GetInstanceInfo)
    if grouped() and plain(kind) and (kind == "party" or kind == "raid") then
        name = (type(name) == "string" and plain(name) and name ~= "") and name or zone
        if kind == "party" then
            Journal.Record("dungeon:" .. name, ("First dungeon together: %s"):format(name))
        else
            Journal.Record("raid:" .. name, ("First raid together: %s"):format(name))
        end
    elseif not plain(kind) or kind == "none" or kind == nil then
        Journal.Record("zone:" .. zone, ("First time in %s together"):format(zone))
    end
end

-- Bosses: WoW may tell us through either of two events, so listen for both.
local function bossDown(name)
    if grouped() and type(name) == "string" and plain(name) and name ~= "" then
        Journal.Record("boss:" .. name, ("Beat %s together for the first time"):format(name))
    end
end
ns.OnEvent("ENCOUNTER_END", function(_, _, name, _, _, success)
    if success == 1 or success == true then
        bossDown(name)
    end
end)
ns.OnEvent("BOSS_KILL", function(_, _, name)
    bossDown(name)
end)

-- Levels: every tenth one, for each of you.
ns.OnEvent("PLAYER_LEVEL_UP", function(_, level)
    if type(level) == "number" and plain(level) and level % 10 == 0 and me() then
        Journal.Record(("level:%s:%d"):format(Journal.Key(me()), level),
            ("%s reached level %d"):format(me(), level))
    end
end)

local function checkPartnerLevel(p, s)
    local level = s and s.level
    if type(level) ~= "number" then
        return
    end
    local before = p.lastLevel
    p.lastLevel = level
    if before and level > before then
        for l = before + 1, level do
            if l % 10 == 0 then
                Journal.Record(("level:%s:%d"):format(Journal.Key(p.name), l),
                    ("%s reached level %d"):format(p.name, l))
            end
        end
    end
end

-- The silly ones.
local function checkDeaths()
    local s = partnerStatus()
    local partner = ns.db and ns.db.partner
    if not (s and partner and me()) then
        return
    end
    local f = s.flags or {}
    local iGhost = call(UnitIsGhost, "player") and true or false
    local iDead = (not iGhost and call(UnitIsDead, "player")) and true or false
    if iDead and f.dead then
        Journal.Record("bothdied", ("First time %s and %s died in the same fight"):format(me(), partner))
    elseif f.ghost and not (iDead or iGhost) then
        Journal.Record("theirghost", ("First time %s ran back as a ghost while %s waited"):format(partner, me()))
    elseif iGhost and not (f.dead or f.ghost) then
        Journal.Record("myghost", ("First time %s ran back as a ghost while %s waited"):format(me(), partner))
    end
end

ns.Listen("PINGED", function(direction, kind, who)
    local label = ns.Ping and ns.Ping.LABELS[kind] or kind
    local sender = direction == "sent" and me() or who
    if sender then
        Journal.Record("ping", ("First ping: %s sent %s"):format(sender, label))
    end
end)

ns.Listen("ANSWERED", function(direction, word, who)
    local answer = ns.Keep and ns.Keep.WORDS[word] or word
    local answerer = direction == "sent" and me() or who
    if answerer then
        Journal.Record("answer", ("First \"Should I keep this?\": %s said %s"):format(answerer, answer))
    end
end)

ns.Listen("PARTNER_UPDATED", function()
    local partner = ns.db and ns.db.partner
    local s = partnerStatus()
    if not (partner and s) or (ns.Demo and ns.Demo.active) then
        return
    end
    local p = Journal.Page(partner)
    if p then
        if s.class then
            p.class = s.class
        end
        checkPartnerLevel(p, s)
    end
    checkPlace()
    checkDeaths()
end)

for _, event in ipairs({ "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE" }) do
    ns.OnEvent(event, function()
        if ns.db then
            checkPlace()
        end
    end)
end
for _, event in ipairs({ "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST" }) do
    ns.OnEvent(event, function()
        if ns.db then
            checkDeaths()
        end
    end)
end

---------------------------------------------------------------------------
-- Links and time together
---------------------------------------------------------------------------
local current -- who this character is linked with, as the journal last saw it

ns.Listen("PARTNER_CHANGED", function(name)
    if current and not (name and ns.SameName(current, name)) then
        endLink(current)
    end
    if name and not (current and ns.SameName(current, name)) then
        startLink(name, true)
    end
    current = name
end)

ns.Listen("LOGIN", function()
    current = ns.db.partner
    if current then
        startLink(current, false) -- reuses the open link if there is one
    end
    C_Timer.NewTicker(TICK, function()
        local partner = ns.db.partner
        local my = me()
        local p = partner and my and partnerStatus() and store() and store()[Journal.Key(partner)]
        local l = p and openLink(p, my)
        if l then
            l.together = (l.together or 0) + TICK
        end
    end)
    C_Timer.After(5, checkPlace)
end)

---------------------------------------------------------------------------
-- Reading it back, for the window
---------------------------------------------------------------------------
-- Partners: the current one first, then the rest, most recent first.
function Journal.Partners()
    local list = {}
    for _, p in pairs(store() or {}) do
        list[#list + 1] = p
    end
    local cur = ns.db and Journal.Key(ns.db.partner)
    table.sort(list, function(a, b)
        local ac, bc = Journal.Key(a.name) == cur, Journal.Key(b.name) == cur
        if ac ~= bc then
            return ac
        end
        return (a.lastAt or 0) > (b.lastAt or 0)
    end)
    return list, cur
end

-- "16 Nov 2026"
function Journal.Date(t)
    if not t then
        return "?"
    end
    return tonumber(date("%d", t)) .. date(" %b %Y", t)
end

function Journal.LinkText(l)
    local who = l.myClass and ("your %s %s"):format(l.myClass:lower(), l.me) or l.me
    local D = Journal.Date
    if not l.fromKnown then
        if l.to then
            return ("On %s, from %s, when the journal started, to %s"):format(who, D(l.from), D(l.to))
        end
        return ("On %s, linked since before %s, when the journal started"):format(who, D(l.from))
    end
    if l.to then
        return ("On %s, linked %s to %s"):format(who, D(l.from), D(l.to))
    end
    return ("On %s, linked %s"):format(who, D(l.from))
end

function Journal.TogetherText(p)
    local seconds = 0
    for _, l in ipairs(p.links) do
        seconds = seconds + (l.together or 0)
    end
    local minutes = math.floor(seconds / 60)
    if minutes < 1 then
        return "Not much time online together yet"
    elseif minutes < 60 then
        return ("About %d minute%s online together"):format(minutes, minutes == 1 and "" or "s")
    end
    local hours = math.floor(minutes / 60 + 0.5)
    return ("About %d hour%s online together"):format(hours, hours == 1 and "" or "s")
end
