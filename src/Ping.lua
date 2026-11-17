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
-- Our own icons, floating white-and-gold dots (media/ping-*.tga, drawn by
-- scripts/make-icons.js): two feet, a path to an X, a sparkle, an exclamation mark,
-- a pointing hand. Each is a little looping animation: FRAMES frames side by side.
Ping.FRAMES = 8
function Ping.Icon(kind)
    return "Interface\\AddOns\\PartnerPanel\\media\\ping-" .. (kind or "come")
end

-- Puts a ping's icon on a texture and starts it playing.
function Ping.SetIcon(tex, kind)
    ns.Flipbook(tex, Ping.Icon(kind), Ping.FRAMES)
end

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

-- Seconds left on "Follow me", or nil when it is not running.
function Ping.FollowLeft()
    if not follow then
        return nil
    end
    return math.max(0, math.floor(FOLLOW_FOR - (GetTime() - follow.started) + 0.5))
end

-- `typed` is true when you asked for it with /pp ping stop, so it gets an answer in chat;
-- running out on its own just shows on the card.
function Ping.StopFollow(typed)
    if not follow then
        return
    end
    endFollow()
    if ns.db and ns.db.partner then
        sendPing({ kind = "stop" })
    end
    if typed then
        ns.Print("Stopped sharing where you are.")
    end
    ns.Fire("PARTNER_UPDATED")
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
            Ping.StopFollow(true)
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
    ns.Fire("PINGED", "sent", kind, partner)

    if kind == "follow" then
        local started = GetTime()
        follow = { map = map, x = x, y = y, started = started }
        follow.ticker = C_Timer.NewTicker(FOLLOW_EVERY, function()
            if not follow then
                return
            end
            if GetTime() - started >= FOLLOW_FOR or not ns.db.partner then
                Ping.StopFollow(false)
                return
            end
            local m, nx, ny = Ping.MyPosition()
            if m and (m ~= follow.map or math.abs(nx - follow.x) > 0.0005 or math.abs(ny - follow.y) > 0.0005) then
                follow.map, follow.x, follow.y = m, nx, ny
                sendPing({ kind = "follow", map = m, x = nx, y = ny })
            end
        end)
    end
    ns.Fire("PARTNER_UPDATED") -- your own card shows "Sharing where you are" while it runs
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

---------------------------------------------------------------------------
-- The floating marker: our own icon, the ping's name and the yards, hung on the frame
-- WoW keeps over the waypoint's spot on your screen (C_Navigation.GetFrame), so it
-- floats over the actual place in the world. Pulses for a moment when it first shows.
---------------------------------------------------------------------------
local PULSE = 3 -- seconds
local marker

local function navFrame()
    if not (C_Navigation and C_Navigation.GetFrame) then
        return nil
    end
    local ok, f = pcall(C_Navigation.GetFrame)
    return ok and f or nil
end

local function makeMarker()
    marker = CreateFrame("Frame", "PartnerPanelPingMarker", UIParent)
    marker:SetSize(64, 64)
    marker:SetFrameStrata("LOW")
    marker.icon = marker:CreateTexture(nil, "ARTWORK")
    marker.icon:SetAllPoints()
    marker.label = marker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    marker.label:SetPoint("TOP", marker, "BOTTOM", 0, -1)
    marker.yards = marker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    marker.yards:SetPoint("TOP", marker.label, "BOTTOM", 0, -1)
    marker:Hide()
    marker:SetScript("OnUpdate", function(self, elapsed)
        self.age = (self.age or 0) + (elapsed or 0)
        local nav = self.nav
        -- WoW hides its own waypoint frame when there is nothing to show; so do we
        self:SetAlpha((nav and nav.IsShown and not nav:IsShown()) and 0 or 1)
        if self.age < PULSE then
            self:SetScale(1 + 0.18 * math.abs(math.sin(self.age * math.pi * 1.5)) * (1 - self.age / PULSE))
        else
            self:SetScale(1)
        end
    end)
end

local function hideMarker()
    if marker then
        marker:Hide()
    end
end

-- Shows or updates the marker for the live ping (fresh = a new ping, so pulse again).
local function showMarker(fresh)
    -- "Follow me", with your partner close enough to have a nameplate: the sparkle sits
    -- right over their head (above the heart, if that is on), and moves with them.
    local overHead = incoming and incoming.kind == "follow" and ns.Heart and ns.Heart.Above()
    local nav = not overHead and navFrame()
    -- Otherwise, only while WoW's waypoint frame is pointing at OUR pin: if you put down
    -- your own pin, or switched the arrow to a quest, it would float over the wrong place.
    local tracking = true
    if C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint then
        local ok, yes = pcall(C_SuperTrack.IsSuperTrackingUserWaypoint)
        tracking = not ok or yes == true
    end
    if not (incoming and (overHead or (incoming.pinned and nav and tracking and pinIsOurs()))) then
        hideMarker()
        return
    end
    if not marker then
        makeMarker()
    end
    marker.nav = nav or nil
    marker.overHead = overHead and true or false
    marker:ClearAllPoints()
    marker:SetPoint("BOTTOM", overHead or nav, "TOP", 0, 4)
    Ping.SetIcon(marker.icon, incoming.kind)
    -- over their head it is plain who and where, so just the sparkle
    marker.label:SetText(overHead and "" or Ping.Text(incoming.kind, incoming.label))
    local d = Ping.Distance()
    marker.yards:SetText((not overHead and d) and ("%d yd"):format(math.floor(d + 0.5)) or "")
    if fresh then
        marker.age = 0
    end
    marker:Show()
end
Ping.ShowMarker = showMarker

-- Their nameplate came or went: move the "Follow me" sparkle between head and map spot.
ns.Listen("PARTNER_PLATE_MOVED", function()
    if incoming and incoming.kind == "follow" then
        showMarker(false)
    end
end)

function Ping.Clear()
    if pinIsOurs() then
        pcall(C_Map.ClearUserWaypoint)
    end
    hideMarker()
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
    local d = Ping.Distance()
    local where = d and ("%d yd"):format(math.floor(d + 0.5)) or zoneName(p.map)
    ns.Toast.Show(p.from, Ping.Text(p.kind, p.label) .. (where and (", " .. where) or ""), Ping.Icon(p.kind), Ping.FRAMES)
    ns.Sound("MAP_PING")
    ns.Fire("PINGED", "received", p.kind, p.from)
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
        showMarker(not update)
        ns.Fire("PARTNER_UPDATED")
    elseif kind == "ARRIVED" then
        if sent and GetTime() - sent.at < SHOW_FOR then
            ns.Toast.Show(from, "Made it to your ping", Ping.Icon(sent.kind), Ping.FRAMES)
            sent = nil
            if follow then
                endFollow()
            end
            ns.Fire("PARTNER_UPDATED")
        end
    end
end)

ns.Listen("PARTNER_CHANGED", function()
    endFollow()
    sent = nil
    Ping.Clear()
end)

-- Once a second: forget old pings, notice when I reach the pin, keep the distance fresh,
-- and keep the "Sharing where you are" countdown on your own card ticking.
local shownYards
local function tick()
    if follow then
        ns.Fire("PARTNER_UPDATED")
    end
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
        Ping.Clear()
        return
    end
    showMarker(false) -- keeps the yards under the marker fresh
    local yards = d and math.floor(d / 5) * 5
    if yards ~= shownYards then
        shownYards = yards
        ns.Fire("PARTNER_UPDATED")
    end
end

ns.Listen("LOGIN", function()
    C_Timer.NewTicker(1, tick)
end)
