KeyboundBrawler = KeyboundBrawler or {}
KeyboundBrawler.version="1.1.2"
local addon=KeyboundBrawler

function addon.Initialize()
    -- Reloads keep the global table: release movement and queued keys first.
    addon.Movement.stop(); addon.Typer.reset(); addon.Loop.reset(); addon.Quest.reset(); addon.Lib.reset(); addon.Coffers.reset()
    if addon.Capture then addon.Capture.reset() end
    addon.Shop.view=nil
    addon.LoadSettings(); addon.UI.init()
    -- Rest lengths are random.
    math.randomseed(os.time()+(Now() or 0)); math.random()
    addon.lastPulse=0; addon.pulse=0
    d("[KeyboundBrawler] Loaded v"..addon.version)
end

-- A loading screen. The game also reports loading (NowLoading open) while an
-- event fades the screen behind its windows, such as the unlock quest's
-- keyboard notice, so an open dialog means there's something to answer.
function addon.loading()
    return MIsLoading~=nil and MIsLoading() and not addon.Dialogs.open()
end

function addon.Update()
    if GetGameState()~=FFXIV.GAMESTATE.INGAME or addon.loading() then return end
    -- Firing words keeps its own pace, so it's checked on every update.
    if addon.Lib.ready() then addon.Typer.tick() end
    if TimeSince(addon.lastPulse or 0)<100 then return end
    addon.lastPulse=Now()
    addon.pulse=addon.pulse+1; addon.inPulse=true
    if addon.RefreshOwner() then addon.Loop.stop() end
    addon.FlushSettings()
    if addon.Lib.refresh() then
        addon.TickNewCharacter()
        addon.Emotes.tick(); addon.Shop.refreshView(); addon.Loop.tick(); addon.Coffers.tick()
        -- Development only, not in module.def: dev\Capture.lua records what
        -- happens in Keybound Square and the duty, dev\Tests.lua runs in-game
        -- scenarios (see dev\README.md).
        if addon.Capture then addon.Capture.tick() end
    end
    if addon.Tests then addon.Tests.tick() end
    addon.inPulse=false
end

function addon.Draw()
    if GetGameState()~=FFXIV.GAMESTATE.INGAME then return end
    addon.UI.draw()
end

-- Current MGC (the shop's cost currency), or nil until the FFXIVLib data is
-- loaded (FFXIVLib is unavailable while Optifine is enabled). Read once per
-- pulse; everything in that pulse shares the value.
function addon.mgc()
    if not addon.Lib.ready() then return nil end
    if addon.inPulse and addon.mgcPulse==addon.pulse then return addon.mgcValue end
    local value=tonumber(FFXIVLib.ItemHelpers.GetCurrencyCount(addon.Lib.data.shop.currency))
    if addon.inPulse then addon.mgcPulse=addon.pulse; addon.mgcValue=value end
    return value
end

function addon.currentMap() return tonumber(Player.localmapid) end

RegisterEventHandler("Module.Initalize",addon.Initialize,"KeyboundBrawler.Initialize")
RegisterEventHandler("Gameloop.Update",addon.Update,"KeyboundBrawler.Update")
RegisterEventHandler("Gameloop.Draw",addon.Draw,"KeyboundBrawler.Draw")
