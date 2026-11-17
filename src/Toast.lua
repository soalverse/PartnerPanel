-- Partner Panel: toasts. Small notes at the top of the screen for the things worth
-- noticing (a ping arriving, an answer, a new link). They fade in, stay a few seconds,
-- and fade out; a click sends one away sooner. Everything routine stays out of chat.
local _, ns = ...

local Toast = {}
ns.Toast = Toast

local FADE_IN, HOLD, FADE_OUT = 0.25, 5, 1
local MAX = 3          -- at most this many on screen; the oldest makes way
local TOP = -110       -- from the top of the screen
local GAP = 56

local active, pool = {}, {}
Toast.history = {}     -- the last few, as { title, text } (handy for /pp status and tests)

local function layout()
    for i, f in ipairs(active) do
        f:ClearAllPoints()
        f:SetPoint("TOP", UIParent, "TOP", 0, TOP - (i - 1) * GAP)
    end
end

function Toast.Dismiss(f)
    for i = #active, 1, -1 do
        if active[i] == f then
            table.remove(active, i)
        end
    end
    f:Hide()
    pool[#pool + 1] = f
    layout()
end

local function make()
    local f = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
    f:SetSize(290, 48)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(26, 26)
    f.icon:SetPoint("LEFT", 11, 0)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetJustifyH("LEFT")
    f.title:SetWordWrap(false)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetJustifyH("LEFT")
    f.text:SetWordWrap(false)
    f:SetScript("OnClick", function(self)
        Toast.Dismiss(self)
    end)
    f:SetScript("OnUpdate", function(self, elapsed)
        self.age = self.age + (elapsed or 0)
        if self.age < FADE_IN then
            self:SetAlpha(self.age / FADE_IN)
        elseif self.age < FADE_IN + HOLD then
            self:SetAlpha(1)
        elseif self.age < FADE_IN + HOLD + FADE_OUT then
            self:SetAlpha(1 - (self.age - FADE_IN - HOLD) / FADE_OUT)
        else
            Toast.Dismiss(self)
        end
    end)
    return f
end

-- Shows a toast. `icon` is a texture path, or nil for none.
-- `frames` above 1 plays the icon as a looping flipbook (our ping icons are).
function Toast.Show(title, text, icon, frames)
    local f = table.remove(pool) or make()
    local accent, bg = ns.Panel.Colors()
    f:SetBackdropColor(bg[1], bg[2], bg[3], 0.95)
    f:SetBackdropBorderColor(accent[1], accent[2], accent[3], 0.95)
    f.title:ClearAllPoints()
    f.text:ClearAllPoints()
    local left = 12
    if icon then
        ns.Flipbook(f.icon, icon, frames)
        f.icon:Show()
        left = 44
    else
        f.icon:Hide()
    end
    f.title:SetPoint("TOPLEFT", left, -9)
    f.title:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.text:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -3)
    f.text:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.title:SetText(title or "")
    f.text:SetText(text or "")
    f.age = 0
    f:SetAlpha(0)
    f:Show()
    table.insert(active, 1, f)
    while #active > MAX do
        Toast.Dismiss(active[#active])
    end
    layout()
    table.insert(Toast.history, { title = title, text = text })
    while #Toast.history > 20 do
        table.remove(Toast.history, 1)
    end
    return f
end

-- The toasts on screen right now, newest first.
function Toast.Active()
    local out = {}
    for i, f in ipairs(active) do
        out[i] = f
    end
    return out
end
