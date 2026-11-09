-- Partner Panel: shared plumbing - saved data, events, an internal message bus, names.
local ADDON, ns = ...
local P = ns.Protocol

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.VERSION = (GetMeta and GetMeta(ADDON, "Version")) or "dev"

local _, _, _, toc = GetBuildInfo()
ns.IS_FOREVER = toc ~= nil and toc >= 16000 and toc < 20000

ns.TAG = "|cffff9f7aPartner Panel|r"

function ns.Print(fmt, ...)
    local text = select("#", ...) > 0 and fmt:format(...) or fmt
    print(ns.TAG .. ": " .. text)
end

-- Forever hides some values mid-combat ("secret values"); comparing one errors.
function ns.IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

---------------------------------------------------------------------------
-- Internal message bus: ns.Listen("PARTNER_UPDATED", fn) / ns.Fire("PARTNER_UPDATED")
---------------------------------------------------------------------------
local listeners = {}

function ns.Listen(name, fn)
    listeners[name] = listeners[name] or {}
    table.insert(listeners[name], fn)
end

function ns.Fire(name, ...)
    local list = listeners[name]
    if not list then
        return
    end
    for i = 1, #list do
        list[i](...)
    end
end

---------------------------------------------------------------------------
-- Game events: ns.OnEvent("PLAYER_LOGIN", function(event, ...) end)
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns.OnEvent(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        local ok = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then
            return -- event doesn't exist in this client
        end
    end
    table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    for i = 1, #list do
        list[i](event, ...)
    end
end)

---------------------------------------------------------------------------
-- Saved data (per character)
---------------------------------------------------------------------------
local DEFAULTS = {
    -- partner = "First Last",   -- set once linked
    -- lastKnown = { zone, subzone, level, class, at },
    mood = "",
    panel = { shown = true, locked = false, theme = "coral" },
}

local function applyDefaults(t, d)
    for k, v in pairs(d) do
        if type(v) == "table" then
            if type(t[k]) ~= "table" then
                t[k] = {}
            end
            applyDefaults(t[k], v)
        elseif t[k] == nil then
            t[k] = v
        end
    end
end

ns.OnEvent("ADDON_LOADED", function(_, name)
    if name ~= ADDON then
        return
    end
    PartnerPanelCharDB = PartnerPanelCharDB or {}
    applyDefaults(PartnerPanelCharDB, DEFAULTS)
    ns.db = PartnerPanelCharDB
    ns.Fire("INIT")
end)

ns.OnEvent("PLAYER_LOGIN", function()
    ns.Fire("LOGIN")
end)

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------
function ns.UniqueNames()
    if RegionalUniqueNamesEnabled then
        local ok, on = pcall(RegionalUniqueNamesEnabled)
        if ok then
            return on and true or false
        end
    end
    return ns.IS_FOREVER
end

function ns.Normalize(name)
    return P.NormalizeName(name, ns.UniqueNames())
end

function ns.SameName(a, b)
    return P.SameName(a, b, ns.UniqueNames())
end

-- A unit's whole name: Forever's "First Last", or Classic's "Name" / "Name-Realm".
function ns.UnitFullName(unit)
    local ok, name, second = pcall(UnitName, unit)
    if not ok or not name or ns.IsSecret(name) then
        return nil
    end
    if type(second) == "string" and second ~= "" and not ns.IsSecret(second) then
        name = name .. (ns.UniqueNames() and " " or "-") .. second
    end
    return ns.Normalize(name)
end

function ns.MyName()
    return ns.UnitFullName("player")
end

-- The unit token ("party1", "raid7") for someone in my group, or nil.
function ns.FindGroupUnit(name)
    if not name or not IsInGroup() then
        return nil
    end
    local raid = IsInRaid()
    local count = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
    for i = 1, count do
        local unit = (raid and "raid" or "party") .. i
        if ns.SameName(ns.UnitFullName(unit), name) then
            return unit
        end
    end
    return nil
end

-- Who "/partner link" means with no name: your target if it's a player, else your one party member.
function ns.GuessPartner()
    local ok, isPlayer = pcall(function()
        return UnitExists("target") and UnitIsPlayer("target") and not UnitIsUnit("target", "player")
    end)
    if ok and isPlayer and not ns.IsSecret(isPlayer) then
        return ns.UnitFullName("target")
    end
    if IsInGroup() and not IsInRaid() and GetNumSubgroupMembers() == 1 then
        return ns.UnitFullName("party1")
    end
    return nil
end

-- "just now", "5m ago", "3h ago", "2d ago"
function ns.Ago(seconds)
    if not seconds or seconds < 60 then
        return "just now"
    elseif seconds < 3600 then
        return ("%dm ago"):format(math.floor(seconds / 60))
    elseif seconds < 86400 then
        return ("%dh ago"):format(math.floor(seconds / 3600))
    end
    return ("%dd ago"):format(math.floor(seconds / 86400))
end
