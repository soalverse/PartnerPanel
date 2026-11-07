-- Partner Panel: sharing "how I'm doing" with your partner, and tracking theirs.
--   HELLO  = "I'm here - send me your status"
--   STATUS = level, class, zone, flags (AFK/combat/dead...), health %, mood
local _, ns = ...
local P = ns.Protocol

local Status = {}
ns.Status = Status

local HEARTBEAT = 45      -- resend status this often, even if nothing changed
local OFFLINE_AFTER = 120 -- no word for this long = offline / out of reach

-- What we know about the partner this session.
local partner = { online = false }
ns.partnerState = partner

-- Whether the partner was in our group at the last check (to notice the route changing).
local wasGrouped = false
local function partnerGrouped()
    return ns.db and ns.db.partner and ns.FindGroupUnit(ns.db.partner) ~= nil or false
end

local function safe(v)
    if ns.IsSecret(v) then
        return nil
    end
    return v
end

local function call(fn, ...)
    if not fn then
        return nil
    end
    local ok, v = pcall(fn, ...)
    if ok then
        return safe(v)
    end
    return nil
end

function Status.Collect()
    local s = { flags = {} }
    s.level = call(UnitLevel, "player")
    local ok, _, classFile = pcall(UnitClass, "player")
    if ok then
        s.class = safe(classFile)
    end
    s.zone = call(GetRealZoneText) or ""
    s.subzone = call(GetSubZoneText) or ""

    local f = s.flags
    f.afk = call(UnitIsAFK, "player") and true or nil
    f.dnd = call(UnitIsDND, "player") and true or nil
    f.combat = call(UnitAffectingCombat, "player") and true or nil
    f.ghost = call(UnitIsGhost, "player") and true or nil
    f.dead = (not f.ghost and call(UnitIsDead, "player")) and true or nil
    f.resting = call(IsResting) and true or nil

    if not f.combat then
        local hp, max = call(UnitHealth, "player"), call(UnitHealthMax, "player")
        if type(hp) == "number" and type(max) == "number" and max > 0 then
            s.hp = hp / max * 100
        end
    end
    s.mood = ns.db.mood or ""
    return s
end

local function sendStatus()
    local to = ns.db and ns.db.partner
    if to then
        ns.Comm.Send(to, P.EncodeStatus(Status.Collect()), "STATUS")
    end
end

local dirty = false
function Status.MarkDirty(delay)
    if dirty then
        return
    end
    dirty = true
    C_Timer.After(delay or 1, function()
        dirty = false
        sendStatus()
    end)
end

function Status.SayHello()
    local to = ns.db and ns.db.partner
    if to then
        ns.Comm.Send(to, P.Encode("HELLO", ns.VERSION), "HELLO")
        Status.MarkDirty(0.5)
    end
end
ns.Listen("SAY_HELLO", Status.SayHello)

function Status.SetMood(text)
    ns.db.mood = P.Clean(text, P.MOOD_MAX)
    Status.MarkDirty(0.2)
    return ns.db.mood
end

-- The partner, as the panel should show them (nil = not linked).
function ns.GetPartnerView()
    if ns.Demo and ns.Demo.active then
        return ns.Demo.View()
    end
    local name = ns.db and ns.db.partner
    if not name then
        return nil
    end
    return {
        name = name,
        online = partner.online,
        status = partner.status,
        lastSeen = partner.lastSeen,
        version = partner.version,
        via = partner.via,
        grouped = ns.FindGroupUnit(name) ~= nil,
        lastKnown = ns.db.lastKnown,
    }
end

---------------------------------------------------------------------------
-- Partner presence
---------------------------------------------------------------------------
local function markSeen(version, via)
    local wasOnline = partner.online
    partner.online = true
    partner.lastSeen = GetTime()
    partner.via = via or partner.via
    if version and version ~= "" then
        partner.version = version
    end
    if not wasOnline then
        ns.Fire("PARTNER_UPDATED")
    end
end

-- While grouped with the partner, learn their BattleTag so Battle.net can find them later.
local function learnBattleTag()
    local p = ns.db and ns.db.partner
    local unit = p and ns.FindGroupUnit(p)
    if unit and ns.BNet then
        ns.BNet.LearnFromUnit(unit, p)
    end
end

local function markOffline()
    if partner.online then
        partner.online = false
        partner.status = nil
        ns.Fire("PARTNER_UPDATED")
    end
end

local function resetPartner()
    partner.online = false
    partner.status = nil
    partner.lastSeen = nil
    partner.version = nil
    partner.via = nil
end

ns.Listen("MESSAGE", function(kind, fields, from, channel)
    local p = ns.db.partner
    if not p or not ns.SameName(p, from) then
        return
    end
    if kind == "HELLO" then
        markSeen(fields[1], channel)
        Status.MarkDirty(0.2)
    elseif kind == "STATUS" then
        markSeen(nil, channel)
        local s = P.DecodeStatus(fields)
        partner.status = s
        ns.db.lastKnown = { zone = s.zone, subzone = s.subzone, level = s.level, class = s.class, at = time() }
        ns.Fire("PARTNER_UPDATED")
    end
end)

ns.Listen("UNREACHABLE", function(name)
    if ns.db.partner and ns.SameName(ns.db.partner, name) then
        markOffline()
    end
end)

ns.Listen("PARTNER_CHANGED", function()
    resetPartner()
    wasGrouped = partnerGrouped()
    learnBattleTag()
    ns.Fire("PARTNER_UPDATED")
end)

---------------------------------------------------------------------------
-- When to send
---------------------------------------------------------------------------
local function onChange()
    Status.MarkDirty(1)
end

for _, event in ipairs({
    "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED_INDOORS",
    "PLAYER_LEVEL_UP", "PLAYER_FLAGS_CHANGED", "PLAYER_UPDATE_RESTING",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST",
}) do
    ns.OnEvent(event, onChange)
end

-- Health changes constantly; only for the player, and coalesced.
local healthFrame = CreateFrame("Frame")
pcall(healthFrame.RegisterUnitEvent, healthFrame, "UNIT_HEALTH", "player")
healthFrame:SetScript("OnEvent", function()
    Status.MarkDirty(3)
end)

-- When the partner joins or leaves our group, the route changes (group <-> Battle.net):
-- say hello on the new route straight away rather than waiting for the next heartbeat.
ns.OnEvent("GROUP_ROSTER_UPDATE", function()
    if not ns.db then
        return
    end
    local grouped = partnerGrouped()
    if grouped then
        learnBattleTag()
    end
    if grouped ~= wasGrouped then
        Status.SayHello()
    end
    wasGrouped = grouped
    ns.Fire("PARTNER_UPDATED")
end)

ns.Listen("LOGIN", function()
    wasGrouped = partnerGrouped()
    learnBattleTag()
    C_Timer.After(3, Status.SayHello)

    C_Timer.NewTicker(HEARTBEAT, sendStatus)

    C_Timer.NewTicker(10, function()
        if not partner.online then
            return
        end
        local unit = ns.FindGroupUnit(ns.db.partner)
        local disconnected = unit and call(UnitIsConnected, unit) == false
        if disconnected or GetTime() - (partner.lastSeen or 0) > OFFLINE_AFTER then
            markOffline()
        end
    end)
end)
