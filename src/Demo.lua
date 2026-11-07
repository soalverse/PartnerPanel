-- Partner Panel: demo mode - a pretend partner, so you can see the panel working solo.
local _, ns = ...

local Demo = { active = false }
ns.Demo = Demo

local SCENES = {
    { zone = "Elwynn Forest", subzone = "Goldshire", hp = 100, flags = { resting = true },
      mood = "Saving you a seat by the fire" },
    { zone = "Elwynn Forest", subzone = "Fargodeep Mine", flags = { combat = true },
      mood = "Saving you a seat by the fire" },
    { zone = "Westfall", subzone = "Sentinel Hill", hp = 72, flags = {}, mood = "come find me!" },
    { zone = "Stormwind City", subzone = "Trade District", hp = 100, flags = { afk = true, resting = true },
      mood = "brb snacks" },
    { zone = "Duskwood", subzone = "Darkshire", hp = 0, flags = { dead = true }, mood = "help lol" },
}

local step, ticker = 0, nil

function Demo.View()
    local scene = SCENES[step % #SCENES + 1]
    return {
        name = "Demo Partner",
        online = true,
        lastSeen = GetTime(),
        version = ns.VERSION,
        grouped = true,
        demo = true,
        status = {
            level = 12 + math.floor(step / #SCENES),
            class = "PALADIN",
            zone = scene.zone,
            subzone = scene.subzone,
            flags = scene.flags,
            hp = scene.hp,
            mood = scene.mood,
        },
    }
end

function Demo.Toggle()
    Demo.active = not Demo.active
    if Demo.active then
        step = 0
        ticker = C_Timer.NewTicker(4, function()
            step = step + 1
            ns.Fire("PARTNER_UPDATED")
        end)
        ns.Panel.Show()
        ns.Print("Demo on - the panel shows a pretend partner that changes every few seconds."
            .. " Type |cffffffff/partner demo|r again to stop.")
    else
        if ticker then
            ticker:Cancel()
            ticker = nil
        end
        ns.Print("Demo off.")
    end
    ns.Fire("PARTNER_UPDATED")
end
