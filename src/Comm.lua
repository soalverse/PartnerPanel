-- Partner Panel: talking to your partner's copy of the addon.
--
-- How messages travel, best route first:
--   1. GROUP: when your partner is in your group, on the group channel, addressed to them
--      ("@Name:..."); everyone else's copy ignores it. Proven on WoW Forever.
--   2. BATTLE.NET: when you are not grouped but are Battle.net friends (BNet.lua).
--   3. WHISPER: a last resort. Addon whispers between players have not been seen to
--      arrive on Forever, but we still try, in case Blizzard fixes it.
local _, ns = ...
local P = ns.Protocol

local Comm = {}
ns.Comm = Comm

local BURST, RATE = 6, 1  -- up to 6 messages at once, then 1 per second
local MAX_TRIES = 90      -- ~90s of retrying while the game holds messages back (combat)
local tokens, refilledAt = BURST, 0
local queue = {}          -- { to, msg, key, tries }
local retryScheduled = false
local recentWhispers = {} -- [lowercased name] = GetTime() of last whisper

C_ChatInfo.RegisterAddonMessagePrefix(P.PREFIX)

local function groupChannel()
    if LE_PARTY_CATEGORY_INSTANCE and LE_PARTY_CATEGORY_HOME
        and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and not IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
    return nil
end

-- Returns channel, target  ("PARTY"/"RAID"/"INSTANCE_CHAT", nil | "BNET", gameAccountID | "WHISPER", name)
function Comm.Route(to)
    if ns.FindGroupUnit(to) then
        local channel = groupChannel()
        if channel then
            return channel, nil
        end
    end
    local gameAccountID = ns.BNet and ns.BNet.Resolve(to)
    if gameAccountID then
        return "BNET", gameAccountID
    end
    return "WHISPER", to
end

-- How a route reads to a person.
function Comm.Describe(channel)
    if channel == "BNET" then
        return "Battle.net"
    elseif channel == "WHISPER" then
        return "whisper (may not arrive on WoW Forever)"
    elseif channel then
        return "your group"
    end
    return "nothing yet"
end

-- Throttled ("too many, slow down") or held back (combat lockdown): try again shortly.
local function shouldRetry(result)
    if result == false then
        return true
    end
    if type(result) ~= "number" then
        return false
    end
    local codes = Enum and Enum.SendAddonMessageResult
    if codes and codes.AddonMessageThrottle and result == codes.AddonMessageThrottle then
        return true
    end
    local lockdown = (codes and (codes.AddOnMessageLockdown or codes.AddonMessageLockdown)) or 11
    return result == lockdown
end

local function flush()
    local now = GetTime()
    tokens = math.min(BURST, tokens + (now - refilledAt) * RATE)
    refilledAt = now

    while queue[1] and tokens >= 1 do
        local item = queue[1]
        local channel, target = Comm.Route(item.to)
        local msg = item.msg
        if channel == "BNET" then
            ns.BNet.Send(target, item.to, msg)
            table.remove(queue, 1)
            tokens = tokens - 1
        elseif channel ~= "WHISPER" and #P.Address(item.to, msg) > P.MAX_LEN or #msg > P.MAX_LEN then
            table.remove(queue, 1) -- shouldn't happen; drop rather than send garbage
        else
            if channel ~= "WHISPER" then
                msg = P.Address(item.to, msg)
            end
            local ok, result = pcall(C_ChatInfo.SendAddonMessage, P.PREFIX, msg, channel, target)
            if ok and shouldRetry(result) then
                item.tries = (item.tries or 0) + 1
                if item.tries > MAX_TRIES then
                    table.remove(queue, 1)
                end
                break
            end
            table.remove(queue, 1)
            tokens = tokens - 1
            if ok and channel == "WHISPER" then
                recentWhispers[item.to:lower()] = now
            end
        end
    end

    if queue[1] and not retryScheduled then
        retryScheduled = true
        C_Timer.After(1, function()
            retryScheduled = false
            flush()
        end)
    end
end

-- Sends an encoded message to `to`. With a `key`, an older queued message with the
-- same key is replaced (no point sending a stale status after a fresh one).
function Comm.Send(to, msg, key)
    if not to or not msg then
        return
    end
    if key then
        for i = #queue, 1, -1 do
            if queue[i].key == key then
                table.remove(queue, i)
            end
        end
    end
    table.insert(queue, { to = to, msg = msg, key = key })
    flush()
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
ns.OnEvent("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
    if ns.IsSecret(prefix) or ns.IsSecret(text) or ns.IsSecret(channel) or ns.IsSecret(sender) then
        return
    end
    if prefix ~= P.PREFIX or type(text) ~= "string" or not ns.db then
        return
    end
    local from = ns.Normalize(sender)
    local me = ns.MyName()
    if not from or ns.SameName(from, me) then
        return -- our own group message echoing back
    end
    local to, body = P.Unaddress(text)
    if channel ~= "WHISPER" and not (to and ns.SameName(to, me)) then
        return -- a group message meant for someone else
    end
    local kind, fields = P.Decode(body)
    if kind then
        ns.Fire("MESSAGE", kind, fields, from, channel)
    end
end)

---------------------------------------------------------------------------
-- Whispering someone offline prints "No player named 'X' is currently playing."
-- Hide that for our own background whispers, and treat it as "they're offline".
---------------------------------------------------------------------------
local notFoundPattern
local function notFoundName(msg)
    if not notFoundPattern then
        local fmt = ERR_CHAT_PLAYER_NOT_FOUND_S
        if type(fmt) ~= "string" then
            return nil
        end
        local escaped = (fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"))
        notFoundPattern = "^" .. (escaped:gsub("%%s", "(.+)")) .. "$"
    end
    return msg:match(notFoundPattern)
end

local function systemFilter(_, _, msg)
    if ns.IsSecret(msg) or type(msg) ~= "string" then
        return false
    end
    local who = notFoundName(msg)
    if not who then
        return false
    end
    who = ns.Normalize(who)
    for name, at in pairs(recentWhispers) do
        if GetTime() - at < 10 and ns.SameName(name, who) then
            ns.Fire("UNREACHABLE", who)
            return true -- hide it
        end
    end
    return false
end

local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
if addFilter then
    addFilter("CHAT_MSG_SYSTEM", systemFilter)
end
