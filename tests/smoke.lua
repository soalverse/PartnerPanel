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
    function o:SetValue(v) self.value = v end
    function o:SetTexture(t) self.texture = t end
    function o:SetStatusBarColor(r, g, b) self.barColor = { r, g, b } end
    function o:CreateTexture()
        local tex = uiObject(client, "Texture")
        table.insert(client.textures, tex)
        return tex
    end
    function o:CreateFontString()
        local fs = uiObject(client, "FontString")
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
local function newClient(first, last, zone)
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
    env.C_SuperTrack = { SetSuperTrackedUserWaypoint = function(v) c.supertracked = v end }
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
    env.GetSubZoneText = function() return c.subzone end
    env.UnitIsAFK = function() return c.afk end
    env.UnitIsDND = function() return false end
    env.UnitAffectingCombat = function() return c.combat end
    env.UnitIsGhost = function() return false end
    env.UnitIsDead = function() return false end
    env.IsResting = function() return false end
    -- Some clients hand addons an opaque "secret value" instead of a real one mid-fight.
    local SECRET = setmetatable({}, { __tostring = function() return "secret" end })
    env.issecretvalue = function(v) return v == SECRET end
    env.UnitHealth = function() if c.combat and c.hidesInCombat then return SECRET end return c.hp end
    env.UnitHealthMax = function() if c.combat and c.hidesInCombat then return SECRET end return c.maxhp end

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
    -- created in order: level, name, line2, line3
    local fs = c.fontStrings
    return { level = fs[1].text, name = fs[2].text, line2 = fs[3].text, line3 = fs[4].text }
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
check("both see the linked message", logHas(ally, "You and Bram Stone are linked") and logHas(bram, "You and Ally Rose are linked"))

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
check("ping: and a line in chat", logHas(bram, "Ally Rose: |cff7fff7fCome here|r (Elwynn Forest)"))
check("ping: Ally is told it went", logHas(ally, "Pinged Bram Stone"))
check("ping: his card shows it", panel(bram).line3:find("Come here", 1, true) ~= nil, panel(bram).line3)
check("ping: with how far away it is", panel(bram).line3:find("141 yd", 1, true) ~= nil, panel(bram).line3)

bram.x, bram.y = 0.405, 0.60 -- five yards off
advance(2)
check("ping: walking up to it clears his pin", bram.waypoint == nil)
check("ping: and tells him", logHas(bram, "You made it to Ally Rose's ping."))
check("ping: and tells her", logHas(ally, "Bram Stone made it to your ping."))
check("ping: his card goes back to normal", panel(bram).line3:find("Come here", 1, true) == nil, panel(bram).line3)

ally.targetNPC = "Hogger"
ally.slash("ping watch")
advance(1)
check("ping: Watch out names her target", logHas(bram, "Watch out|r: Hogger"))
ally.slash("ping come") -- straight after: too soon, dropped
advance(1)
check("ping: a second ping within a moment is dropped", bram.ns.Ping.Current().kind == "watch")
advance(3)
check("ping: standing on a Watch out does not count as made it", bram.waypoint ~= nil and bram.ns.Ping.Current() ~= nil)
ally.targetNPC = nil
advance(300)
check("ping: an old ping wears off after 5 minutes", bram.ns.Ping.Current() == nil)
check("ping: and takes its pin with it", bram.waypoint == nil)

ally.slash("ping stand")
advance(1)
bram.waypoint = { uiMapID = 1436, position = { x = 0.1, y = 0.1 } } -- he puts down his own pin
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
check("follow: she is told it lasts 3 minutes", logHas(ally, "for the next 3 minutes"))
ally.x = 0.45
advance(3)
check("follow: the pin moves with her", bram.waypoint and math.abs(bram.waypoint.position.x - 0.45) < 0.0001,
    bram.waypoint and bram.waypoint.position.x)
check("follow: without a new chat line each time", logCount(bram, "Follow me") == 1, logCount(bram, "Follow me"))
local before = #ally.sent
advance(9)
check("follow: standing still sends nothing", #ally.sent == before, #ally.sent - before)
ally.slash("ping stop")
advance(1)
check("follow: stop reaches him", logHas(bram, "Ally Rose stopped sharing where they are."))
check("follow: and clears his pin", bram.waypoint == nil)

advance(2)
ally.slash("ping follow")
advance(181)
check("follow: ends by itself after 3 minutes", not ally.ns.Ping.Following())
check("follow: and says so", logCount(ally, "Stopped sharing where you are.") == 2, logCount(ally, "Stopped sharing where you are."))

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
check("ask: Ally is told it went", logHas(ally, "Asked Bram Stone about"))

ally.slash("ask |cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r")
advance(2)
check("ask: a second question waits its turn", ask.itemName.text:find("Darkmoon", 1, true) ~= nil)

ask.buttons.keep.scripts.OnClick()
advance(2)
local a = ally.ns.db.answers[19422]
check("ask: his answer is saved on her side", a and a.answer == "keep" and a.from == "Bram Stone", a and a.answer)
check("ask: and she hears it", logHas(ally, "Bram Stone says |cff7fbfffKeep|r for"))
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

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
