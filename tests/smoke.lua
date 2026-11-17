-- Headless smoke test: loads the real addon files for three fake players against a
-- stubbed WoW API, connects them in a party, and walks through linking, status,
-- moods, going offline and unlinking.
-- Run from the project root:  luajit tests/smoke.lua
-- (Uses setfenv, so it needs Lua 5.1 / LuaJIT - the same Lua WoW runs.)

-- Load order comes from the real TOC, so the test breaks if a file is added but not listed.
local FILES = {}
for line in io.lines("PartnerPanel.toc") do
    local name = line:match("^src[\\/](%w+)%.lua%s*$")
    if name then
        FILES[#FILES + 1] = name
    end
end
assert(#FILES > 0, "no src files found in PartnerPanel.toc")

---------------------------------------------------------------------------
-- Virtual clock + timers
---------------------------------------------------------------------------
local now, timers, timerSeq = 1000, {}, 0
local function schedule(delay, fn, interval)
    timerSeq = timerSeq + 1
    local t = { at = now + delay, fn = fn, interval = interval, seq = timerSeq }
    table.insert(timers, t)
    return t
end
local function advance(seconds)
    local stop = now + seconds
    while true do
        table.sort(timers, function(a, b)
            if a.at == b.at then return a.seq < b.seq end
            return a.at < b.at
        end)
        local t = timers[1]
        if not t or t.at > stop then break end
        table.remove(timers, 1)
        now = math.max(now, t.at)
        if not t.cancelled then
            if t.interval then
                t.at = now + t.interval
                table.insert(timers, t)
            end
            t.fn()
        end
    end
    now = stop
end

---------------------------------------------------------------------------
-- Generic UI object: any method is a no-op unless defined
---------------------------------------------------------------------------
local function uiObject(client, kind)
    local o = { kind = kind, scripts = {}, shown = true, text = "" }
    function o:SetScript(name, fn) self.scripts[name] = fn end
    function o:RegisterEvent(event) client.registered[event] = client.registered[event] or {}; table.insert(client.registered[event], self) end
    function o:RegisterUnitEvent(event) self:RegisterEvent(event) end
    function o:SetText(t) self.text = t or "" end
    function o:GetText() return self.text end
    function o:SetShown(v) self.shown = v and true or false end
    function o:Show() self.shown = true end
    function o:Hide() self.shown = false end
    function o:IsShown() return self.shown end
    function o:GetPoint() return "TOPLEFT", nil, "TOPLEFT", 24, -140 end
    function o:SetPoint(...) self.point = { ... } end
    function o:SetValue(v) self.value = v end
    function o:SetAlpha(a) self.alpha = a end
    function o:GetValue() return self.value end
    function o:SetChecked(v) self.checked = v and true or false end
    function o:GetChecked() return self.checked == true end
    function o:SetScale(v) self.scale = v end
    function o:SetBackdropColor(r, g, b, a) self.bgColor = { r, g, b, a } end
    function o:SetTexture(t) self.texture = t end
    function o:SetTexCoord(a, b, c, d) self.coords = { a, b, c, d } end
    function o:SetStatusBarColor(r, g, b) self.barColor = { r, g, b } end
    function o:CreateTexture()
        local tex = uiObject(client, "Texture")
        table.insert(client.textures, tex)
        return tex
    end
    function o:CreateFontString()
        local fs = uiObject(client, "FontString")
        fs.owner = self
        table.insert(client.fontStrings, fs)
        return fs
    end
    return setmetatable(o, { __index = function() return function() end end })
end

---------------------------------------------------------------------------
-- Network: party addon messages reach everyone in the group (sender included,
-- as WoW echoes them); whispers are dropped, as observed on WoW Forever.
---------------------------------------------------------------------------
local clients = {}
local group = {} -- list of clients in the party

local function inGroup(c)
    for _, m in ipairs(group) do if m == c then return true end end
    return false
end

local function fire(c, event, ...)
    for _, frame in ipairs(c.registered[event] or {}) do
        local fn = frame.scripts.OnEvent
        if fn then fn(frame, event, ...) end
    end
end

local function sendAddon(from, prefix, msg, channel, target)
    if #msg > 255 then error("addon message over 255 bytes: " .. #msg) end
    from.sent[#from.sent + 1] = { channel = channel, target = target, msg = msg }
    if channel == "PARTY" or channel == "RAID" then
        for _, m in ipairs(group) do
            schedule(0.1, function() fire(m, "CHAT_MSG_ADDON", prefix, msg, channel, from.name) end)
        end
    end
    return 0
end

-- Battle.net: friendships, and game data delivered between online friends.
local friendships = {}
local function bnetFriends(a, b)
    return friendships[a] ~= nil and friendships[a][b] == true
end
local function makeFriends(a, b)
    friendships[a] = friendships[a] or {}
    friendships[b] = friendships[b] or {}
    friendships[a][b], friendships[b][a] = true, true
end

local function sendBNet(from, id, prefix, text)
    if #text > 255 then error("Battle.net message over 255 bytes: " .. #text) end
    from.sent[#from.sent + 1] = { channel = "BNET", target = id, msg = text }
    for _, o in ipairs(clients) do
        if o.gaid == id and bnetFriends(from, o) and o.connected and from.connected then
            schedule(0.1, function() fire(o, "BN_CHAT_MSG_ADDON", prefix, text, "WHISPER", from.gaid) end)
        end
    end
end

---------------------------------------------------------------------------
-- A fake player running the addon
---------------------------------------------------------------------------
local function newClient(first, last, zone, opts)
    opts = opts or {}
    local n = #clients + 1
    local c = {
        first = first, last = last, name = first .. " " .. last,
        zone = zone, subzone = "", level = 10, class = "MAGE",
        afk = false, combat = false, hp = 80, maxhp = 100, connected = true, hidesInCombat = false,
        registered = {}, fontStrings = {}, textures = {}, log = {}, sent = {}, popups = {},
        map = 1429, x = 0.5, y = 0.5, inDungeon = false, cursorX = 500, cursorY = 500, itemCache = {},
        -- Battle.net: how this player's game account looks in a friend's list
        gaid = 1000 + n, battleTag = first .. "#" .. (4000 + n), bnetChar = first, bnetRealm = last,
    }
    local env = {}
    setmetatable(env, { __index = _G })

    local function others()
        local list = {}
        for _, m in ipairs(group) do if m ~= c then list[#list + 1] = m end end
        return list
    end
    local function unitClient(unit)
        if unit == "player" then return c end
        local i = unit:match("^party(%d)$")
        if i and inGroup(c) then return others()[tonumber(i)] end
        if unit:match("^nameplate%d+$") then return c.plateUnits[unit] end
        return nil
    end

    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        c.log[#c.log + 1] = table.concat(parts, " ")
    end
    env.GetBuildInfo = function() return "1.0", "1", "Nov 1 2026", 16001 end
    env.C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
    env.RegionalUniqueNamesEnabled = function() return true end
    env.GetTime = function() return now end
    env.time = function() return math.floor(now) end
    env.date = os.date
    env.C_Timer = {
        After = function(d, fn) schedule(d, fn) end,
        NewTicker = function(i, fn)
            local t = schedule(i, fn, i)
            return { Cancel = function() t.cancelled = true end }
        end,
    }
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return true end,
        SendAddonMessage = function(prefix, msg, channel, target) return sendAddon(c, prefix, msg, channel, target) end,
    }
    env.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, AddOnMessageLockdown = 11 } }
    env.CreateFrame = function(kind, name)
        local f = uiObject(c, kind)
        if name then env[name] = f end
        return f
    end
    env.UIParent = uiObject(c, "Frame")
    env.GameTooltip = uiObject(c, "GameTooltip")
    env.RAID_CLASS_COLORS = { MAGE = { r = 0.25, g = 0.78, b = 0.92 }, PALADIN = { r = 0.96, g = 0.55, b = 0.73 } }
    env.CLASS_ICON_TCOORDS = { MAGE = { 0.25, 0.49, 0, 0.25 }, PALADIN = { 0, 0.25, 0.5, 0.75 } }
    env.ACCEPT, env.DECLINE = "Accept", "Decline"
    env.StaticPopupDialogs = {}
    env.StaticPopup_Show = function(which, a1, a2, data)
        c.popups[#c.popups + 1] = { which = which, a1 = a1, a2 = a2, data = data }
    end
    env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
    env.ChatFrameUtil = { AddMessageEventFilter = function(event, fn) c.chatFilter = fn end }
    env.SlashCmdList = {}
    env.LE_PARTY_CATEGORY_HOME, env.LE_PARTY_CATEGORY_INSTANCE = 1, 2

    env.IsInGroup = function(category)
        if category == 2 then return false end
        return inGroup(c) and #group > 1
    end
    env.IsInRaid = function() return false end
    env.GetNumGroupMembers = function() return inGroup(c) and #group or 0 end
    env.GetNumSubgroupMembers = function() return inGroup(c) and (#group - 1) or 0 end
    env.UnitName = function(unit)
        if unit == "target" and c.targetNPC then return c.targetNPC end
        local u = unitClient(unit)
        if u then return u.first, u.last end
        return nil
    end
    env.UnitGUID = function(unit)
        local u = unitClient(unit)
        return u and ("Player-" .. u.name) or nil
    end

    local function friendList()
        local list = {}
        for _, o in ipairs(clients) do
            if o ~= c and bnetFriends(c, o) then list[#list + 1] = o end
        end
        return list
    end
    local function gameInfo(o)
        return { gameAccountID = o.gaid, isOnline = o.connected, clientProgram = "WoW",
                 characterName = o.bnetChar, realmName = o.bnetRealm }
    end
    env.BNET_CLIENT_WOW = "WoW"
    env.BNGetNumFriends = function() local l = friendList(); return #l, #l end
    env.C_BattleNet = {
        GetFriendAccountInfo = function(i)
            local o = friendList()[i]
            if o then return { battleTag = o.battleTag, gameAccountInfo = gameInfo(o) } end
        end,
        GetFriendNumGameAccounts = function(i) return friendList()[i] and 1 or 0 end,
        GetFriendGameAccountInfo = function(i, j)
            local o = friendList()[i]
            if o and j == 1 then return gameInfo(o) end
        end,
        GetAccountInfoByGUID = function(guid)
            for _, o in ipairs(clients) do
                if ("Player-" .. o.name) == guid and bnetFriends(c, o) then
                    return { battleTag = o.battleTag, gameAccountInfo = gameInfo(o) }
                end
            end
        end,
        SendGameData = function(id, prefix, text) return sendBNet(c, id, prefix, text) end,
    }

    -- Maps: every map is 1000 yards across on one continent, so 0.01 of a map is 10 yards.
    env.C_Map = {
        GetBestMapForUnit = function() if c.inDungeon then return nil end return c.map end,
        GetPlayerMapPosition = function() return { x = c.x, y = c.y } end,
        CanSetUserWaypointOnMap = function() return true end,
        SetUserWaypoint = function(point) c.waypoint = point return true end,
        GetUserWaypoint = function() return c.waypoint end,
        ClearUserWaypoint = function() c.waypoint = nil end,
        GetMapInfo = function(map) return { name = (map == 1436 and "Westfall") or "Elwynn Forest" } end,
        GetWorldPosFromMapPos = function(_, v) return 0, { x = v.x * 1000, y = v.y * 1000 } end,
    }
    env.UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { uiMapID = m, position = { x = x, y = y } } end }
    env.CreateVector2D = function(x, y) return { x = x, y = y } end
    env.C_SuperTrack = {
        SetSuperTrackedUserWaypoint = function(v) c.supertracked = v end,
        IsSuperTrackingUserWaypoint = function() return c.supertracked == true end,
    }
    -- WoW's own "where the waypoint is on your screen" frame
    c.navFrame = uiObject(c, "Frame")
    env.C_Navigation = { GetFrame = function() return c.navFrame end }
    env.GetCursorPosition = function() return c.cursorX, c.cursorY end

    -- Items: the first look at an item this client has never seen asks the server.
    local ITEMS = { [19422] = "Darkmoon Faire Fortune", [2589] = "Linen Cloth" }
    env.GetItemInfo = function(item)
        local id = tonumber(tostring(item):match("item:(%d+)"))
        if not id or not ITEMS[id] then return nil end
        if not c.itemCache[id] then c.itemCache[id] = true return nil end
        local link = "|cffffffff|Hitem:" .. id .. "::::::::60:::::|h[" .. ITEMS[id] .. "]|h|r"
        return ITEMS[id], link, 1, 1, 0, "Misc", "Junk", 20, "", "Interface\\Icons\\Item" .. id
    end
    -- The modern settings window (Forever has it; an older client might not).
    if not opts.noSettings then
        env.Settings = {
            RegisterCanvasLayoutCategory = function(f) c.settingsFrame = f
                return { ID = 42, GetID = function(self) return self.ID end } end,
            RegisterAddOnCategory = function(cat) c.settingsCategory = cat end,
            OpenToCategory = function(id) c.openedSettings = id end,
        }
    end
    -- Key bindings: key -> command
    c.bindings = { B = "OPENALLBAGS" }
    env.GetBindingKey = function(command)
        local found = {}
        for k, cmd in pairs(c.bindings) do if cmd == command then found[#found + 1] = k end end
        table.sort(found)
        return found[1], found[2]
    end
    env.SetBinding = function(key, command) c.bindings[key] = command return true end
    env.SetBindingClick = function(key, button, mouse)
        c.bindings[key] = "CLICK " .. button .. ":" .. (mouse or "LeftButton") return true
    end
    env.GetBindingAction = function(key) return c.bindings[key] or "" end
    env.GetCurrentBindingSet = function() return 2 end
    env.SaveBindings = function(set) c.savedBindings = set end
    env.GetBindingText = function(key) return (key:gsub("SHIFT%-", "Shift-")) end
    env.InCombatLockdown = function() return c.lockdown == true end

    -- Nameplates: which character each nameplate token is showing, and WoW's settings
    c.plateUnits, c.plates, c.cvars = {}, {}, { nameplateShowFriends = "0" }
    env.C_NamePlate = { GetNamePlateForUnit = function(unit) return c.plates[unit] end }
    env.GetCVar = function(name) return c.cvars[name] end
    env.SetCVar = function(name, value) c.cvars[name] = tostring(value) end

    c.sounds = {}
    env.SOUNDKIT = { MAP_PING = 1, TELL_MESSAGE = 2 }
    env.PlaySound = function(id) c.sounds[#c.sounds + 1] = id end

    -- Modified clicks on items all pass through HandleModifiedItemClick.
    c.hooks, c.keys, c.button = {}, {}, "LeftButton"
    env.HandleModifiedItemClick = function() return false end
    env.hooksecurefunc = function(name, fn) c.hooks[name] = fn end
    env.IsAltKeyDown = function() return c.keys.alt == true end
    env.IsShiftKeyDown = function() return c.keys.shift == true end
    env.IsControlKeyDown = function() return c.keys.ctrl == true end
    env.GetMouseButtonClicked = function() return c.button end
    env.TooltipDataProcessor ={ AddTooltipPostCall = function(_, fn) c.tooltipPost = fn end }
    env.Enum.TooltipDataType = { Item = 0 }

    env.UnitExists = function(unit)
        if unit == "target" and c.targetNPC then return true end
        return unitClient(unit) ~= nil
    end
    env.UnitIsPlayer = function(unit) return unitClient(unit) ~= nil end
    env.UnitIsUnit = function(a, b) return unitClient(a) == unitClient(b) end
    env.UnitIsConnected = function(unit) local u = unitClient(unit); return u and u.connected or false end
    env.UnitLevel = function() return c.level end
    env.UnitClass = function() return "Mage", c.class end
    env.GetRealZoneText = function() return c.zone end
    env.GetInstanceInfo = function() return c.instanceName or c.zone, c.instanceType or "none" end
    env.GetSubZoneText = function() return c.subzone end
    env.UnitIsAFK = function() return c.afk end
    env.UnitIsDND = function() return false end
    env.UnitAffectingCombat = function() return c.combat end
    env.UnitIsGhost = function() return c.ghost == true end
    env.UnitIsDead = function() return c.dead == true or c.ghost == true end
    env.IsResting = function() return false end
    -- Some clients hand addons an opaque "secret value" instead of a real one mid-fight.
    local SECRET = setmetatable({}, { __tostring = function() return "secret" end })
    env.issecretvalue = function(v) return v == SECRET end
    env.UnitHealth = function() if c.combat and c.hidesInCombat then return SECRET end return c.hp end
    env.UnitHealthMax = function() if c.combat and c.hidesInCombat then return SECRET end return c.maxhp end

    -- Saved data from an earlier session, or shared with another character on the account.
    env.PartnerPanelDB = opts.account
    env.PartnerPanelCharDB = opts.charDB

    c.env = env
    c.ns = {}
    for _, file in ipairs(FILES) do
        local chunk = assert(loadfile("src/" .. file .. ".lua"))
        setfenv(chunk, env)
        chunk("PartnerPanel", c.ns)
    end
    c.slash = function(text) env.SlashCmdList.PARTNERPANEL(text) end
    clients[#clients + 1] = c
    return c
end

local function panel(c)
    -- the card's own text, created in order: level, name, line2, line3
    local fs = {}
    for _, f in ipairs(c.fontStrings) do
        if f.owner == c.env.PartnerPanelFrame then fs[#fs + 1] = f end
    end
    return { level = fs[1].text, name = fs[2].text, line2 = fs[3].text, line3 = fs[4].text, line4 = fs[5] and fs[5].text or "" }
end

---------------------------------------------------------------------------
-- Tiny test harness
---------------------------------------------------------------------------
local passed, failed = 0, 0
local function check(label, cond, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. label .. (detail and ("\n      " .. tostring(detail)) or ""))
    end
end
-- Toasts: the small notes at the top of the screen, in the order they appeared
local function toastHas(c, needle)
    for _, t in ipairs(c.ns.Toast.history) do
        if ((t.title or "") .. ": " .. (t.text or "")):find(needle, 1, true) then return true end
    end
    return false
end
local function toastCount(c, needle)
    local n = 0
    for _, t in ipairs(c.ns.Toast.history) do
        if ((t.title or "") .. ": " .. (t.text or "")):find(needle, 1, true) then n = n + 1 end
    end
    return n
end
local function logHas(c, needle)
    for _, line in ipairs(c.log) do
        if line:find(needle, 1, true) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- The story
---------------------------------------------------------------------------
local ally = newClient("Ally", "Rose", "Elwynn Forest")
local bram = newClient("Bram", "Stone", "Westfall")
local cara = newClient("Cara", "Moss", "Duskwood") -- a third party member

for _, c in ipairs(clients) do
    fire(c, "ADDON_LOADED", "PartnerPanel")
    fire(c, "PLAYER_LOGIN")
end
advance(5)

check("panel shows the not-linked state", panel(ally).name == "No partner linked yet", panel(ally).name)

-- Linking while not grouped: goes out as a whisper (which Forever drops)
ally.slash("link Bram Stone")
check("ungrouped link request is a whisper", ally.sent[#ally.sent].channel == "WHISPER")
check("ungrouped link gives the group-up tip", logHas(ally, "invite them to a group"))
advance(25)
check("unanswered request times out with a hint", logHas(ally, "No answer from Bram Stone"))

-- Group up: Ally, Bram and Cara
group = { ally, bram, cara }
for _, c in ipairs(clients) do fire(c, "GROUP_ROSTER_UPDATE") end
advance(1)

ally.slash("link bram-stone") -- typed oddly on purpose
advance(1)
check("Bram gets the link popup", #bram.popups == 1 and bram.popups[1].data == "Ally Rose",
    bram.popups[1] and bram.popups[1].data)
check("Cara (not addressed) gets no popup", #cara.popups == 0)
check("grouped messages are addressed on PARTY", ally.sent[#ally.sent].channel == "PARTY"
    and ally.sent[#ally.sent].msg:find("^@Bram Stone:") ~= nil, ally.sent[#ally.sent].msg)

bram.env.StaticPopupDialogs[bram.popups[1].which].OnAccept(nil, bram.popups[1].data)
advance(5)
check("Bram is linked to Ally", bram.ns.db.partner == "Ally Rose", bram.ns.db.partner)
check("Ally is linked to Bram", ally.ns.db.partner == "Bram Stone", ally.ns.db.partner)
check("Cara stays unlinked", cara.ns.db.partner == nil)
check("both get a toast for the new link", toastHas(ally, "Bram Stone: You are linked now") and toastHas(bram, "Ally Rose: You are linked now"))
check("and nothing about it in chat", not logHas(ally, "are linked") and not logHas(bram, "are linked"))

check("Ally sees Bram online", ally.ns.partnerState.online == true)
check("Ally's panel shows Bram's name", panel(ally).name == "Bram Stone", panel(ally).name)
check("Ally's panel shows Bram's zone", panel(ally).line2 == "Westfall", panel(ally).line2)
check("Ally's panel shows Bram's level", panel(ally).level == "Lv 10", panel(ally).level)
check("Bram's panel shows Ally's zone", panel(bram).line2 == "Elwynn Forest", panel(bram).line2)
check("Bram sees Ally's health", math.floor(bram.ns.partnerState.status.hp) == 80, bram.ns.partnerState.status.hp)

-- Bram moves and sets a mood
bram.subzone = "Sentinel Hill"
fire(bram, "ZONE_CHANGED")
bram.slash("mood come find me!")
advance(3)
check("zone change reaches Ally", panel(ally).line2 == "Westfall - Sentinel Hill", panel(ally).line2)
check("mood reaches Ally", panel(ally).line3:find("come find me!", 1, true) ~= nil, panel(ally).line3)

-- Combat: health now goes out mid-fight on a client that allows it
bram.combat = true
fire(bram, "PLAYER_REGEN_DISABLED")
advance(3)
check("combat status reaches Ally", panel(ally).line3:find("In combat", 1, true) ~= nil, panel(ally).line3)
check("health is shared in combat when the client allows it", ally.ns.partnerState.status.hp == 80, ally.ns.partnerState.status.hp)

-- ...and is quietly withheld on a client that keeps combat values private
bram.hidesInCombat = true
bram.hp = 55
fire(bram, "PLAYER_REGEN_DISABLED")
advance(3)
check("health is withheld when the client hides it", ally.ns.partnerState.status.hp == nil, ally.ns.partnerState.status.hp)
check("and the rest of the status still arrives", panel(ally).line3:find("In combat", 1, true) ~= nil, panel(ally).line3)
bram.hidesInCombat = false
bram.hp = 80
bram.combat = false
fire(bram, "PLAYER_REGEN_ENABLED")

-- Heartbeats keep it alive over time
advance(300)
check("still online after 5 minutes of heartbeats", ally.ns.partnerState.online == true)

-- Bram disconnects: he stays in the group (like a real disconnect) but goes silent
bram.connected = false
local bramSend = bram.env.C_ChatInfo.SendAddonMessage
bram.env.C_ChatInfo.SendAddonMessage = function() return 0 end
advance(15)
check("Ally sees Bram offline after he disconnects", ally.ns.partnerState.online == false)
check("offline panel shows last seen", panel(ally).line2:find("Last seen in Westfall", 1, true) ~= nil, panel(ally).line2)
bram.connected = true
bram.env.C_ChatInfo.SendAddonMessage = bramSend

-- Bram comes back: a roster update re-says hello
group = { ally, cara }
for _, c in ipairs(clients) do fire(c, "GROUP_ROSTER_UPDATE") end
advance(1)
group = { ally, bram, cara }
for _, c in ipairs(clients) do fire(c, "GROUP_ROSTER_UPDATE") end
advance(3)
check("rejoining the group reconnects", ally.ns.partnerState.online == true)

-- Hidden "No player named" message for our own background whispers
group = {}
for _, c in ipairs(clients) do fire(c, "GROUP_ROSTER_UPDATE") end
advance(50) -- let a heartbeat pass
ally.ns.Status.SayHello() -- and make sure a background whisper has just gone out
advance(2)
local hidden = ally.chatFilter(nil, "CHAT_MSG_SYSTEM", "No player named 'Bram Stone' is currently playing.")
check("not-found message for partner is hidden", hidden == true)
check("...and marks them offline", ally.ns.partnerState.online == false)
local shown = ally.chatFilter(nil, "CHAT_MSG_SYSTEM", "No player named 'Someone Else' is currently playing.")
check("not-found message for others is left alone", shown == false)

-- Demo mode and commands don't error
ally.slash("demo")
advance(5)
check("demo shows the pretend partner", panel(ally).name == "Demo Partner", panel(ally).name)
ally.slash("demo")
ally.slash("status")
check("status command prints the link", logHas(ally, "Linked with Bram Stone"))
ally.slash("")
check("help lists commands", logHas(ally, "/pp link"))
check("help still points at the long name", logHas(ally, "/partner"))
check("help lists the themes", logHas(ally, "Coral, Storm"))
ally.slash("hide"); ally.slash("show"); ally.slash("lock"); ally.slash("unlock"); ally.slash("reset")

-- The card wears the partner's class, when the client has the class art
local function iconOf(c)
    return c.textures[1] and c.textures[1].texture
end
check("icon: shows Bram's class ring", (iconOf(ally) or ""):find("UI-Classes-Circles", 1, true) ~= nil, iconOf(ally))
check("icon: falls back to the rune with no partner", (function()
    local saved = cara.ns.db.partner
    cara.ns.db.partner = nil
    cara.ns.Panel.Render()
    local tex = iconOf(cara)
    cara.ns.db.partner = saved
    return (tex or ""):find("INV_Misc_Rune_01", 1, true) ~= nil
end)(), iconOf(cara))

-- Themes
check("theme: the default is coral", ally.ns.db.panel.theme == "coral", ally.ns.db.panel.theme)
ally.slash("theme storm")
check("theme: set by name", ally.ns.db.panel.theme == "storm", ally.ns.db.panel.theme)
check("theme: it says which one", logHas(ally, "Theme set to"))
ally.slash("theme WISTERIA")
check("theme: the name is not case-sensitive", ally.ns.db.panel.theme == "wisteria", ally.ns.db.panel.theme)
ally.slash("theme nonsense")
check("theme: an unknown name changes nothing", ally.ns.db.panel.theme == "wisteria")
check("theme: and says so", logHas(ally, "There is no theme called"))
ally.slash("theme")
check("theme: with no name it reports yours", logHas(ally, "Your theme is"))
ally.slash("theme coral")
check("theme: back to the default", ally.ns.db.panel.theme == "coral")

-- Unlink (while grouped so the message arrives)
group = { ally, bram }
for _, c in ipairs(clients) do fire(c, "GROUP_ROSTER_UPDATE") end
advance(2)
ally.slash("unlink")
advance(2)
check("Ally is unlinked", ally.ns.db.partner == nil)
check("Bram hears the unlink", bram.ns.db.partner == nil and logHas(bram, "Ally Rose unlinked from you"))
check("panel back to not-linked", panel(ally).name == "No partner linked yet", panel(ally).name)

---------------------------------------------------------------------------
-- Battle.net: live updates while NOT grouped (e.g. he is off in a raid)
---------------------------------------------------------------------------
local function roster()
    for _, c in ipairs(clients) do fire(c, "GROUP_ROSTER_UPDATE") end
end
local function link(a, b)
    a.slash("link")
    advance(1)
    local p = b.popups[#b.popups]
    b.env.StaticPopupDialogs[p.which].OnAccept(nil, p.data)
    advance(5)
end

makeFriends(ally, bram)
group = { ally, bram }
roster()
advance(1)
link(ally, bram)
check("BN: relinked while grouped", ally.ns.db.partner == "Bram Stone" and bram.ns.db.partner == "Ally Rose")
check("BN: BattleTag learned from the group", ally.ns.db.partnerBattleTag == bram.battleTag, ally.ns.db.partnerBattleTag)
check("BN: grouped still prefers the group channel", ally.ns.Comm.Route("Bram Stone") == "PARTY")

-- He leaves to join a raid with other people
group = { bram, cara }
roster()
advance(3)
check("BN: after ungrouping, the route is Battle.net", ally.ns.Comm.Route("Bram Stone") == "BNET")
check("BN: hello goes out over Battle.net straight away", ally.sent[#ally.sent].channel == "BNET")

bram.zone, bram.subzone = "Duskwood", "Darkshire"
fire(bram, "ZONE_CHANGED_NEW_AREA")
advance(3)
check("BN: his zone change reaches her while ungrouped", panel(ally).line2 == "Duskwood - Darkshire", panel(ally).line2)
check("BN: her card knows it came through Battle.net", ally.ns.partnerState.via == "BNET", ally.ns.partnerState.via)

ally.slash("mood come find me!")
advance(3)
check("BN: her mood reaches him", panel(bram).line3:find("come find me!", 1, true) ~= nil, panel(bram).line3)
check("BN: he still reaches his raid over the group channel", bram.ns.Comm.Route("Cara Moss") == "PARTY")

local onlyBram = true
for _, s in ipairs(ally.sent) do
    if s.channel == "BNET" and s.target ~= bram.gaid then onlyBram = false end
end
check("BN: Battle.net messages only ever go to the partner", onlyBram)
check("BN: Cara (not a Battle.net friend) never got a popup or link", #cara.popups == 0 and cara.ns.db.partner == nil)

advance(300)
check("BN: still live after 5 minutes apart", ally.ns.partnerState.online == true and bram.ns.partnerState.online == true)

-- Forever might list character names in an unexpected shape: the BattleTag still finds him.
bram.bnetChar, bram.bnetRealm = "Bramble", nil
local bramSendBN = bram.env.C_BattleNet.SendGameData
bram.env.C_BattleNet.SendGameData = function() end -- keep him quiet so nothing refreshes the cache
advance(35)
check("BN: found by BattleTag when the name does not match", ally.ns.BNet.Resolve("Bram Stone") == bram.gaid)
bram.env.C_BattleNet.SendGameData = bramSendBN

-- Status command explains the route
ally.slash("status")
check("BN: status names the Battle.net route", logHas(ally, "Sending to them through: Battle.net"))
check("BN: status reports Battle.net found them", logHas(ally, "Battle.net: found them online"))

-- Linking from scratch without grouping, between Battle.net friends
group = {}
roster()
ally.slash("unlink")
advance(2)
check("BN: unlink reaches him over Battle.net", bram.ns.db.partner == nil)
bram.bnetChar, bram.bnetRealm = "Bram", "Stone"
ally.slash("link Bram Stone")
advance(1)
local p = bram.popups[#bram.popups]
check("BN: link request arrives without a group", p and p.data == "Ally Rose", p and p.data)
bram.env.StaticPopupDialogs[p.which].OnAccept(nil, p.data)
advance(5)
check("BN: linked without ever grouping", ally.ns.db.partner == "Bram Stone" and bram.ns.db.partner == "Ally Rose")

-- He logs off: Battle.net shows him offline, the card follows
bram.connected = false
advance(130)
check("BN: her card shows him offline after he logs off", ally.ns.partnerState.online == false)
check("BN: offline card says so", panel(ally).line3:find("Offline, or out of reach", 1, true) ~= nil, panel(ally).line3)

---------------------------------------------------------------------------
-- Pings: a pin and an arrow, dropped where you stand
---------------------------------------------------------------------------
local function logCount(c, needle)
    local n = 0
    for _, line in ipairs(c.log) do
        if line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

bram.connected = true
group = { ally, bram }
roster()
advance(5)
check("ping: back together for the ping tests", ally.ns.partnerState.online and bram.ns.partnerState.online)

ally.x, ally.y = 0.40, 0.60
bram.x, bram.y = 0.50, 0.50
ally.slash("ping come")
advance(1)
local wp = bram.waypoint
check("ping: Bram gets a map pin", wp ~= nil and wp.uiMapID == 1429, wp and wp.uiMapID)
check("ping: on the spot Ally stood", wp and math.abs(wp.position.x - 0.40) < 0.0001 and math.abs(wp.position.y - 0.60) < 0.0001)
check("ping: with the arrow switched on", bram.supertracked == true)
local mk = bram.env.PartnerPanelPingMarker
check("marker: floats over the spot", mk and mk.shown)
check("marker: with our path-to-an-X icon", mk and mk.icon.texture == [[Interface\AddOns\PartnerPanel\media\ping-come]], mk and mk.icon.texture)
local function sameCoords(c, want)
    if not c then return false end
    for i = 1, 4 do if math.abs(c[i] - want[i]) > 1e-6 then return false end end
    return true
end
check("marker: shows the first of its 8 frames", sameCoords(mk.icon.coords, { 0, 0.125, 0, 1 }),
    mk.icon.coords and table.concat(mk.icon.coords, ","))
local driver = bram.ns.flipbookDriver
driver.scripts.OnUpdate(driver, 0.2) -- a little over one frame's worth of time
check("marker: and plays on to the next", sameCoords(mk.icon.coords, { 0.125, 0.25, 0, 1 }),
    table.concat(mk.icon.coords, ","))
driver.scripts.OnUpdate(driver, 1.0) -- past the end of the loop
check("marker: then loops back round", sameCoords(mk.icon.coords, { 0, 0.125, 0, 1 }), table.concat(mk.icon.coords, ","))
local itemToast = bram.ns.Toast.Show("Test", "an item picture", "Interface\\Icons\\INV_Misc_Bag_08")
check("toast: an item picture is shown whole, not sliced", sameCoords(itemToast.icon.coords, { 0, 1, 0, 1 }))
bram.ns.Toast.Dismiss(itemToast)
check("marker: named, with the yards", mk and mk.label.text:find("Come here", 1, true) and mk.yards.text == "141 yd",
    mk and (mk.label.text .. " / " .. mk.yards.text))
mk.scripts.OnUpdate(mk, 0.3)
check("marker: pulses when it first appears", mk.scale and mk.scale > 1, mk.scale)
mk.scripts.OnUpdate(mk, 4)
check("marker: then settles", mk.scale == 1, mk.scale)
check("ping: and a toast, with how far", toastHas(bram, "Ally Rose: |cff7fff7fCome here|r, 141 yd"), bram.ns.Toast.history[#bram.ns.Toast.history].text)
check("ping: not in his chat", not logHas(bram, "Come here"))
check("ping: and nothing in hers for sending it", not logHas(ally, "Pinged") and not logHas(ally, "Come here|r"))
check("ping: his card says where to look", panel(bram).line4 == "Look for the arrow on your minimap", panel(bram).line4)
check("ping: his card shows it", panel(bram).line3:find("Come here", 1, true) ~= nil, panel(bram).line3)
check("ping: with how far away it is", panel(bram).line3:find("141 yd", 1, true) ~= nil, panel(bram).line3)

bram.x, bram.y = 0.405, 0.60 -- five yards off
advance(2)
check("ping: walking up to it clears his pin", bram.waypoint == nil)
check("ping: arriving is quiet for him", not logHas(bram, "made it") and not toastHas(bram, "made it"))
check("ping: and his card lets go of the hint", panel(bram).line4 == "", panel(bram).line4)
check("marker: gone once he gets there", not mk.shown)
check("ping: she gets a toast that he made it", toastHas(ally, "Bram Stone: Made it to your ping"))
check("ping: his card goes back to normal", panel(bram).line3:find("Come here", 1, true) == nil, panel(bram).line3)

ally.targetNPC = "Hogger"
ally.slash("ping watch")
advance(1)
check("ping: Watch out names her target", toastHas(bram, "Watch out|r: Hogger"))
ally.slash("ping come") -- straight after: too soon, dropped
advance(1)
check("ping: a second ping within a moment is dropped", bram.ns.Ping.Current().kind == "watch")
advance(3)
check("ping: standing on a Watch out does not count as made it", bram.waypoint ~= nil and bram.ns.Ping.Current() ~= nil)
ally.targetNPC = nil
advance(300)
check("ping: an old ping wears off after 5 minutes", bram.ns.Ping.Current() == nil)
check("ping: and takes its pin with it", bram.waypoint == nil)

bram.x, bram.y = 0.6, 0.6 -- well away from her, so the ping does not count as reached
ally.slash("ping stand")
advance(1)
check("marker: shows for Stand here", mk.shown and mk.label.text:find("Stand here", 1, true) ~= nil)
bram.waypoint = { uiMapID = 1436, position = { x = 0.1, y = 0.1 } } -- he puts down his own pin
advance(2)
check("marker: never floats over a pin he placed himself", not mk.shown)
advance(301)
check("ping: never clears a pin he placed himself", bram.waypoint and bram.waypoint.uiMapID == 1436)
bram.waypoint = nil

-- Follow me, over Battle.net
group = {}
roster()
advance(3)
check("ping: now apart, the route is Battle.net", ally.ns.Comm.Route("Bram Stone") == "BNET")
bram.x, bram.y = 0.9, 0.9
ally.slash("ping follow")
advance(1)
check("follow: he gets her spot", bram.waypoint and math.abs(bram.waypoint.position.x - 0.40) < 0.0001)
check("follow: her own card counts down", panel(ally).line4:find("Sharing where you are, 2:5", 1, true) ~= nil, panel(ally).line4)
check("follow: his card says to follow the arrow", panel(bram).line4 == "Follow the arrow on your minimap", panel(bram).line4)
ally.x = 0.45
advance(3)
check("follow: the pin moves with her", bram.waypoint and math.abs(bram.waypoint.position.x - 0.45) < 0.0001,
    bram.waypoint and bram.waypoint.position.x)
check("follow: one toast, not one per step", toastCount(bram, "Follow me") == 1, toastCount(bram, "Follow me"))
local before = #ally.sent
advance(9)
check("follow: standing still sends nothing", #ally.sent == before, #ally.sent - before)
ally.slash("ping stop")
advance(1)
check("follow: stop reaches him, quietly", bram.ns.Ping.Current() == nil and not logHas(bram, "stopped sharing"))
check("follow: you typed it, so chat answers you", logHas(ally, "Stopped sharing where you are."))
check("follow: and your card stops counting", panel(ally).line4 == "", panel(ally).line4)
check("follow: and clears his pin", bram.waypoint == nil)

advance(2)
ally.slash("ping follow")
advance(181)
check("follow: ends by itself after 3 minutes", not ally.ns.Ping.Following())
check("follow: running out says nothing in chat", logCount(ally, "Stopped sharing where you are.") == 1, logCount(ally, "Stopped sharing where you are."))

ally.inDungeon = true
local sentBefore = #ally.sent
ally.slash("ping come")
advance(1)
check("ping: in a dungeon it explains instead of sending", logHas(ally, "keeping your exact spot private")
    and #ally.sent == sentBefore)
ally.inDungeon = false

-- The wheel: hold the key, point, let go
local slice = ally.ns.Wheel.SliceAt
check("wheel: up is Come here", slice(0, 100) == "come")
check("wheel: up and right is Follow me", slice(95, 31) == "follow")
check("wheel: up and left is Stand here", slice(-95, 31) == "stand")
check("wheel: down and right is Grab this", slice(59, -81) == "grab")
check("wheel: down and left is Watch out", slice(-59, -81) == "watch")
check("wheel: the middle is cancel", slice(5, 5) == nil)

advance(2)
ally.cursorX, ally.cursorY = 500, 500
ally.env.PartnerPanel_PingKey("down")
check("wheel: opens on key down", ally.ns.Wheel.IsOpen())
ally.cursorY = 600
ally.env.PartnerPanel_PingKey("up")
advance(1)
check("wheel: closes on let go", not ally.ns.Wheel.IsOpen())
check("wheel: and sends what you pointed at", bram.ns.Ping.Current() and bram.ns.Ping.Current().kind == "come")

advance(2)
sentBefore = #ally.sent
ally.cursorX, ally.cursorY = 500, 500
ally.env.PartnerPanel_PingKey("down")
ally.cursorX = 510
ally.env.PartnerPanel_PingKey("up")
advance(1)
check("wheel: letting go in the middle sends nothing", #ally.sent == sentBefore)

---------------------------------------------------------------------------
-- "Should I keep this?"
---------------------------------------------------------------------------
local LINK = "|cffffffff|Hitem:19422::::::::60:::::|h[Darkmoon Faire Fortune]|h|r"
ally.slash("ask " .. LINK)
advance(2)
local ask = bram.env.PartnerPanelAsk
check("ask: Bram gets the question window", ask and ask.shown)
check("ask: it says who is asking", ask and ask.title.text == "Ally Rose asks: should I keep this?", ask and ask.title.text)
check("ask: and shows the item, once his game has looked it up", ask and ask.itemName.text:find("Darkmoon Faire Fortune", 1, true) ~= nil,
    ask and ask.itemName.text)
check("ask: asking puts nothing in chat", not logHas(ally, "Asked Bram Stone about"))

ally.slash("ask |cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r")
advance(2)
check("ask: a second question waits its turn", ask.itemName.text:find("Darkmoon", 1, true) ~= nil)

ask.buttons.keep.scripts.OnClick()
advance(2)
local a = ally.ns.db.answers[19422]
check("ask: his answer is saved on her side", a and a.answer == "keep" and a.from == "Bram Stone", a and a.answer)
check("ask: his answer arrives as a toast", toastHas(ally, "Bram Stone: Says |cff7fbfffKeep|r: "))
check("ask: and answering puts nothing in his chat", not logHas(bram, "Told Ally"))
check("ask: then the next question shows", ask.shown and ask.itemName.text:find("Linen Cloth", 1, true) ~= nil, ask.itemName.text)

local tip = { lines = {}, AddLine = function(self, t) self.lines[#self.lines + 1] = t end }
ally.tooltipPost(tip, { id = 19422 })
check("ask: the answer is on her tooltip", tip.lines[1] and tip.lines[1]:find("Bram Stone says", 1, true) ~= nil, tip.lines[1])
local tip2 = { lines = {}, AddLine = tip.AddLine }
ally.tooltipPost(tip2, { id = 2589 })
check("ask: and only on that item", #tip2.lines == 0)

ask.buttons.sell.scripts.OnClick()
advance(2)
check("ask: second answer saved too", ally.ns.db.answers[2589] and ally.ns.db.answers[2589].answer == "sell")
check("ask: the window goes away when nothing is left", not ask.shown)

sentBefore = #ally.sent
ally.slash("ask")
check("ask: with no item it explains how", logHas(ally, "shift-click the item") and #ally.sent == sentBefore)

-- Alt-click an item in your bags to ask
local CLOTH = "|cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"
local function altClick(c, link)
    c.hooks.HandleModifiedItemClick(link)
end
local asksSent = function()
    local n = 0
    for _, s in ipairs(ally.sent) do
        if s.msg:find("ASK", 1, true) then n = n + 1 end
    end
    return n
end
local asks = asksSent()
ally.keys.alt = true
altClick(ally, CLOTH)
altClick(ally, CLOTH) -- the same click passing through a second time
advance(2)
check("alt-click: asks about the item", ask.shown and ask.itemName.text:find("Linen Cloth", 1, true) ~= nil,
    ask.itemName.text)
check("alt-click: one click asks once", asksSent() == asks + 1, asksSent() - asks)
ask.buttons.bank.scripts.OnClick()
advance(2)
check("alt-click: and the answer comes back like any other", ally.ns.db.answers[2589].answer == "bank")

asks = asksSent()
ally.keys.shift = true
altClick(ally, CLOTH)
ally.keys.shift = false
ally.keys.alt = false
altClick(ally, CLOTH)
ally.keys.alt = true
ally.button = "RightButton"
altClick(ally, CLOTH)
ally.button = "LeftButton"
ally.keys.alt = false
advance(2)
check("alt-click: Shift, no Alt, or a right click never ask", asksSent() == asks, asksSent() - asks)

-- Nobody else can answer for your partner
cara.ns.db.partner = "Ally Rose"
cara.ns.Comm.Send("Ally Rose", cara.ns.Protocol.Encode("ANSWER", 2589, "keep"))
advance(2)
check("ask: an answer from someone who is not your partner is ignored", ally.ns.db.answers[2589].answer == "bank")

-- Unlinked: the ping and ask commands explain instead
cara.ns.db.partner = nil
cara.slash("ping come")
cara.slash("ask " .. LINK)
check("unlinked: ping and ask both point at /pp link", logCount(cara, "Link with your partner first") == 2)

---------------------------------------------------------------------------
-- The settings page, under Options > AddOns
---------------------------------------------------------------------------
local opt = ally.ns.Options.controls
local card = ally.env.PartnerPanelFrame
check("settings: the page is registered with the game", ally.settingsCategory ~= nil
    and ally.settingsFrame == ally.env.PartnerPanelOptions)
ally.slash("options")
check("settings: /pp options opens it", ally.openedSettings == 42, ally.openedSettings)

ally.ns.Options.Refresh()
check("settings: boxes start out matching the saved settings", opt.shown:GetChecked() and not opt.locked:GetChecked()
    and opt.altAsk:GetChecked() and opt.sounds:GetChecked())
check("settings: sliders start at 100% size and 90% background", opt.scale.valueText.text == "100%"
    and opt.alpha.valueText.text == "90%", opt.scale.valueText.text .. " " .. opt.alpha.valueText.text)

local function click(cb, value)
    cb:SetChecked(value)
    cb.scripts.OnClick(cb)
end
click(opt.locked, true)
check("settings: Lock it in place", ally.ns.db.panel.locked == true)
click(opt.shown, false)
check("settings: Show the card, off, hides it", ally.ns.db.panel.shown == false and not card.shown)
click(opt.shown, true)
check("settings: and on brings it back", ally.ns.db.panel.shown == true and card.shown)

opt.scale.scripts.OnValueChanged(opt.scale, 1.23)
check("settings: Size snaps to a step and resizes the card", ally.ns.db.panel.scale == 1.25 and card.scale == 1.25,
    tostring(ally.ns.db.panel.scale) .. " " .. tostring(card.scale))
check("settings: and shows it as a percentage", opt.scale.valueText.text == "125%", opt.scale.valueText.text)
opt.alpha.scripts.OnValueChanged(opt.alpha, 0.5)
check("settings: Background fades the card", card.bgColor and math.abs(card.bgColor[4] - 0.5) < 0.001,
    card.bgColor and card.bgColor[4])
ally.ns.Panel.SetScale(9)
check("settings: a silly size is kept within limits", ally.ns.db.panel.scale == ally.ns.Panel.SCALE_MAX)

opt.themes.storm.scripts.OnClick()
check("settings: a theme swatch sets the theme", ally.ns.db.panel.theme == "storm")
check("settings: and the page says which", opt.themeLabel.text == "Theme: Storm", opt.themeLabel.text)
ally.slash("theme ember")
ally.ns.Options.Refresh()
check("settings: a /pp change shows on the page", opt.themeLabel.text == "Theme: Ember", opt.themeLabel.text)

click(opt.altAsk, false)
asks = asksSent()
ally.keys.alt = true
altClick(ally, LINK)
ally.keys.alt = false
advance(2)
check("settings: with Alt-click off, Alt-click asks nothing", asksSent() == asks)
click(opt.altAsk, true)

local heard = #bram.sounds
advance(2)
ally.slash("ping come")
advance(1)
check("settings: a ping plays a sound", #bram.sounds == heard + 1)
bram.ns.db.sounds = false
advance(2)
ally.slash("ping grab")
advance(1)
check("settings: and stays quiet with sounds off", #bram.sounds == heard + 1)
bram.ns.db.sounds = true

ally.settingsFrame.OnDefault()
check("settings: Defaults puts everything back", ally.ns.db.panel.theme == "coral" and ally.ns.db.panel.scale == 1
    and math.abs(ally.ns.db.panel.alpha - 0.9) < 0.001 and ally.ns.db.panel.locked == false
    and ally.ns.db.altAsk == true and ally.ns.db.sounds == true and card.scale == 1)

-- The ping key, set from the settings page
local PING = "CLICK PartnerPanelPingButton:LeftButton"
local keyBtn, capture = opt.pingKey, opt.keyCapture
ally.ns.Options.Refresh()
check("key: starts out not set", keyBtn.text == "Not set", keyBtn.text)
keyBtn.scripts.OnClick(keyBtn, "LeftButton")
check("key: clicking it waits for a key", keyBtn.text == "Press a key...", keyBtn.text)
capture.scripts.OnKeyDown(capture, "G")
check("key: pressing G makes G the ping key", ally.bindings.G == PING, ally.bindings.G)
check("key: and saves it", ally.savedBindings == 2)
check("key: the button shows it", keyBtn.text == "G", keyBtn.text)
check("key: and chat confirms it", logHas(ally, "Your ping key is now |cffffffffG|r."))

keyBtn.scripts.OnClick(keyBtn, "LeftButton")
ally.keys.shift = true
capture.scripts.OnKeyDown(capture, "LSHIFT") -- the Shift key on its own is not a choice yet
capture.scripts.OnKeyDown(capture, "G")
ally.keys.shift = false
check("key: Shift + G works", ally.bindings["SHIFT-G"] == PING, ally.bindings["SHIFT-G"])
check("key: and the old G is let go", ally.bindings.G == nil, ally.bindings.G)
check("key: shown the way WoW writes it", keyBtn.text == "Shift-G", keyBtn.text)

keyBtn.scripts.OnClick(keyBtn, "LeftButton")
capture.scripts.OnKeyDown(capture, "ESCAPE")
check("key: Escape changes nothing", ally.bindings["SHIFT-G"] == PING and keyBtn.text == "Shift-G")

keyBtn.scripts.OnClick(keyBtn, "LeftButton")
capture.scripts.OnKeyDown(capture, "B")
check("key: taking a key that did something else", ally.bindings.B == PING)
check("key: says what it used to do", logHas(ally, "used to do something else (OPENALLBAGS)"))

ally.lockdown = true
keyBtn.scripts.OnClick(keyBtn, "LeftButton")
capture.scripts.OnKeyDown(capture, "H")
ally.lockdown = false
check("key: mid-fight it explains and changes nothing", ally.bindings.H == nil and ally.bindings.B == PING
    and logHas(ally, "during a fight"))

ally.bindings.J = "PARTNERPANEL_PING" -- one set through Keybindings, if that ever shows up
keyBtn.scripts.OnClick(keyBtn, "RightButton")
check("key: right-click clears it, wherever it was set", ally.bindings.B == nil and ally.bindings.J == nil)
check("key: and the button says so", keyBtn.text == "Not set", keyBtn.text)

-- The key itself: hold, point, let go
local pingBtn = ally.env.PartnerPanelPingButton
advance(2)
ally.cursorX, ally.cursorY = 500, 500
pingBtn.scripts.OnClick(pingBtn, "LeftButton", true)
check("key: pressing it opens the wheel", ally.ns.Wheel.IsOpen())
ally.cursorX = 600 -- right is between Follow me and Grab this; up-right is Follow me
ally.cursorY = 530
pingBtn.scripts.OnClick(pingBtn, "LeftButton", false)
advance(1)
check("key: letting go sends what you pointed at", not ally.ns.Wheel.IsOpen()
    and bram.ns.Ping.Current() and bram.ns.Ping.Current().kind == "follow",
    bram.ns.Ping.Current() and bram.ns.Ping.Current().kind)
ally.slash("ping stop")

advance(2)
ally.cursorX, ally.cursorY = 500, 500
pingBtn.scripts.OnClick(pingBtn, "LeftButton") -- a client that never says "let go"
ally.cursorY = 400
pingBtn.scripts.OnClick(pingBtn, "LeftButton")
advance(1)
check("key: where let go never arrives, a second press sends", not ally.ns.Wheel.IsOpen()
    and bram.ns.Ping.Current() and bram.ns.Ping.Current().kind ~= "follow")

-- The heart over your partner (off unless you turn it on)
local heartBox = opt.heart
local function plate(c, token, who)
    c.plateUnits[token] = who
    c.plates[token] = uiObject(c, "Frame")
    fire(c, "NAME_PLATE_UNIT_ADDED", token)
    return c.plates[token]
end
local function unplate(c, token)
    fire(c, "NAME_PLATE_UNIT_REMOVED", token)
    c.plateUnits[token], c.plates[token] = nil, nil
end
ally.ns.Options.Refresh()
check("heart: off to begin with", ally.ns.db.heart == false and not heartBox:GetChecked())
check("heart: and your nameplate setting is left alone", ally.cvars.nameplateShowFriends == "0")
local bramPlate = plate(ally, "nameplate2", bram)
check("heart: nothing shows while it is off", not ally.ns.Heart.IsShown())

click(heartBox, true)
local heart = ally.env.PartnerPanelHeart
check("heart: turning it on switches friendly nameplates on", ally.cvars.nameplateShowFriends == "1")
check("heart: floats over Bram", heart and heart.shown and heart.point and heart.point[2] == bramPlate,
    heart and heart.point and tostring(heart.point[2]))
check("heart: our heart picture, playing", heart.icon.texture == [[Interface\AddOns\PartnerPanel\media\ping-heart]]
    and sameCoords(heart.icon.coords, { 0, 0.125, 0, 1 }), heart.icon.texture)
plate(ally, "nameplate5", cara)
check("heart: someone else walking by changes nothing", heart.point[2] == bramPlate)
unplate(ally, "nameplate2")
check("heart: gone when he walks out of range", not heart.shown)
bramPlate = plate(ally, "nameplate7", bram)
check("heart: back when he is close again", heart.shown and heart.point[2] == bramPlate)
bramPlate.IsForbidden = function() return true end
ally.ns.Heart.Rescan()
check("heart: hidden where WoW keeps nameplates to itself", not heart.shown)
bramPlate.IsForbidden = nil
ally.ns.Heart.Rescan()

-- Follow me from him, while his nameplate is on her screen: the sparkle sits on his head
advance(3)
bram.slash("ping follow")
advance(1)
local amk = ally.env.PartnerPanelPingMarker
check("follow: the sparkle sits over his head, above the heart", amk and amk.shown and amk.point[2] == heart,
    amk and amk.point and tostring(amk.point[2]))
check("follow: just the sparkle, no words, up there", amk.label.text == "" and amk.yards.text == "")
unplate(ally, "nameplate7")
check("follow: out of range, it goes back to the map spot", amk.shown and amk.point[2] == ally.navFrame
    and amk.label.text:find("Follow me", 1, true) ~= nil)
bram.slash("ping stop")
advance(1)

click(heartBox, false)
check("heart: turning it off puts nameplates back how they were", ally.cvars.nameplateShowFriends == "0")
ally.cvars.nameplateShowFriends = "1" -- she had them on herself
click(heartBox, true)
click(heartBox, false)
check("heart: but leaves them on if you had them on yourself", ally.cvars.nameplateShowFriends == "1")
ally.cvars.nameplateShowFriends = "0"

ally.lockdown = true
click(heartBox, true)
check("heart: mid-fight, the nameplate change waits", ally.cvars.nameplateShowFriends == "0"
    and logHas(ally, "the heart appears once this one is over"))
ally.lockdown = false
fire(ally, "PLAYER_REGEN_ENABLED")
check("heart: and happens when the fight ends", ally.cvars.nameplateShowFriends == "1")
ally.settingsFrame.OnDefault()
check("heart: Defaults turns it off again", ally.ns.db.heart == false and ally.cvars.nameplateShowFriends == "0")

-- A client with no settings window: no errors, and /pp options says where to look
local dana = newClient("Dana", "Reed", "Elwynn Forest", { noSettings = true })
fire(dana, "ADDON_LOADED", "PartnerPanel")
fire(dana, "PLAYER_LOGIN")
advance(1)
dana.slash("options")
check("settings: without a settings window, it says where to look", logHas(dana, "Find the settings in Options"))
check("settings: and the card still works", panel(dana).name == "No partner linked yet", panel(dana).name)

---------------------------------------------------------------------------
-- Toasts fade on their own, a click sends one away, and at most three stack up
---------------------------------------------------------------------------
local T = ally.ns.Toast
for _, f in ipairs(T.Active()) do T.Dismiss(f) end
for i = 1, 4 do T.Show("Test", "note " .. i) end
local stack = T.Active()
check("toast: at most three at once", #stack == 3, #stack)
check("toast: newest on top", stack[1].text.text == "note 4" and stack[3].text.text == "note 2")
stack[1].scripts.OnUpdate(stack[1], 0.1)
check("toast: fades in", stack[1].alpha and stack[1].alpha > 0 and stack[1].alpha < 1, stack[1].alpha)
stack[1].scripts.OnUpdate(stack[1], 7)
check("toast: and is gone after a few seconds", #T.Active() == 2)
stack[2].scripts.OnClick(stack[2])
check("toast: a click sends one away", #T.Active() == 1)

---------------------------------------------------------------------------
-- The partner journal
---------------------------------------------------------------------------
local function start(c)
    fire(c, "ADDON_LOADED", "PartnerPanel")
    fire(c, "PLAYER_LOGIN")
end
local function firsts(c, partner)
    local p = c.ns.Journal.Page(partner)
    local out = {}
    for _, f in ipairs(p.firsts) do out[#out + 1] = f.text end
    return out
end
local function hasFirst(c, partner, text)
    for _, t in ipairs(firsts(c, partner)) do
        if t == text then return true end
    end
    return false
end
local function countFirst(c, partner, text)
    local n = 0
    for _, t in ipairs(firsts(c, partner)) do
        if t == text then n = n + 1 end
    end
    return n
end

local eve = newClient("Eve", "Hart", "Elwynn Forest")
local finn = newClient("Finn", "Cole", "Elwynn Forest")
start(eve)
start(finn)
advance(5)
group = { eve, finn }
roster()
advance(1)
link(eve, finn)
advance(3)

local page = eve.ns.Journal.Page("Finn Cole")
check("journal: linking opens a page for the partner", page and #page.links == 1)
check("journal: with the real link date", page.links[1].fromKnown == true and page.links[1].me == "Eve Hart")
check("journal: being in the same zone is a first", hasFirst(eve, "Finn Cole", "First time in Elwynn Forest together"),
    table.concat(firsts(eve, "Finn Cole"), " | "))
check("journal: he gets it too, in his own journal", hasFirst(finn, "Eve Hart", "First time in Elwynn Forest together"))

eve.zone = "Westfall"
fire(eve, "ZONE_CHANGED_NEW_AREA")
advance(3)
check("journal: one of you alone in a zone is not a first", not hasFirst(eve, "Finn Cole", "First time in Westfall together"))
finn.zone = "Westfall"
fire(finn, "ZONE_CHANGED_NEW_AREA")
advance(3)
check("journal: both there is", hasFirst(eve, "Finn Cole", "First time in Westfall together"))
fire(finn, "ZONE_CHANGED_NEW_AREA")
advance(3)
check("journal: and only once", countFirst(eve, "Finn Cole", "First time in Westfall together") == 1)

for _, c in ipairs({ eve, finn }) do
    c.zone, c.instanceName, c.instanceType = "The Deadmines", "The Deadmines", "party"
    fire(c, "ZONE_CHANGED_NEW_AREA")
end
advance(3)
check("journal: a dungeon together", hasFirst(eve, "Finn Cole", "First dungeon together: The Deadmines"))
check("journal: a dungeon is not also a zone", not hasFirst(eve, "Finn Cole", "First time in The Deadmines together"))

fire(eve, "BOSS_KILL", 639, "Edwin VanCleef")
fire(eve, "ENCOUNTER_END", 639, "Edwin VanCleef", 1, 5, 1)
fire(eve, "ENCOUNTER_END", 640, "Cookie", 1, 5, 0) -- a wipe
check("journal: a boss together", hasFirst(eve, "Finn Cole", "Beat Edwin VanCleef together for the first time"))
check("journal: told twice, written once", countFirst(eve, "Finn Cole", "Beat Edwin VanCleef together for the first time") == 1)
check("journal: a wipe is not a win", not hasFirst(eve, "Finn Cole", "Beat Cookie together for the first time"))

for _, c in ipairs({ eve, finn }) do
    c.zone, c.instanceName, c.instanceType = "Westfall", nil, nil
end
eve.level = 20
fire(eve, "PLAYER_LEVEL_UP", 20)
finn.level = 20
fire(finn, "PLAYER_LEVEL_UP", 20)
advance(3)
check("journal: your tenth levels", hasFirst(eve, "Finn Cole", "Eve Hart reached level 20"))
check("journal: and theirs", hasFirst(eve, "Finn Cole", "Finn Cole reached level 20"),
    table.concat(firsts(eve, "Finn Cole"), " | "))
eve.level = 21
fire(eve, "PLAYER_LEVEL_UP", 21)
check("journal: only every tenth level", not hasFirst(eve, "Finn Cole", "Eve Hart reached level 21"))

advance(2)
eve.slash("ping come")
advance(1)
advance(2)
finn.slash("ping watch")
advance(1)
check("journal: the first ping", hasFirst(eve, "Finn Cole", "First ping: Eve Hart sent Come here"))
check("journal: only the first", not hasFirst(eve, "Finn Cole", "First ping: Finn Cole sent Watch out"))
check("journal: his journal has the same first ping", hasFirst(finn, "Eve Hart", "First ping: Eve Hart sent Come here"))

eve.slash("ask " .. LINK)
advance(2)
finn.env.PartnerPanelAsk.buttons.keep.scripts.OnClick()
advance(2)
check("journal: the first answer", hasFirst(eve, "Finn Cole", "First \"Should I keep this?\": Finn Cole said Keep"))
check("journal: on his side too", hasFirst(finn, "Eve Hart", "First \"Should I keep this?\": Finn Cole said Keep"))

eve.dead, finn.dead = true, true
fire(eve, "PLAYER_DEAD")
fire(finn, "PLAYER_DEAD")
advance(3)
check("journal: dying in the same fight", hasFirst(eve, "Finn Cole", "First time Eve Hart and Finn Cole died in the same fight"))
eve.dead = false
fire(eve, "PLAYER_ALIVE")
finn.dead, finn.ghost = false, true
fire(finn, "PLAYER_ALIVE")
advance(3)
check("journal: running back as a ghost", hasFirst(eve, "Finn Cole", "First time Finn Cole ran back as a ghost while Eve Hart waited"),
    table.concat(firsts(eve, "Finn Cole"), " | "))
finn.ghost = false
fire(finn, "PLAYER_UNGHOST")

advance(600)
local together = page.links[1].together
check("journal: counts time online together", together >= 540 and together <= 660, together)
check("journal: and says it plainly", eve.ns.Journal.TogetherText(page):find("minutes online together", 1, true) ~= nil,
    eve.ns.Journal.TogetherText(page))

-- A new partner: Finn moves down the list, with his dates closed
local gus = newClient("Gus", "Pike", "Westfall")
start(gus)
advance(5)
group = { eve, gus }
roster()
advance(1)
eve.slash("link Gus Pike")
advance(1)
gus.env.StaticPopupDialogs[gus.popups[#gus.popups].which].OnAccept(nil, gus.popups[#gus.popups].data)
advance(5)
check("journal: changing partner closes the old link", page.links[1].to ~= nil)
local list, current = eve.ns.Journal.Partners()
check("journal: the partner you have now comes first", list[1].name == "Gus Pike" and list[2].name == "Finn Cole",
    list[1].name .. ", " .. (list[2] and list[2].name or "?"))
check("journal: Finn's firsts are kept", #firsts(eve, "Finn Cole") >= 10, #firsts(eve, "Finn Cole"))
check("journal: link dates read like a sentence", eve.ns.Journal.LinkText(page.links[1]):find("^On your mage Eve Hart, linked %d+ %a+ %d+ to %d+ %a+ %d+$") ~= nil,
    eve.ns.Journal.LinkText(page.links[1]))

eve.slash("journal")
local shown = eve.ns.JournalFrame.Lines()
check("journal: the window opens with /pp journal", eve.ns.JournalFrame.IsOpen())
check("journal: current partner on top, marked as now", shown[1]:find("Gus Pike", 1, true) and shown[1]:find("your partner now", 1, true),
    shown[1])
local finnAt, westfallAt
for i, t in ipairs(shown) do
    if t:find("Finn Cole", 1, true) and not finnAt then finnAt = i end
    if t:find("First time in Westfall together", 1, true) then westfallAt = i end
end
check("journal: then Finn, with his firsts under his name", finnAt and westfallAt and westfallAt > finnAt and finnAt > 1)
check("journal: each first has its date", westfallAt and shown[westfallAt]:find("%d+ %a+ %d+") ~= nil, westfallAt and shown[westfallAt])

local eveOpt = eve.ns.Options.controls
eve.env.PartnerPanelJournal:Hide()
eveOpt.journal.scripts.OnClick()
check("journal: the settings page has a button for it", eve.ns.JournalFrame.IsOpen())

-- A link from before the journal existed: honest about the missing date
local hana = newClient("Hana", "Brook", "Duskwood", {
    charDB = { partner = "Ivy Lane", mood = "", panel = { shown = true, locked = false, theme = "coral" } } })
start(hana)
local ivy = hana.ns.Journal.Page("Ivy Lane")
check("journal: an older link is kept, with the date it is missing", ivy and ivy.links[1] and ivy.links[1].fromKnown == false)
check("journal: and says so", hana.ns.Journal.LinkText(ivy.links[1]):find("linked since before", 1, true) ~= nil,
    hana.ns.Journal.LinkText(ivy.links[1]))

-- Two characters on one account share one journal
local account = { journal = {} }
local jade = newClient("Jade", "Moss", "Elwynn Forest", { account = account,
    charDB = { partner = "Kim Ray", mood = "", panel = { shown = true, locked = false, theme = "coral" } } })
start(jade)
local lark = newClient("Lark", "Moss", "Elwynn Forest", { account = account,
    charDB = { partner = "Max Oak", mood = "", panel = { shown = true, locked = false, theme = "coral" } } })
start(lark)
local larkList = lark.ns.Journal.Partners()
check("journal: one journal across your characters", #larkList == 2)
check("journal: the logged-in character's partner comes first", larkList[1].name == "Max Oak", larkList[1].name)
local jadeList = jade.ns.Journal.Partners()
check("journal: and on the other character, theirs does", jadeList[1].name == "Kim Ray", jadeList[1].name)
check("journal: each link says which character it was", larkList[2].links[1].me == "Jade Moss")

-- Nobody yet
local nova = newClient("Nova", "Vale", "Elwynn Forest")
start(nova)
nova.slash("journal")
check("journal: empty, it says what will appear", nova.ns.JournalFrame.Lines()[1]:find("Nothing here yet", 1, true) ~= nil)

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
