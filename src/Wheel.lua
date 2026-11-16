-- Partner Panel: the ping wheel. Hold the key, flick toward an option, let go.
-- Letting go in the middle cancels. "/pp ping" opens it to click instead.
local _, ns = ...

local Wheel = {}
ns.Wheel = Wheel

local RADIUS = 92     -- from the middle of the wheel to the middle of each option
local DEAD_ZONE = 30  -- let go this close to the middle and nothing is sent
Wheel.ORDER = { "come", "follow", "grab", "watch", "stand" } -- clockwise, starting at the top
local STEP = 360 / #Wheel.ORDER

local frame, options, hint
local mode, originX, originY, hovered

-- Which option a cursor offset (in pixels from the middle) points at, or nil for the middle.
function Wheel.SliceAt(dx, dy)
    if dx * dx + dy * dy < DEAD_ZONE * DEAD_ZONE then
        return nil
    end
    local clockwise = (90 - math.deg(math.atan2(dy, dx))) % 360
    local i = math.floor((clockwise + STEP / 2) / STEP) % #Wheel.ORDER + 1
    return Wheel.ORDER[i]
end

local function cursor()
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1
    return x / scale, y / scale
end

local function highlight(kind)
    hovered = kind
    local accent = ns.Panel.Colors()
    for k, b in pairs(options) do
        if k == kind then
            b:SetBackdropBorderColor(accent[1], accent[2], accent[3], 1)
            b:SetAlpha(1)
        else
            b:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
            b:SetAlpha(0.8)
        end
    end
end

local function create()
    frame = CreateFrame("Frame", "PartnerPanelWheel", UIParent)
    frame:SetSize(RADIUS * 2 + 130, RADIUS * 2 + 70)
    frame:SetFrameStrata("DIALOG")
    frame:Hide()
    if UISpecialFrames then
        table.insert(UISpecialFrames, "PartnerPanelWheel") -- Escape closes it
    end

    options = {}
    for i, kind in ipairs(Wheel.ORDER) do
        local b = CreateFrame("Button", nil, frame, "BackdropTemplate")
        b:SetSize(112, 30)
        local angle = math.rad(90 - (i - 1) * STEP)
        b:SetPoint("CENTER", frame, "CENTER", math.cos(angle) * RADIUS, math.sin(angle) * RADIUS)
        b:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 18)
        icon:SetPoint("LEFT", 7, 0)
        icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. ns.Ping.ICONS[kind])
        local label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label:SetPoint("LEFT", icon, "RIGHT", 5, 0)
        label:SetText(ns.Ping.Text(kind))
        b:SetScript("OnClick", function()
            Wheel.Close()
            ns.Ping.Send(kind)
        end)
        b:SetScript("OnEnter", function()
            if mode == "click" then
                highlight(kind)
            end
        end)
        options[kind] = b
    end

    local cancel = CreateFrame("Button", nil, frame)
    cancel:SetSize(28, 28)
    cancel:SetPoint("CENTER")
    local x = cancel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    x:SetPoint("CENTER")
    x:SetText("|cffb0b0b0x|r")
    cancel:SetScript("OnClick", Wheel.Close)

    hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOM", 0, 2)

    frame:SetScript("OnUpdate", function()
        if mode == "hold" then
            local cx, cy = cursor()
            local kind = Wheel.SliceAt(cx - originX, cy - originY)
            if kind ~= hovered then
                highlight(kind)
            end
        end
    end)
    frame:SetScript("OnHide", function()
        mode = nil
    end)
end

-- "hold" (the key binding: let go to send) or "click" (/pp ping: click an option).
function Wheel.Open(how)
    if not (ns.db and ns.db.partner) then
        ns.Print("Link with your partner first, with |cffffffff/pp link|r.")
        return
    end
    if not frame then
        create()
    end
    mode = how or "click"
    originX, originY = cursor()
    local _, bg = ns.Panel.Colors()
    for _, b in pairs(options) do
        b:SetBackdropColor(bg[1], bg[2], bg[3], 0.92)
        b:EnableMouse(mode == "click")
    end
    hint:SetText(mode == "hold" and "Let go on an option to send it, or in the middle to cancel"
        or "Click an option to send it")
    highlight(nil)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", originX, originY)
    frame:Show()
end

function Wheel.Close()
    if frame then
        frame:Hide()
    end
    mode = nil
end

function Wheel.IsOpen()
    return mode ~= nil
end

-- Called by the key binding (Bindings.xml) on key down and key up.
function PartnerPanel_PingKey(keystate)
    if keystate == "down" then
        Wheel.Open("hold")
    elseif mode == "hold" then
        local cx, cy = cursor()
        local kind = Wheel.SliceAt(cx - originX, cy - originY)
        Wheel.Close()
        if kind then
            ns.Ping.Send(kind)
        end
    end
end

BINDING_HEADER_PARTNERPANEL = "Partner Panel"
BINDING_NAME_PARTNERPANEL_PING = "Ping your partner (hold, point, let go)"
