-- Partner Panel: the panel itself - a small, movable card showing your partner at a glance.
local _, ns = ...

local Panel = {}
ns.Panel = Panel

local WIDTH, HEIGHT = 240, 66
local ICON = "Interface\\Icons\\INV_Misc_Rune_01" -- the Hearthstone
local ACCENT = { 1, 0.62, 0.48 }

local frame, icon, nameText, levelText, line2, line3, healthBar

local function classColor(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then
        return c.r, c.g, c.b
    end
    return 1, 0.82, 0
end

local function statusWord(flags)
    if flags.dead then
        return "|cffff5555Dead|r"
    elseif flags.ghost then
        return "|cffb0b0ffGhost|r"
    elseif flags.combat then
        return "|cffff7f3fIn combat|r"
    elseif flags.afk then
        return "|cffffd200AFK|r"
    elseif flags.dnd then
        return "|cffffd200Busy|r"
    elseif flags.resting then
        return "|cff7fbfffResting|r"
    end
    return "|cff7fff7fOnline|r"
end

local function place(zone, subzone)
    if subzone and subzone ~= "" and subzone ~= zone then
        return zone .. " - " .. subzone
    end
    return zone or ""
end

function Panel.Render()
    if not frame then
        return
    end
    local v = ns.GetPartnerView()
    healthBar:Hide()
    levelText:SetText("")

    if not v then
        icon:SetDesaturated(true)
        nameText:SetText("No partner linked yet")
        nameText:SetTextColor(0.7, 0.7, 0.7)
        line2:SetText("Group up with them, then type |cffffffff/partner link|r")
        line3:SetText("")
        return
    end

    local s = v.online and v.status or nil
    local known = v.lastKnown or {}
    nameText:SetText(v.name)
    nameText:SetTextColor(classColor((s and s.class) or known.class))
    icon:SetDesaturated(not v.online)

    local level = (s and s.level) or known.level
    if level then
        levelText:SetText("Lv " .. level)
    end

    if s then
        line2:SetText(place(s.zone, s.subzone))
        local text = statusWord(s.flags)
        if s.mood and s.mood ~= "" then
            text = text .. "  |cffe6d2ff\"" .. s.mood .. "\"|r"
        end
        line3:SetText(text)
        if s.hp then
            healthBar:SetValue(s.hp)
            healthBar:Show()
        end
    elseif v.online then
        line2:SetText("Connected")
        line3:SetText("|cff7fff7fOnline|r")
    else
        if known.zone and known.zone ~= "" then
            line2:SetText(("Last seen in %s, %s"):format(known.zone, ns.Ago(time() - (known.at or time()))))
        else
            line2:SetText("Not seen yet")
        end
        if v.grouped then
            line3:SetText("|cff9d9d9dIn your group - waiting to hear from them|r")
        else
            line3:SetText("|cff9d9d9dOffline, or not in your group|r")
        end
    end
end

local function savePosition()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    ns.db.panel.point = { point, relPoint, x, y }
end

local function restorePosition()
    frame:ClearAllPoints()
    local p = ns.db.panel.point
    if p then
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 24, -140)
    end
end

local function showTooltip(self)
    local v = ns.GetPartnerView()
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Partner Panel", ACCENT[1], ACCENT[2], ACCENT[3])
    if v then
        GameTooltip:AddDoubleLine("Linked with", v.name, 1, 1, 1, 1, 1, 1)
        if v.online then
            GameTooltip:AddDoubleLine("Last heard from", ns.Ago(GetTime() - (v.lastSeen or GetTime())), 1, 1, 1, 1, 1, 1)
        end
        if v.version then
            GameTooltip:AddDoubleLine("Their version", v.version, 1, 1, 1, 0.7, 0.7, 0.7)
        end
        if v.demo then
            GameTooltip:AddLine("Demo mode - /partner demo to stop", 1, 0.82, 0)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(ns.db.panel.locked and "Locked in place (/partner unlock)" or "Drag to move (/partner lock to pin it)",
        0.7, 0.7, 0.7)
    GameTooltip:AddLine("/partner for all commands", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function create()
    frame = CreateFrame("Frame", "PartnerPanelFrame", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.09, 0.06, 0.07, 0.9)
    frame:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)

    icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("TOPLEFT", 9, -9)
    icon:SetTexture(ICON)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    levelText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    levelText:SetPoint("TOPRIGHT", -10, -10)

    nameText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 0)
    nameText:SetPoint("RIGHT", levelText, "LEFT", -6, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)

    line2 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line2:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -3)
    line2:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
    line2:SetJustifyH("LEFT")
    line2:SetWordWrap(false)

    line3 = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    line3:SetPoint("TOPLEFT", line2, "BOTTOMLEFT", 0, -3)
    line3:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
    line3:SetJustifyH("LEFT")
    line3:SetWordWrap(false)

    healthBar = CreateFrame("StatusBar", nil, frame)
    healthBar:SetPoint("BOTTOMLEFT", 9, 7)
    healthBar:SetPoint("BOTTOMRIGHT", -9, 7)
    healthBar:SetHeight(4)
    healthBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    healthBar:SetStatusBarColor(0.25, 0.85, 0.35)
    healthBar:SetMinMaxValues(0, 100)
    local bg = healthBar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)

    frame:SetScript("OnDragStart", function(self)
        if not ns.db.panel.locked then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        savePosition()
    end)
    frame:SetScript("OnEnter", showTooltip)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    restorePosition()
    frame:SetShown(ns.db.panel.shown)
    Panel.Render()
end

function Panel.Show()
    ns.db.panel.shown = true
    if frame then
        frame:Show()
        Panel.Render()
    end
end

function Panel.Hide()
    ns.db.panel.shown = false
    if frame then
        frame:Hide()
    end
end

function Panel.SetLocked(locked)
    ns.db.panel.locked = locked
end

function Panel.ResetPosition()
    ns.db.panel.point = nil
    if frame then
        restorePosition()
    end
end

ns.Listen("LOGIN", function()
    create()
    C_Timer.NewTicker(15, Panel.Render) -- keeps "5m ago" fresh
end)
ns.Listen("PARTNER_UPDATED", Panel.Render)
ns.Listen("PARTNER_CHANGED", Panel.Render)
