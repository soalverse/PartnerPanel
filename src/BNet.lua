-- Partner Panel: the Battle.net route, so cards stay live when you are not grouped.
--
-- Battle.net friends can send each other addon messages wherever they are. To use it we
-- need the partner's current WoW "game account" number. We find it two ways:
--   1. Their character name, matched against your Battle.net friends' online WoW accounts.
--   2. Their BattleTag, learned once while you are grouped (it never changes), so this
--      works even if WoW Forever reports character names in an unexpected shape.
-- Every call is guarded: if this client lacks an API, the route simply stays off.
local _, ns = ...
local P = ns.Protocol

local BNet = {}
ns.BNet = BNet

local FOUND_TTL, MISSING_TTL = 30, 10 -- seconds to trust a lookup
local cache = {}                     -- [lowercased name] = { id = gameAccountID or false, at = GetTime() }

local function api(name)
    return C_BattleNet and C_BattleNet[name] or nil
end

local function call(fn, ...)
    if not fn then
        return nil
    end
    local ok, a, b = pcall(fn, ...)
    if ok then
        return a, b
    end
    return nil
end

local function sendFunction()
    return api("SendGameData") or BNSendGameData
end

function BNet.Available()
    return sendFunction() ~= nil and api("GetFriendAccountInfo") ~= nil and BNGetNumFriends ~= nil
end

local function plain(v)
    return type(v) == "string" and v ~= "" and not ns.IsSecret(v)
end

-- The ways a game account's character might be written: "Demo", "Demo Chan", "Demo-Chan".
local function accountNames(g)
    if type(g) ~= "table" or not plain(g.characterName) then
        return {}
    end
    local out = { g.characterName }
    if plain(g.realmName) then
        out[#out + 1] = g.characterName .. " " .. g.realmName
        out[#out + 1] = g.characterName .. "-" .. g.realmName
    end
    return out
end

local function matchesName(g, target)
    for _, n in ipairs(accountNames(g)) do
        if ns.SameName(n, target) then
            return true
        end
    end
    return false
end

local function onlineWow(g)
    if type(g) ~= "table" or not g.isOnline or not g.gameAccountID or ns.IsSecret(g.gameAccountID) then
        return false
    end
    local wow = BNET_CLIENT_WOW or "WoW"
    if g.clientProgram and g.clientProgram ~= wow then
        return false
    end
    if WOW_PROJECT_ID and g.wowProjectID and g.wowProjectID ~= WOW_PROJECT_ID then
        return false -- logged into a different version of WoW
    end
    return true
end

-- Calls test(account, gameAccount) for every friend's game account; returns the first match.
local function find(test)
    local count = call(BNGetNumFriends) or 0
    local getAccount = api("GetFriendAccountInfo")
    local numGames, getGame = api("GetFriendNumGameAccounts"), api("GetFriendGameAccountInfo")
    for i = 1, count do
        local account = call(getAccount, i)
        if type(account) == "table" then
            local games = numGames and call(numGames, i) or 0
            if type(games) == "number" and games > 0 and getGame then
                for j = 1, games do
                    local g = call(getGame, i, j)
                    if test(account, g) then
                        return account, g
                    end
                end
            elseif test(account, account.gameAccountInfo) then
                return account, account.gameAccountInfo
            end
        end
    end
    return nil
end

local function remember(name, id)
    cache[name:lower()] = { id = id or false, at = GetTime() }
end

-- The game account number to reach `name` through Battle.net, or nil.
function BNet.Resolve(name)
    if not name or not BNet.Available() then
        return nil
    end
    local hit = cache[name:lower()]
    if hit and GetTime() - hit.at < (hit.id and FOUND_TTL or MISSING_TTL) then
        return hit.id or nil
    end
    local _, g = find(function(_, game)
        return onlineWow(game) and matchesName(game, name)
    end)
    local tag = ns.db and ns.db.partner and ns.SameName(ns.db.partner, name) and ns.db.partnerBattleTag
    if not g and tag then
        _, g = find(function(account, game)
            return onlineWow(game) and account.battleTag == tag
        end)
    end
    local id = g and g.gameAccountID or nil
    remember(name, id)
    return id
end

-- While grouped, learn the partner's BattleTag from their character (works even when
-- their character name shows up differently in the friends list).
function BNet.LearnFromUnit(unit, name)
    local byGuid = api("GetAccountInfoByGUID")
    local guid = call(UnitGUID, unit)
    if not byGuid or not plain(guid) then
        return
    end
    local account = call(byGuid, guid)
    if type(account) ~= "table" or not plain(account.battleTag) then
        return -- not Battle.net friends, or hidden
    end
    if ns.db.partnerBattleTag ~= account.battleTag then
        ns.db.partnerBattleTag = account.battleTag
    end
    local g = account.gameAccountInfo
    if type(g) == "table" and g.gameAccountID and not ns.IsSecret(g.gameAccountID) then
        remember(name, g.gameAccountID)
    end
end

function BNet.Send(gameAccountID, to, msg)
    local wrapped = P.WrapBNet(to, ns.MyName() or "?", msg)
    if #wrapped > P.MAX_LEN then
        return false
    end
    local ok = pcall(sendFunction(), gameAccountID, P.PREFIX, wrapped)
    return ok
end

-- Short description for /partner status.
function BNet.Describe(name)
    if not BNet.Available() then
        return "not available in this client"
    end
    if BNet.Resolve(name) then
        return "found them online"
    end
    if ns.db.partnerBattleTag then
        return "knows who they are, but they are not online in WoW right now"
    end
    return "not found yet (are you Battle.net friends? grouping once helps it learn)"
end

-- Receiving. Only Battle.net friends can send these; the name inside the envelope says who.
ns.OnEvent("BN_CHAT_MSG_ADDON", function(_, prefix, text, _, senderID)
    if ns.IsSecret(prefix) or ns.IsSecret(text) or ns.IsSecret(senderID) then
        return
    end
    if prefix ~= P.PREFIX or not ns.db then
        return
    end
    local to, from, body = P.UnwrapBNet(text)
    if not to or not ns.SameName(to, ns.MyName()) then
        return
    end
    from = ns.Normalize(from)
    if not from then
        return
    end
    local kind, fields = P.Decode(body)
    if kind then
        if type(senderID) == "number" then
            remember(from, senderID) -- reply the same way it came
        end
        ns.Fire("MESSAGE", kind, fields, from, "BNET")
    end
end)
