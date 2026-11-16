-- Partner Panel: "Should I keep this?" Ask your partner about an item, they answer Equip,
-- Sell, Keep or Bank, and their answer stays on that item's tooltip.
--   ASK    = item string  (links are built from "|", which cannot travel, so we send
--                          the plain "item:19422:0:0..." inside the link instead)
--   ANSWER = item id, answer
local _, ns = ...
local P = ns.Protocol

local Keep = {}
ns.Keep = Keep

Keep.WORDS = { equip = "Equip", sell = "Sell", keep = "Keep", bank = "Bank" }
Keep.COLORS = { equip = "7fff7f", sell = "ff9f7a", keep = "7fbfff", bank = "ffd200" }

local waiting = {} -- questions for me to answer, oldest first: { from, item }
local frame, current

local function plainNumber(v)
    return type(v) == "number" and not ns.IsSecret(v)
end

local getItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Calls done(link, texture) once this client knows the item, or done(nil) if it never does.
-- The first lookup of an item you have never seen asks the server, so it may take a moment.
local function lookup(itemString, done, tries)
    local ok, _, link, _, _, _, _, _, _, _, texture = pcall(getItemInfo, itemString)
    if ok and type(link) == "string" and not ns.IsSecret(link) then
        done(link, texture)
        return
    end
    tries = (tries or 0) + 1
    if tries > 10 then
        done(nil)
        return
    end
    C_Timer.After(0.5, function()
        lookup(itemString, done, tries)
    end)
end

function Keep.Answer(itemID)
    local a = ns.db and ns.db.answers and ns.db.answers[itemID]
    if type(a) == "table" and Keep.WORDS[a.answer] then
        return a
    end
    return nil
end

function Keep.AnswerText(word)
    return ("|cff%s%s|r"):format(Keep.COLORS[word] or "ffffff", Keep.WORDS[word] or word)
end

---------------------------------------------------------------------------
-- Asking
---------------------------------------------------------------------------
function Keep.Ask(text)
    local partner = ns.db and ns.db.partner
    if not partner then
        ns.Print("Link with your partner first, with |cffffffff/pp link|r.")
        return false
    end
    local item = P.ItemString(text)
    if not item then
        ns.Print("Hold Alt and click the item in your bags. Or type |cffffffff/pp ask|r and a space,"
            .. " shift-click the item, then press Enter.")
        return false
    end
    ns.Comm.Send(partner, P.Encode("ASK", item))
    lookup(item, function(link)
        ns.Print("Asked %s about %s.", partner, link or "that item")
    end)
    return true
end

-- Alt-click an item to ask about it. WoW sends every modified click on an item (bags,
-- character sheet, loot, chat links) through HandleModifiedItemClick, so we listen there.
-- Only a plain Alt + left click counts: Shift links and splits, Ctrl previews, and those
-- stay WoW's. One click can pass through twice, so the same item within a second is ignored.
local lastAlt = { item = nil, at = 0 }

function Keep.OnModifiedClick(link)
    if not (IsAltKeyDown and IsAltKeyDown()) or (IsShiftKeyDown and IsShiftKeyDown())
        or (IsControlKeyDown and IsControlKeyDown()) then
        return
    end
    if GetMouseButtonClicked then
        local button = GetMouseButtonClicked()
        if button and button ~= "LeftButton" then
            return
        end
    end
    local item = P.ItemString(link)
    if not item or not (ns.db and ns.db.partner) then
        return
    end
    if lastAlt.item == item and GetTime() - lastAlt.at < 1 then
        return
    end
    lastAlt.item, lastAlt.at = item, GetTime()
    Keep.Ask(link)
end

if hooksecurefunc and HandleModifiedItemClick then
    hooksecurefunc("HandleModifiedItemClick", function(link)
        if type(link) == "string" and not ns.IsSecret(link) then
            Keep.OnModifiedClick(link)
        end
    end)
end

---------------------------------------------------------------------------
-- Answering: a small window, one question at a time
---------------------------------------------------------------------------
local showNext

local function create()
    frame = CreateFrame("Frame", "PartnerPanelAsk", UIParent, "BackdropTemplate")
    frame:SetSize(300, 112)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
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

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", 12, -12)
    frame.title:SetPoint("RIGHT", frame, "RIGHT", -30, 0)
    frame.title:SetJustifyH("LEFT")

    local item = CreateFrame("Button", nil, frame)
    item:SetSize(30, 30)
    item:SetPoint("TOPLEFT", 12, -32)
    frame.icon = item:CreateTexture(nil, "ARTWORK")
    frame.icon:SetAllPoints()
    item:SetScript("OnEnter", function(self)
        if current and current.link then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(current.link)
            GameTooltip:Show()
        end
    end)
    item:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    frame.itemName = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.itemName:SetPoint("LEFT", item, "RIGHT", 8, 0)
    frame.itemName:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
    frame.itemName:SetJustifyH("LEFT")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        current = nil
        frame:Hide()
        showNext()
    end)

    frame.buttons = {}
    for i, word in ipairs(P.ANSWERS) do
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(64, 22)
        b:SetPoint("BOTTOMLEFT", 12 + (i - 1) * 69, 12)
        b:SetText(Keep.WORDS[word])
        b:SetScript("OnClick", function()
            Keep.Reply(word)
        end)
        frame.buttons[word] = b
    end
end

function showNext()
    if current or not waiting[1] then
        return
    end
    current = table.remove(waiting, 1)
    if not frame then
        create()
    end
    local accent, bg = ns.Panel.Colors()
    frame:SetBackdropColor(bg[1], bg[2], bg[3], 0.95)
    frame:SetBackdropBorderColor(accent[1], accent[2], accent[3], 0.9)
    frame.title:SetText(("%s asks: should I keep this?"):format(current.from))
    frame.itemName:SetText("...")
    frame.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    frame:Show()
    local asked = current
    lookup(asked.item, function(link, texture)
        if current ~= asked then
            return
        end
        asked.link = link
        frame.itemName:SetText(link or ("Item " .. (P.ItemID(asked.item) or "?")))
        if texture then
            frame.icon:SetTexture(texture)
        end
    end)
    if PlaySound and SOUNDKIT and SOUNDKIT.TELL_MESSAGE then
        pcall(PlaySound, SOUNDKIT.TELL_MESSAGE)
    end
end

function Keep.Waiting()
    return current, #waiting
end

-- Sends my answer to the question on screen.
function Keep.Reply(word)
    if not (current and P.IsAnswer(word)) then
        return
    end
    local asked = current
    current = nil
    if frame then
        frame:Hide()
    end
    local id = P.ItemID(asked.item)
    if id and ns.db.partner and ns.SameName(ns.db.partner, asked.from) then
        ns.Comm.Send(asked.from, P.Encode("ANSWER", id, word))
        ns.Print("Told %s: %s %s.", asked.from, Keep.AnswerText(word), asked.link or "it")
    end
    showNext()
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
ns.Listen("MESSAGE", function(kind, fields, from)
    local partner = ns.db.partner
    if not partner or not ns.SameName(partner, from) then
        return
    end
    if kind == "ASK" then
        local item = P.ItemString(fields[1])
        if item and #waiting < 20 then
            waiting[#waiting + 1] = { from = from, item = item }
            showNext()
        end
    elseif kind == "ANSWER" then
        local id, word = tonumber(fields[1]), fields[2]
        if id and id > 0 and P.IsAnswer(word) then
            ns.db.answers = ns.db.answers or {}
            ns.db.answers[id] = { answer = word, from = from, at = time() }
            lookup("item:" .. id, function(link)
                ns.Print("%s says %s for %s.", from, Keep.AnswerText(word), link or "that item")
            end)
        end
    end
end)

ns.Listen("PARTNER_CHANGED", function()
    for i = #waiting, 1, -1 do
        waiting[i] = nil
    end
    if current then
        current = nil
        if frame then
            frame:Hide()
        end
    end
end)

---------------------------------------------------------------------------
-- Tooltips: "Partner Panel: Bram Stone says Keep"
---------------------------------------------------------------------------
local function addLine(tooltip, id)
    local a = plainNumber(id) and Keep.Answer(id)
    if a then
        tooltip:AddLine(("|cffff9f7aPartner Panel:|r %s says %s"):format(a.from, Keep.AnswerText(a.answer)))
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
    and Enum.TooltipDataType.Item then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if type(data) == "table" then
            addLine(tooltip, data.id)
        end
    end)
elseif GameTooltip and GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetItem") then
    GameTooltip:HookScript("OnTooltipSetItem", function(self)
        local _, link = self:GetItem()
        addLine(self, P.ItemID(P.ItemString(link)))
    end)
end
