-- Partner Panel: a heart over your partner's head. Optional, and off unless you turn it on.
-- An addon cannot attach anything to another character, but it can hang a picture on their
-- nameplate, the floating name bar WoW draws over characters, so the heart moves with them.
-- Friendly players only get nameplates when that WoW setting is on, so while the heart is
-- on it switches friendly nameplates on, and when you turn the heart off it puts that
-- setting back, but only if it was the heart that changed it.
local _, ns = ...

local Heart = {}
ns.Heart = Heart

local SIZE = 34
local frame        -- the heart itself
local plateUnit    -- the nameplate showing the partner right now, e.g. "nameplate3"
local pending      -- a nameplate setting change waiting for a fight to end

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

local getCVar = (C_CVar and C_CVar.GetCVar) or GetCVar
local setCVar = (C_CVar and C_CVar.SetCVar) or SetCVar

local function isPartner(unit)
    local partner = ns.db and ns.db.partner
    return partner ~= nil and ns.SameName(ns.UnitFullName(unit), partner)
end

-- The nameplate frame for `unit`, unless WoW keeps it to itself (inside dungeons).
local function plateFor(unit)
    if not (unit and C_NamePlate and C_NamePlate.GetNamePlateForUnit) then
        return nil
    end
    local plate = call(C_NamePlate.GetNamePlateForUnit, unit)
    if not plate or (plate.IsForbidden and plate:IsForbidden()) then
        return nil
    end
    return plate
end

function Heart.PartnerPlate()
    if plateUnit and isPartner(plateUnit) then
        return plateFor(plateUnit)
    end
    return nil
end

-- What to hang things above your partner on: the heart if it is showing, else their
-- nameplate. nil when neither is on screen. ("Follow me" puts its sparkle here.)
function Heart.Above()
    if frame and frame:IsShown() then
        return frame
    end
    return Heart.PartnerPlate()
end

function Heart.IsShown()
    return frame ~= nil and frame:IsShown()
end

local function create()
    frame = CreateFrame("Frame", "PartnerPanelHeart", UIParent)
    frame:SetSize(SIZE, SIZE)
    frame:SetFrameStrata("LOW")
    frame.icon = frame:CreateTexture(nil, "ARTWORK")
    frame.icon:SetAllPoints()
    ns.Ping.SetIcon(frame.icon, "heart")
    frame:Hide()
end

function Heart.Update()
    local plate = ns.db and ns.db.heart and Heart.PartnerPlate()
    if plate then
        if not frame then
            create()
        end
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOM", plate, "TOP", 0, 2)
        frame:Show()
    elseif frame then
        frame:Hide()
    end
    ns.Fire("PARTNER_PLATE_MOVED")
end

-- Looks through the nameplates on screen for your partner.
local function rescan()
    plateUnit = nil
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if call(UnitExists, unit) and isPartner(unit) then
            plateUnit = unit
            break
        end
    end
    Heart.Update()
end
Heart.Rescan = rescan

local function friendlyPlatesOn()
    return tostring(call(getCVar, "nameplateShowFriends")) == "1"
end

-- Returns false when WoW will not allow it right now (mid-fight); it happens afterwards.
local function setFriendlyPlates(on)
    if InCombatLockdown and InCombatLockdown() then
        pending = on
        return false
    end
    pending = nil
    call(setCVar, "nameplateShowFriends", on and "1" or "0")
    return true
end

function Heart.SetEnabled(on)
    ns.db.heart = on and true or false
    if on and not friendlyPlatesOn() then
        ns.db.heartTurnedOnPlates = true
        if not setFriendlyPlates(true) then
            ns.Print("WoW does not let addons change nameplates during a fight, so the heart"
                .. " appears once this one is over.")
        end
    elseif not on and ns.db.heartTurnedOnPlates then
        ns.db.heartTurnedOnPlates = nil
        setFriendlyPlates(false)
    end
    rescan()
end

ns.OnEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
    if ns.db and isPartner(unit) then
        plateUnit = unit
        Heart.Update()
    end
end)

ns.OnEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
    if unit == plateUnit then
        plateUnit = nil
        Heart.Update()
    end
end)

ns.OnEvent("PLAYER_REGEN_ENABLED", function()
    if pending ~= nil then
        setFriendlyPlates(pending)
        rescan()
    end
end)

ns.Listen("PARTNER_CHANGED", function()
    if ns.db then
        rescan()
    end
end)

ns.Listen("LOGIN", function()
    if ns.db.heart and not friendlyPlatesOn() then
        ns.db.heartTurnedOnPlates = true
        setFriendlyPlates(true)
    end
    rescan()
end)
