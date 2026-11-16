-- Partner Panel: the settings page, under Options > AddOns > Partner Panel.
-- Drawn from plain widgets on a canvas page. Blizzard's auto-built settings list has
-- changed shape between WoW versions; the canvas page is the part confirmed on Forever.
-- Every change applies straight away, and /pp commands keep working alongside it.
local _, ns = ...

local Options = {}
ns.Options = Options

local frame, category
local controls = { themes = {} }
Options.controls = controls

local LEFT = 20

local function label(parent, template, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return fs
end

-- A checkbox at (x, y) from the top left, with a label and an optional grey note under it.
local function checkbox(key, y, text, note, get, set)
    local cb = CreateFrame("CheckButton", nil, frame)
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT, y)
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    local fs = label(cb, "GameFontHighlight", text)
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    if note then
        local n = label(cb, "GameFontDisableSmall", note)
        n:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3)
    end
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
    end)
    cb.refresh = function()
        cb:SetChecked(get() and true or false)
    end
    controls[key] = cb
    return cb
end

-- A horizontal slider with its name above and its value beside it.
local function slider(key, y, text, min, max, step, show, get, set)
    local name = label(frame, "GameFontHighlight", text)
    name:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT + 4, y)
    local s = CreateFrame("Slider", nil, frame, "BackdropTemplate")
    s:SetOrientation("HORIZONTAL")
    s:SetSize(220, 17)
    s:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -6)
    s:SetMinMaxValues(min, max)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then
        s:SetObeyStepOnDrag(true)
    end
    s:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local value = label(frame, "GameFontHighlightSmall", "")
    value:SetPoint("LEFT", s, "RIGHT", 10, 0)
    local refreshing = false
    s:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v / step + 0.5) * step
        value:SetText(show(v))
        if not refreshing then
            set(v)
        end
    end)
    s.refresh = function()
        refreshing = true
        local v = get()
        s:SetValue(v)
        value:SetText(show(v))
        refreshing = false
    end
    s.valueText = value
    controls[key] = s
    return s
end

local function percent(v)
    return ("%d%%"):format(math.floor(v * 100 + 0.5))
end

local function create()
    frame = CreateFrame("Frame", "PartnerPanelOptions")
    frame.name = "Partner Panel"

    local title = label(frame, "GameFontNormalLarge", "Partner Panel")
    title:SetPoint("TOPLEFT", LEFT, -16)
    local sub = label(frame, "GameFontHighlightSmall", "Everything here changes straight away. The /pp commands still work too.")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

    local journal = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    journal:SetSize(160, 24)
    journal:SetPoint("TOPLEFT", frame, "TOPLEFT", 300, -18)
    journal:SetText("Open the journal")
    journal:SetScript("OnClick", function()
        ns.JournalFrame.Open()
    end)
    controls.journal = journal

    -- The card
    local card = label(frame, "GameFontNormal", "The card")
    card:SetPoint("TOPLEFT", LEFT, -64)
    checkbox("shown", -84, "Show the card", nil,
        function() return ns.db.panel.shown end,
        function(v) if v then ns.Panel.Show() else ns.Panel.Hide() end end)
    checkbox("locked", -110, "Lock it in place", nil,
        function() return ns.db.panel.locked end,
        function(v) ns.Panel.SetLocked(v) end)
    local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    reset:SetSize(160, 22)
    reset:SetPoint("TOPLEFT", frame, "TOPLEFT", 300, -86)
    reset:SetText("Put it back")
    reset:SetScript("OnClick", function()
        ns.Panel.ResetPosition()
    end)
    controls.reset = reset

    slider("scale", -146, "Size", ns.Panel.SCALE_MIN, ns.Panel.SCALE_MAX, 0.05, percent,
        function() return ns.db.panel.scale or 1 end,
        function(v) ns.Panel.SetScale(v) end)
    slider("alpha", -196, "Background", ns.Panel.ALPHA_MIN, ns.Panel.ALPHA_MAX, 0.05, percent,
        function() return ns.db.panel.alpha or 0.9 end,
        function(v) ns.Panel.SetAlpha(v) end)

    -- Themes: one swatch each, in the theme's own colours
    local themeName = label(frame, "GameFontHighlight", "Theme")
    themeName:SetPoint("TOPLEFT", LEFT + 4, -248)
    controls.themeLabel = themeName
    for i, key in ipairs(ns.Panel.ThemeKeys()) do
        local accent, bg, name = ns.Panel.Colors(key)
        local b = CreateFrame("Button", nil, frame, "BackdropTemplate")
        b:SetSize(30, 30)
        b:SetPoint("TOPLEFT", frame, "TOPLEFT", LEFT + 4 + (i - 1) * 36, -268)
        b:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        b:SetBackdropColor(bg[1], bg[2], bg[3], 1)
        b:SetBackdropBorderColor(accent[1], accent[2], accent[3], 1)
        b:SetScript("OnClick", function()
            ns.Panel.SetTheme(key)
            Options.Refresh()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(name, accent[1], accent[2], accent[3])
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        controls.themes[key] = b
    end

    -- Pings and questions
    local talk = label(frame, "GameFontNormal", "Pings and questions")
    talk:SetPoint("TOPLEFT", LEFT, -318)
    checkbox("altAsk", -338, "Alt-click an item to ask about it",
        "Turn this off if another addon already uses Alt-click. /pp ask still works.",
        function() return ns.db.altAsk ~= false end,
        function(v) ns.db.altAsk = v end)
    checkbox("sounds", -378, "Play a sound when a ping or a question arrives", nil,
        function() return ns.db.sounds ~= false end,
        function(v) ns.db.sounds = v end)
    -- The ping key: click the button, then press the key you want
    local keyName = label(frame, "GameFontHighlight", "Ping key")
    keyName:SetPoint("TOPLEFT", LEFT + 4, -414)
    local keyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    keyButton:SetSize(150, 22)
    keyButton:SetPoint("LEFT", keyName, "RIGHT", 12, 0)
    keyButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local keyNote = label(frame, "GameFontDisableSmall",
        "Click, then press the key you want. Right-click clears it. Hold it, point at an option, and let go.")
    keyNote:SetPoint("TOPLEFT", keyName, "BOTTOMLEFT", 0, -12)

    local capture = CreateFrame("Frame", nil, frame)
    capture:Hide()
    local listening = false
    local function stopListening()
        listening = false
        capture:EnableKeyboard(false)
        capture:Hide()
        keyButton.refresh()
    end
    local MODIFIERS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
                        LMETA = true, RMETA = true, UNKNOWN = true }
    local function setKey(key)
        local ok, before = ns.Wheel.SetKey(key)
        if not ok then
            if before == "combat" then
                ns.Print("WoW does not let addons change keys during a fight. Try again once it is over.")
            else
                ns.Print("WoW would not set that key. Try another one.")
            end
        elseif key then
            ns.Print("Your ping key is now |cffffffff%s|r.", ns.Wheel.KeyText(key))
            if before then
                local was = _G["BINDING_NAME_" .. before] or before
                ns.Print("That key used to do something else (%s), so that is now unbound.", was)
            end
        else
            ns.Print("Ping key cleared. |cffffffff/pp ping|r still opens the wheel.")
        end
        keyButton.refresh()
    end
    capture:SetScript("OnKeyDown", function(_, key)
        if not listening or MODIFIERS[key] then
            return
        end
        stopListening()
        if key == "ESCAPE" then
            return
        end
        local combo = ((IsAltKeyDown and IsAltKeyDown()) and "ALT-" or "")
            .. ((IsControlKeyDown and IsControlKeyDown()) and "CTRL-" or "")
            .. ((IsShiftKeyDown and IsShiftKeyDown()) and "SHIFT-" or "") .. key
        setKey(combo)
    end)
    keyButton:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            stopListening()
            setKey(nil)
            return
        end
        listening = true
        self:SetText("Press a key...")
        capture:Show()
        capture:EnableKeyboard(true)
        if capture.SetPropagateKeyboardInput then
            pcall(capture.SetPropagateKeyboardInput, capture, false)
        end
    end)
    keyButton.refresh = function()
        if not listening then
            keyButton:SetText(ns.Wheel.KeyText(ns.Wheel.GetKey()) or "Not set")
        end
    end
    controls.pingKey = keyButton
    controls.keyCapture = capture

    frame:SetScript("OnShow", Options.Refresh)

    -- What the Settings window calls when you press Defaults, or opens the page.
    frame.OnDefault = Options.Defaults
    frame.OnRefresh = Options.Refresh
    frame.OnCommit = function() end
end

-- Brings every control in line with the saved settings.
function Options.Refresh()
    if not frame then
        return
    end
    for _, c in pairs(controls) do
        if type(c) == "table" and c.refresh then
            c.refresh()
        end
    end
    controls.themeLabel:SetText("Theme: " .. ns.Panel.ThemeLabel())
end

function Options.Defaults()
    ns.Panel.Show()
    ns.Panel.SetLocked(false)
    ns.Panel.SetTheme("coral")
    ns.Panel.SetScale(1)
    ns.Panel.SetAlpha(0.9)
    ns.db.altAsk = true
    ns.db.sounds = true
    Options.Refresh()
end

-- Opens the page, or says where it is if the game will not open it (it refuses mid-fight).
function Options.Open()
    if category and Settings and Settings.OpenToCategory then
        local id = (category.GetID and category:GetID()) or category.ID
        if id and pcall(Settings.OpenToCategory, id) then
            return
        end
    end
    ns.Print("Find the settings in Options, under AddOns, then Partner Panel.")
end

ns.Listen("INIT", function()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
        return -- no settings page on this client; the /pp commands still do everything
    end
    create()
    local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, frame, "Partner Panel")
    if ok and cat then
        category = cat
        pcall(Settings.RegisterAddOnCategory, cat)
    end
end)
