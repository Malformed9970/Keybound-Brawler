KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler

-- The loop and the typer always run; the window only asks how many games to
-- play. order is the buy order (item ids); wants and bought are keyed by
-- tostring(itemId): wants[key]=1 for a ticked item, bought counts what this
-- addon has bought. emotes[tostring(emoteId)]=true for the shop's emotes the
-- Emote window has shown as learned. Rests are random within their ranges.
-- Shop at defaults to 5470 MGC, the price of all 19 unique offers; spending
-- what's left on coffers is on, and a new character starts with every
-- unique offer ticked (addon.TickNewCharacter). Defaults only fill in what a
-- character's saved file doesn't have: changing one never changes anyone's
-- saved settings.
local defaults={
    maxGames=0,
    wordDelayMs=1500,
    spendAt=5470, keepReserve=0, coffers=true,
    restMin=4, restMax=10,
    breakEvery=10, breakMin=5, breakMax=15,
    consoleLog=false, hideOwned=false,
    order={}, wants={}, bought={}, emotes={},
}

local function clamp(value,minimum,maximum) return math.max(minimum,math.min(maximum,math.floor(value))) end

local function sanitize(s)
    -- Settings from 0.3: switches are gone, "Spend the rest on coffers" carries over,
    -- either way (the default is on now).
    if s.buyCoffers~=nil and s.coffers==nil then s.coffers=s.buyCoffers=="Enabled" end
    for _,key in ipairs({"farmLoop","autoTyper","autoBuy","buyCoffers","debugLog"}) do s[key]=nil end
    -- Settings from the OCR typer (up to 0.9.0): replaced by the word delay.
    s.charsPerSecond=nil; s.submitDelayMs=nil
    -- Settings from before 0.8.3: Shop at defaulted to 9000, so a saved 9000
    -- is that default and moves to the new one, once.
    if s.settingsVersion==nil and s.spendAt==9000 then s.spendAt=defaults.spendAt end
    s.settingsVersion=1
    for key,value in pairs(defaults) do
        if type(s[key])~=type(value) then s[key]=type(value)=="table" and {} or value end
    end
    s.maxGames=clamp(s.maxGames,0,9999)
    s.wordDelayMs=clamp(s.wordDelayMs,250,5000)
    s.spendAt=clamp(s.spendAt,0,99999)
    s.keepReserve=clamp(s.keepReserve,0,99999)
    s.restMin=clamp(s.restMin,0,600); s.restMax=clamp(s.restMax,0,600)
    if s.restMin>s.restMax then s.restMin,s.restMax=s.restMax,s.restMin end
    s.breakEvery=clamp(s.breakEvery,0,50)
    s.breakMin=clamp(s.breakMin,1,25); s.breakMax=clamp(s.breakMax,1,25)
    if s.breakMin>s.breakMax then s.breakMin,s.breakMax=s.breakMax,s.breakMin end
    for i=#s.order,1,-1 do if type(s.order[i])~="number" then table.remove(s.order,i) end end
    for key,value in pairs(s.wants) do
        s.wants[key]=(type(key)=="string" and type(value)=="number" and value>0) and 1 or nil
    end
    for key,value in pairs(s.bought) do
        if type(key)~="string" or type(value)~="number" then s.bought[key]=nil end
    end
    for key,value in pairs(s.emotes) do
        if type(key)~="string" or value~=true then s.emotes[key]=nil end
    end
end

local function loadTable(path)
    if not FileExists(path) then return nil end
    local ok,value=pcall(FileLoad,path)
    if ok and type(value)=="table" then return value end
end

-- One settings file per character (name and home world), so alts and
-- multiboxed clients each keep their own shopping list and "bought" counts.
-- Other bytes than letters and digits are hex-escaped so different names
-- never share a file.
local function fileName(name,home)
    return "KeyboundSettings_"..name:gsub("[^%w]",function(c) return string.format("_%02X",c:byte()) end).."_"..home..".lua"
end

-- Loads the current character's settings. Until a character is known, the
-- defaults are used in memory and nothing is saved. A character's first load
-- starts from the shared file older versions used, minus its purchase counts.
function addon.LoadSettings()
    addon.paths=addon.paths or {}
    addon.paths.root=GetLuaModsPath()..[[KeyboundBrawler\]]
    addon.paths.folder=GetLuaModsPath()..[[ffxivminion\Lj\]]
    local name,home=Player.name,tonumber(Player.homeworld)
    addon.ownerName,addon.ownerHome=name,home
    addon.paths.settings=nil
    local loaded
    if type(name)=="string" and name~="" and home and home>0 then
        addon.paths.settings=addon.paths.folder..fileName(name,home)
        loaded=loadTable(addon.paths.settings)
        if not loaded then
            loaded=loadTable(addon.paths.folder..[[KeyboundSettings.lua]])
            if loaded then loaded.bought={} end
        end
    end
    -- A character with no saved settings at all (not even the old shared
    -- file) is new: its offers get ticked once FFXIVLib has loaded them.
    addon.settingsNew=addon.paths.settings~=nil and loaded==nil
    addon.settings=loaded or {}
    sanitize(addon.settings)
    addon.settingsChangedAt=nil
    addon.Shop.dirty=true; addon.Shop.ownedAt=nil
end

-- A new character starts with every unique offer ticked. The offers come
-- from FFXIVLib, which loads after the settings, so this runs once its data
-- is ready, and is saved like any edit.
function addon.TickNewCharacter()
    if not addon.settingsNew then return end
    addon.settingsNew=false
    for _,e in ipairs(addon.Lib.data.shop.items) do
        if not e.repeatable then addon.settings.wants[e.key]=1 end
    end
    addon.SettingsChanged()
end

-- Checked each pulse: loads the other file when a character logs in or the
-- client switches characters, saving pending edits to the previous one first.
-- Returns true when the character changed.
function addon.RefreshOwner()
    if Player.name==addon.ownerName and tonumber(Player.homeworld)==addon.ownerHome then return false end
    if addon.settingsChangedAt then addon.SaveSettings() end
    addon.LoadSettings()
    return true
end

function addon.SaveSettings()
    sanitize(addon.settings)
    addon.Shop.dirty=true
    addon.settingsChangedAt=nil
    if not addon.paths.settings then return end
    if not FolderExists(addon.paths.folder) then FolderCreate(addon.paths.folder) end
    local ok,result=pcall(FileSave,addon.paths.settings,addon.settings)
    if not ok or result==false then d("[KeyboundBrawler] Could not save "..addon.paths.settings) end
end

-- Edits from the window apply at once but are written to disk only after a
-- second without further changes, so dragging a slider doesn't write the
-- file every frame.
function addon.SettingsChanged()
    addon.settingsChangedAt=Now()
    addon.Shop.dirty=true
end

function addon.FlushSettings()
    if addon.settingsChangedAt and TimeSince(addon.settingsChangedAt)>=1000 then addon.SaveSettings() end
end
