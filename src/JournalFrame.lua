-- Partner Panel: the journal window. One section per partner, current partner first,
-- each with its link dates, time together, and firsts in the order they happened.
-- Opened from the settings page, or with /pp journal.
local _, ns = ...

local JournalFrame = {}
ns.JournalFrame = JournalFrame

local WIDTH, HEIGHT = 460, 500
local frame, scroll, child
local pool, used = {}, 0

local function line(font)
    used = used + 1
    local fs = pool[used]
    if not fs then
        fs = child:CreateFontString(nil, "OVERLAY", font)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        pool[used] = fs
    end
    fs:SetFontObject(font)
    fs:SetWidth(WIDTH - 70)
    fs:Show()
    return fs
end

local function classColor(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then
        return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
    end
    return "|cffffd200"
end

function JournalFrame.Render()
    if not frame then
        return
    end
    for _, fs in ipairs(pool) do
        fs:Hide()
        fs:ClearAllPoints()
    end
    used = 0
    local y = 0
    local function add(text, font, indent, gap)
        local fs = line(font)
        fs:SetText(text)
        fs:SetPoint("TOPLEFT", child, "TOPLEFT", indent or 0, -y)
        y = y + (fs:GetStringHeight() or 14) + (gap or 4)
    end

    local J = ns.Journal
    local partners, current = J.Partners()
    if #partners == 0 then
        add("Nothing here yet. Link up with someone, and your firsts together will start filling this in.",
            "GameFontHighlight")
    end
    for i, p in ipairs(partners) do
        if i > 1 then
            y = y + 16
        end
        local title = classColor(p.class) .. p.name .. "|r"
        if J.Key(p.name) == current then
            title = title .. "  |cff7fff7fyour partner now|r"
        end
        add(title, "GameFontNormalLarge", 0, 6)
        for _, l in ipairs(p.links) do
            add(J.LinkText(l), "GameFontHighlightSmall", 10)
        end
        add(J.TogetherText(p), "GameFontDisableSmall", 10, 8)
        if #p.firsts == 0 then
            add("No firsts yet. Go somewhere new together.", "GameFontDisableSmall", 10)
        end
        for _, f in ipairs(p.firsts) do
            add(("|cffb0b0b0%s|r   %s"):format(J.Date(f.at), f.text), "GameFontHighlight", 10)
        end
    end
    child:SetHeight(math.max(y, 1))
end

-- The words on screen, in order (for checking the layout without the game).
function JournalFrame.Lines()
    local out = {}
    for i = 1, used do
        out[i] = pool[i]:GetText()
    end
    return out
end

local function create()
    frame = CreateFrame("Frame", "PartnerPanelJournal", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:Hide()
    if UISpecialFrames then
        table.insert(UISpecialFrames, "PartnerPanelJournal") -- Escape closes it
    end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    title:SetText("Partner journal")
    local sub = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
    sub:SetText("Your firsts together, kept for every character on this account.")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    scroll = CreateFrame("ScrollFrame", nil, frame)
    scroll:SetPoint("TOPLEFT", 18, -62)
    scroll:SetPoint("BOTTOMRIGHT", -18, 16)
    child = CreateFrame("Frame", nil, scroll)
    child:SetSize(WIDTH - 50, 1)
    scroll:SetScrollChild(child)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local most = math.max(0, (child:GetHeight() or 0) - (self:GetHeight() or 0))
        local v = (self:GetVerticalScroll() or 0) - delta * 40
        self:SetVerticalScroll(math.max(0, math.min(most, v)))
    end)
end

function JournalFrame.Open()
    if not frame then
        create()
    end
    local accent, bg = ns.Panel.Colors()
    frame:SetBackdropColor(bg[1], bg[2], bg[3], 0.96)
    frame:SetBackdropBorderColor(accent[1], accent[2], accent[3], 0.9)
    -- The settings window sits on top of everything, so step it aside first.
    if SettingsPanel and SettingsPanel.IsShown and SettingsPanel:IsShown() and HideUIPanel then
        pcall(HideUIPanel, SettingsPanel)
    end
    scroll:SetVerticalScroll(0)
    frame:Show()
    JournalFrame.Render()
end

function JournalFrame.IsOpen()
    return frame ~= nil and frame:IsShown()
end

ns.Listen("JOURNAL_UPDATED", function()
    if JournalFrame.IsOpen() then
        JournalFrame.Render()
    end
end)
