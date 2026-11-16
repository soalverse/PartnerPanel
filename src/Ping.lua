-- Partner Panel: pings. A pin and an arrow for your partner, dropped where you stand.
--   PING    = kind, map, x, y, label   ("follow" repeats while you move; "stop" ends it)
--   ARRIVED = "I made it", so the sender knows, and a "follow" can stop early.
-- An addon cannot read the spot under the mouse out in the world (Blizzard keeps that for
-- its own ping wheel), so every ping marks the floor under the sender, plus the name of
-- whatever they are hovering or targeting.
local _, ns = ...
local P = ns.Protocol

local Ping = {}
ns.Ping = Ping

Ping.LABELS = { stand = "Stand here", come = "Come here", follow = "Follow me", watch = "Watch out", grab = "Grab this" }
Ping.COLORS = { stand = "7fbfff", come = "7fff7f", follow = "e6d2ff", watch = "ff5555", grab = "ffd200" }
-- Raid marker icons, which every client has: square, star, moon, skull, diamond.
Ping.ICONS = { stand = 6, come = 1, follow = 5, watch = 8, grab = 3 }

local SHOW_FOR = 300     -- a ping stays on the card (and the pin on the map) this long
local FOLLOW_FOR = 180   -- "Follow me" keeps updating this long
local FOLLOW_EVERY = 3   -- seconds between "Follow me" updates, and only if you moved
local ARRIVE_YARDS = 10  -- this close to the pin counts as made it
local MIN_GAP = 1.5      -- seconds between pings you send, so a nervous finger cannot spam

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

local function plainNumber(v)
    return type(v) == "number" and not ns.IsSecret(v)
end

local function xy(pos)
    if type(pos) ~= "table" then
        return nil
    end
    local x, y = pos.x, pos.y
    if x == nil and pos.GetXY then
        x, y = pos:GetXY()
    end
    if plainNumber(x) and plainNumber(y) then
        return x, y
    end
    return nil
end

-- Where I am: map id, x, y (0 to 1), or nil where the game keeps it private (dungeons).
function Ping.MyPosition()
    if not C_Map then
        return nil
    end
    local map = call(C_Map.GetBestMapForUnit, "player")
    if not plainNumber(map) then
        return nil
    end
    local x, y = xy((call(C_Map.GetPlayerMapPosition, map, "player")))
    if not x or (x == 0 and y == 0) then
        return nil
    end
    return map, x, y
end

-- The name of whatever I am hovering, or else targeting, if it is not me.
local function pointedAt()
    for _, unit in ipairs({ "mouseover", "target" }) do
        local exists = call(UnitExists, unit)
        if exists and not ns.IsSecret(exists) and not call(UnitIsUnit, unit, "player") then
            if call(UnitIsPlayer, unit) then
                local name = ns.UnitFullName(unit)
                if name then
                    return name
                end
            else
                local name = call(UnitName, unit)
                if type(name) == "string" and name ~= "" and not ns.IsSecret(name) then
                    return name
                end
            end
        end
    end
    return nil
end

function Ping.Text(kind, label)
    local text = ("|cff%s%s|r"):format(Ping.COLORS[kind] or "ffffff", Ping.LABELS[kind] or kind)
    if label then
        text = text .. ": " .. label
    end
    return text
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local lastSent = 0
local sent        -- { kind, at } my last ping, so "made it" means something
local follow      -- { ticker, map, x, y } while "Follow me" is running

local function sendPing(p)
    ns.Comm.Send(ns.db.partner, P.EncodePing(p), "PING")
end

local function endFollow()
    if follow then
        follow.ticker:Cancel()
        follow = nil
    end
end

function Ping.Following()
    return follow ~= nil
end

function Ping.StopFollow()
    if not follow then
        return
    end
    endFollow()
    if ns.db and ns.db.partner then
        sendPing({ kind = "stop" })
    end
    ns.Print("Stopped sharing where you are.")
end

-- Sends a ping of `kind` ("stand", "come", "follow", "watch", "grab", or "stop").
function Ping.Send(kind)
    local partner = ns.db and ns.db.partner
    if not partner then
        ns.Print("Link with your partner first, with |cffffffff/pp link|r.")
        return false
    end
    if kind == "stop" then
        if follow then
            Ping.StopFollow()
        else
            ns.Print("You are not sharing where you are right now.")
        end
        return true
    end
    if not Ping.LABELS[kind] then
        return false
    end
    if GetTime() - lastSent < MIN_GAP then
        return false
    end
    local map, x, y = Ping.MyPosition()
    if not map then
        ns.Print("WoW is keeping your exact spot private here, so there is nowhere to put the pin."
            .. " That usually means you are in a dungeon.")
        return false
    end
    lastSent = GetTime()
    local label = (kind == "watch" or kind == "grab") and pointedAt() or nil
    endFollow()
    sendPing({ kind = kind, map = map, x = x, y = y, label = label })
    sent = { kind = kind, at = GetTime() }

    if kind == "follow" then
        local started = GetTime()
        follow = { map = map, x = x, y = y }
        follow.ticker = C_Timer.NewTicker(FOLLOW_EVERY, function()
            if not follow then
                return
            end
            if GetTime() - started >= FOLLOW_FOR or not ns.db.partner then
                Ping.StopFollow()
                return
            end
            local m, nx, ny = Ping.MyPosition()
            if m and (m ~= follow.map or math.abs(nx - follow.x) > 0.0005 or math.abs(ny - follow.y) > 0.0005) then
                follow.map, follow.x, follow.y = m, nx, ny
                sendPing({ kind = "follow", map = m, x = nx, y = ny })
            end
        end)
        ns.Print("Sharing where you are with %s for the next 3 minutes. |cffffffff/pp ping stop|r ends it sooner.",
            partner)
    else
        ns.Print("Pinged %s: %s.", partner, Ping.Text(kind, label))
    end
    return true
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local incoming -- { kind, map, x, y, label, at, from, pinned }

local function zoneName(map)
    local info = C_Map and call(C_Map.GetMapInfo, map)
    if type(info) == "table" and type(info.name) == "string" and not ns.IsSecret(info.name) then
        return info.name
    end
    return nil
end

-- True while the map pin is still the one we placed (the game keeps one pin at a time,
-- and the player may have put down their own since).
local function pinIsOurs()
    if not (incoming and incoming.pinned and C_Map) then
        return false
    end
    local wp = call(C_Map.GetUserWaypoint)
    if type(wp) ~= "table" or wp.uiMapID ~= incoming.map then
        return false
    end
    local x, y = xy(wp.position)
    return x ~= nil and math.abs(x - incoming.x) < 0.001 and math.abs(y - incoming.y) < 0.001
end

local function placePin(p)
    if not (C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates) then
        return false
    end
    if call(C_Map.CanSetUserWaypointOnMap, p.map) == false then
        return false
    end
    local point = call(UiMapPoint.CreateFromCoordinates, p.map, p.x, p.y)
    if not point or not pcall(C_Map.SetUserWaypoint, point) then
        return false
    end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
    return true
end

function Ping.Clear()
    if pinIsOurs() then
        pcall(C_Map.ClearUserWaypoint)
    end
    if incoming then
        incoming = nil
        ns.Fire("PARTNER_UPDATED")
    end
end

local function worldPos(map, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then
        return nil
    end
    local continent, pos = call(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
    local wx, wy = xy(pos)
    if plainNumber(continent) and wx then
        return continent, wx, wy
    end
    return nil
end

-- Yards from me to the pin, when this client can say (same continent, not in a dungeon).
function Ping.Distance()
    if not incoming then
        return nil
    end
    local map, x, y = Ping.MyPosition()
    if not map then
        return nil
    end
    local c1, x1, y1 = worldPos(map, x, y)
    local c2, x2, y2 = worldPos(incoming.map, incoming.x, incoming.y)
    if not (c1 and c2) or c1 ~= c2 then
        return nil
    end
    return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
end

-- What the card shows, or nil.
function Ping.Current()
    if not incoming then
        return nil
    end
    return { kind = incoming.kind, label = incoming.label, text = Ping.Text(incoming.kind, incoming.label),
             distance = Ping.Distance(), at = incoming.at }
end

local function announce(p)
    local where = zoneName(p.map)
    ns.Print("%s: %s%s", p.from, Ping.Text(p.kind, p.label), where and (" (" .. where .. ")") or "")
    if PlaySound and SOUNDKIT and SOUNDKIT.MAP_PING then
        pcall(PlaySound, SOUNDKIT.MAP_PING)
    end
end

ns.Listen("MESSAGE", function(kind, fields, from)
    local partner = ns.db.partner
    if not partner or not ns.SameName(partner, from) then
        return
    end
    if kind == "PING" then
        local p = P.DecodePing(fields)
        if not p then
            return
        end
        if p.kind == "stop" then
            if incoming and incoming.kind == "follow" then
                ns.Print("%s stopped sharing where they are.", from)
                Ping.Clear()
            end
            return
        end
        local update = incoming and incoming.kind == "follow" and p.kind == "follow"
        p.at, p.from = GetTime(), from
        p.pinned = placePin(p)
        incoming = p
        if not update then
            announce(p)
        end
        ns.Fire("PARTNER_UPDATED")
    elseif kind == "ARRIVED" then
        if sent and GetTime() - sent.at < SHOW_FOR then
            ns.Print("%s made it to your ping.", from)
            sent = nil
            if follow then
                endFollow()
            end
        end
    end
end)

ns.Listen("PARTNER_CHANGED", function()
    endFollow()
    sent = nil
    Ping.Clear()
end)

-- Once a second: forget old pings, notice when I reach the pin, keep the distance fresh.
local shownYards
local function tick()
    if not incoming then
        return
    end
    if GetTime() - incoming.at > SHOW_FOR then
        Ping.Clear()
        return
    end
    local d = Ping.Distance()
    if d and d <= ARRIVE_YARDS and incoming.kind ~= "watch" then
        ns.Comm.Send(ns.db.partner, P.Encode("ARRIVED"), "ARRIVED")
        ns.Print("You made it to %s's ping.", incoming.from)
        Ping.Clear()
        return
    end
    local yards = d and math.floor(d / 5) * 5
    if yards ~= shownYards then
        shownYards = yards
        ns.Fire("PARTNER_UPDATED")
    end
end

ns.Listen("LOGIN", function()
    C_Timer.NewTicker(1, tick)
end)
