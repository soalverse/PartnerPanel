-- Partner Panel: the panel itself - a small, movable card showing your partner at a glance.
local _, ns = ...

local Panel = {}
ns.Panel = Panel

local WIDTH, HEIGHT = 240, 72 -- 72 leaves the health bar room to breathe under the third line
local ICON = "Interface\\Icons\\INV_Misc_Rune_01" -- the Hearthstone, when we have no class to show
local CLASS_RING = "Interface\\TargetingFrame\\UI-Classes-Circles"

-- Colour themes, borrowed from the soalverse mood themes. "coral" is the original
-- look, and stays the default, so nobody's panel changes when they update.
local THEMES = {
    coral    = { label = "Coral",    accent = { 1.00, 0.62, 0.48 }, bg = { 0.090, 0.060, 0.070 } },
    storm    = { label = "Storm",    accent = { 0.62, 0.80, 0.86 }, bg = { 0.094, 0.188, 0.227 } },
    tempest  = { label = "Tempest",  accent = { 0.66, 0.85, 0.94 }, bg = { 0.047, 0.133, 0.212 } },
    ember    = { label = "Ember",    accent = { 0.85, 0.54, 0.42 }, bg = { 0.240, 0.210, 0.320 } },
    sunset   = { label = "Sunset",   accent = { 0.89, 0.58, 0.45 }, bg = { 0.290, 0.220, 0.220 } },
    sunlit   = { label = "Sunlit",   accent = { 0.75, 0.75, 0.25 }, bg = { 0.235, 0.267, 0.267 } },
    wisteria = { label = "Wisteria", accent = { 0.84, 0.66, 0.77 }, bg = { 0.227, 0.169, 0.290 } },
    fogbank  = { label = "Fogbank",  accent = { 0.69, 0.68, 0.66 }, bg = { 0.102, 0.102, 0.094 } },
}
local THEME_ORDER = { "coral", "storm", "tempest", "ember", "sunset", "sunlit", "wisteria", "fogbank" }
local DEFAULT_THEME = "coral"

local frame, icon, nameText, levelText, line2, line3, healthBar

local function theme()
    return THEMES[ns.db and ns.db.panel and ns.db.panel.theme or DEFAULT_THEME] or THEMES[DEFAULT_THEME]
end

-- The names a person can type, in the order they are offered.
function Panel.ThemeNames()
    local out = {}
    for _, key in ipairs(THEME_ORDER) do
        out[#out + 1] = THEMES[key].label
    end
    return out
end

function Panel.ThemeLabel()
    return theme().label
end

-- Returns the theme's label, or nil if there is no theme by that name.
function Panel.SetTheme(name)
    local key = tostring(name or ""):lower()
    if not THEMES[key] then
        return nil
    end
    ns.db.panel.theme = key
    Panel.ApplyTheme()
    return THEMES[key].label
end

function Panel.ApplyTheme()
    if not frame then
        return
    end
    local t = theme()
    frame:SetBackdropColor(t.bg[1], t.bg[2], t.bg[3], 0.9)
    frame:SetBackdropBorderColor(t.accent[1], t.accent[2], t.accent[3], 0.9)
end

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

-- Their class ring, if this client has the class art and we know their class.
local function setIcon(classFile)
    local coords = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
    if type(coords) == "table" and #coords == 4 then
        icon:SetTexture(CLASS_RING)
        icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        icon:SetTexture(ICON)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end
end

-- Green while they are fine, amber when it is getting thin, red when you should worry.
local function healthColor(pct)
    if pct <= 25 then
        return 0.85, 0.25, 0.25
    elseif pct <= 50 then
        return 0.95, 0.70, 0.25
    end
    return 0.25, 0.85, 0.35
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
        setIcon(nil)
        icon:SetDesaturated(true)
        nameText:SetText("No partner linked yet")
        nameText:SetTextColor(0.7, 0.7, 0.7)
        line2:SetText("Type |cffffffff/pp link|r together, or |cffffffff/pp link First Last|r")
        line3:SetText("")
        return
    end

    local s = v.online and v.status or nil
    local known = v.lastKnown or {}
    nameText:SetText(v.name)
    nameText:SetTextColor(classColor((s and s.class) or known.class))
    setIcon((s and s.class) or known.class)
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
            healthBar:SetStatusBarColor(healthColor(s.hp))
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
            line3:SetText("|cff9d9d9dOffline, or out of reach|r")
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
    local t = theme()
    GameTooltip:AddLine("Partner Panel", t.accent[1], t.accent[2], t.accent[3])
    if v then
        GameTooltip:AddDoubleLine("Linked with", v.name, 1, 1, 1, 1, 1, 1)
        if v.online then
            GameTooltip:AddDoubleLine("Last heard from", ns.Ago(GetTime() - (v.lastSeen or GetTime())), 1, 1, 1, 1, 1, 1)
            if v.via then
                GameTooltip:AddDoubleLine("Connected through", ns.Comm.Describe(v.via), 1, 1, 1, 1, 1, 1)
            end
        end
        if v.version then
            GameTooltip:AddDoubleLine("Their version", v.version, 1, 1, 1, 0.7, 0.7, 0.7)
        end
        if v.demo then
            GameTooltip:AddLine("Demo mode - /pp demo to stop", 1, 0.82, 0)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(ns.db.panel.locked and "Locked in place (/pp unlock)" or "Drag to move (/pp lock to pin it)",
        0.7, 0.7, 0.7)
    GameTooltip:AddLine("/pp for all commands", 0.7, 0.7, 0.7)
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
    Panel.ApplyTheme()

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
