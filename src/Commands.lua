-- Partner Panel: slash commands (/partner or /partnerpanel).
local _, ns = ...

local function help()
    ns.Print("v%s commands:", ns.VERSION)
    local w = "|cffffffff"
    print(w .. "  /partner link|r [First Last] - link with your partner (group up first; no name = your target or party member)")
    print(w .. "  /partner unlink|r - undo the link")
    print(w .. "  /partner mood|r <text> - a little message your partner sees (no text clears it)")
    print(w .. "  /partner show|r, " .. w .. "/partner hide|r - the partner panel")
    print(w .. "  /partner lock|r, " .. w .. "/partner unlock|r, " .. w .. "/partner reset|r - pin, free, or re-center the panel")
    print(w .. "  /partner demo|r - preview the panel with a pretend partner")
    print(w .. "  /partner status|r - connection details (handy when something isn't working)")
end

local function status()
    local partner = ns.db.partner
    ns.Print("You are %s.", ns.MyName() or "?")
    if not partner then
        ns.Print("Not linked with anyone yet.")
        return
    end
    local st = ns.partnerState
    local channel = ns.Comm.Route(partner)
    ns.Print("Linked with %s - %s.", partner, st.online and "|cff7fff7fconnected|r" or "|cff9d9d9dnot connected|r")
    ns.Print("Sending to them through: %s", ns.Comm.Describe(channel))
    if st.via then
        ns.Print("Hearing from them through: %s", ns.Comm.Describe(st.via))
    end
    ns.Print("Battle.net: %s", ns.BNet.Describe(partner))
    if st.lastSeen then
        ns.Print("Last heard from them %s (their version %s).", ns.Ago(GetTime() - st.lastSeen), st.version or "?")
    end
end

SLASH_PARTNERPANEL1 = "/partner"
SLASH_PARTNERPANEL2 = "/partnerpanel"
SlashCmdList.PARTNERPANEL = function(input)
    input = (input or ""):match("^%s*(.-)%s*$")
    local cmd, rest = input:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "link" then
        ns.Link.Request(rest ~= "" and rest or ns.GuessPartner())
    elseif cmd == "unlink" then
        ns.Link.Unlink()
    elseif cmd == "mood" then
        local mood = ns.Status.SetMood(rest)
        if mood == "" then
            ns.Print("Mood cleared.")
        else
            ns.Print("Mood set: \"%s\"", mood)
        end
    elseif cmd == "show" then
        ns.Panel.Show()
    elseif cmd == "hide" then
        ns.Panel.Hide()
        ns.Print("Panel hidden - |cffffffff/partner show|r brings it back.")
    elseif cmd == "lock" then
        ns.Panel.SetLocked(true)
        ns.Print("Panel locked.")
    elseif cmd == "unlock" then
        ns.Panel.SetLocked(false)
        ns.Print("Panel unlocked - drag it wherever you like.")
    elseif cmd == "reset" then
        ns.Panel.ResetPosition()
    elseif cmd == "demo" then
        ns.Demo.Toggle()
    elseif cmd == "status" then
        status()
    else
        help()
    end
end
