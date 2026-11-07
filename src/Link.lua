-- Partner Panel: pairing. One of you sends a request, the other gets a popup and accepts.
--   LINKREQ -> (popup) -> LINKOK / LINKNO,   and UNLINK to undo.
local _, ns = ...
local P = ns.Protocol

local Link = {}
ns.Link = Link

local REQUEST_TIMEOUT = 20
local pending -- { name } while waiting for an answer

local function setPartner(name)
    ns.db.partner = name
    if not name then
        ns.db.lastKnown = nil
    end
    ns.Fire("PARTNER_CHANGED", name)
end

local function linked(name)
    ns.Print("You and %s are linked! |cffff9f7a<3|r", name)
    ns.Fire("SAY_HELLO")
end

function Link.Request(name)
    name = ns.Normalize(name)
    if not name then
        ns.Print("Who should I link you with? Group up with them and type |cffffffff/partner link|r,"
            .. " or |cffffffff/partner link First Last|r.")
        return
    end
    if ns.SameName(name, ns.MyName()) then
        ns.Print("That's you, silly! Pick someone else.")
        return
    end
    pending = { name = name }
    ns.Comm.Send(name, P.Encode("LINKREQ", ns.VERSION))
    ns.Print("Asked %s to link up. They'll get a popup to accept.", name)
    if not ns.FindGroupUnit(name) then
        ns.Print("Tip: invite them to a group first - on WoW Forever, Partner Panel talks over the group channel.")
    end
    local request = pending
    C_Timer.After(REQUEST_TIMEOUT, function()
        if pending == request then
            pending = nil
            ns.Print("No answer from %s. Check you're grouped together and they have Partner Panel enabled.", name)
        end
    end)
end

function Link.Accept(name)
    if not name then
        return
    end
    local previous = ns.db.partner
    if previous and not ns.SameName(previous, name) then
        ns.Comm.Send(previous, P.Encode("UNLINK"))
    end
    setPartner(name)
    ns.Comm.Send(name, P.Encode("LINKOK", ns.VERSION))
    linked(name)
end

function Link.Decline(name)
    if name then
        ns.Comm.Send(name, P.Encode("LINKNO"))
    end
end

function Link.Unlink()
    local partner = ns.db.partner
    if not partner then
        ns.Print("You're not linked with anyone yet.")
        return
    end
    ns.Comm.Send(partner, P.Encode("UNLINK"))
    setPartner(nil)
    ns.Print("Unlinked from %s.", partner)
end

StaticPopupDialogs["PARTNERPANEL_LINK_REQUEST"] = {
    text = "%s wants to link up with you in |cffff9f7aPartner Panel|r.%s",
    button1 = ACCEPT or "Accept",
    button2 = DECLINE or "Decline",
    OnAccept = function(_, data)
        Link.Accept(data)
    end,
    OnCancel = function(_, data, reason)
        if reason == "clicked" then
            Link.Decline(data)
        end
    end,
    timeout = 60,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

ns.Listen("MESSAGE", function(kind, _, from)
    local partner = ns.db.partner
    if kind == "LINKREQ" then
        if partner and ns.SameName(partner, from) then
            Link.Accept(from) -- already linked: just confirm again
            return
        end
        local extra = partner and ("\n\n(This replaces your link with %s.)"):format(partner) or ""
        StaticPopup_Show("PARTNERPANEL_LINK_REQUEST", from, extra, from)
    elseif kind == "LINKOK" then
        if pending and ns.SameName(pending.name, from) then
            pending = nil
            setPartner(from)
            linked(from)
        end
    elseif kind == "LINKNO" then
        if pending and ns.SameName(pending.name, from) then
            pending = nil
            ns.Print("%s declined the link.", from)
        end
    elseif kind == "UNLINK" then
        if partner and ns.SameName(partner, from) then
            setPartner(nil)
            ns.Print("%s unlinked from you.", from)
        end
    end
end)
