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

    env.UnitExists = function(unit) return unitClient(unit) ~= nil end
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

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
    os.exit(1)
end
