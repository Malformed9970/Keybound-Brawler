KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Emotes=addon.Emotes or {}
local E=addon.Emotes

-- Which of the shop's emotes you've learned. Minion has no emote unlock
-- check: no Inventory:IsUnlocked kind matches (kind 9 agreed with the real
-- list on only 196 of 333 emotes). The game's Emote window does list every
-- emote you have: its raw values hold a count, then six values per emote
-- (id, icon, flags, tab, name, text commands), favourites and history
-- included (read 2026-10-25). Learned emotes are remembered per character in
-- settings.emotes; an emote can't be unlearned.

-- One emote's six values: four uints, the name and the text commands. The
-- Favourites and History slots at the end can be empty (id 0, blank strings),
-- so only the first entry must have a real command ("/...").
local function isEntry(raw,i,first)
    for k=0,3 do
        local value=raw[i+k]
        if not value or tostring(value.type)~="uint" then return false end
    end
    local name,commands=raw[i+4],raw[i+5]
    return name~=nil and tostring(name.type)=="string" and commands~=nil and tostring(commands.type)=="string"
        and (not first or tostring(commands.value):sub(1,1)=="/")
end

-- The emote ids the open Emote window lists (a set), or nil when it isn't
-- open or its list hasn't loaded. The count is found by shape rather than a
-- fixed index: a uint whose first and last entries have that layout.
function E.list()
    if not IsControlOpen("Emote") then return nil end
    local control=GetControl("Emote")
    local raw=control and control:GetRawData()
    if not raw then return nil end
    for i=1,80 do
        local n=raw[i] and tostring(raw[i].type)=="uint" and tonumber(raw[i].value)
        if n and n>0 and n<5000 and isEntry(raw,i+1,true) and isEntry(raw,i+1+(n-1)*6) then
            local ids={}
            for k=0,n-1 do
                local value=raw[i+1+k*6]
                local id=value and tonumber(value.value)
                if id and id>0 then ids[id]=true end
            end
            return ids
        end
    end
end

-- Remembers the shop's emotes the open Emote window lists. Returns true when
-- the list was read.
function E.read()
    local ids=E.list()
    if not ids then return false end
    local learned,changed=addon.settings.emotes,false
    for _,e in ipairs(addon.Lib.data.shop.items) do
        if e.emote and ids[e.emote] and not learned[tostring(e.emote)] then
            learned[tostring(e.emote)]=true; changed=true
            addon.Debug.log("Emote "..tostring(e.emote).." is learned ("..tostring(e.name)..")")
        end
    end
    if changed then addon.SettingsChanged(); addon.Shop.checkOwned(true) end
    return true
end

-- Passive: whenever the Emote window is open (you opened it, or the loop
-- did), it is read once a second.
function E.tick()
    if E.passiveAt and TimeSince(E.passiveAt)<1000 then return end
    E.passiveAt=Now()
    if IsControlOpen("Emote") then E.read() end
end

-- Whether the loop should open the window to look: once per Start, while
-- one of the shop's emotes isn't known to be learned, ticked or not (the
-- shop list shows what you own). An emote can't be unlearned, so once
-- they're all known the window never opens again.
function E.needsCheck(run)
    if E.checkedRun==run then return false end
    local learned=addon.settings.emotes
    for _,e in ipairs(addon.Lib.data.shop.items) do
        if e.emote and not learned[tostring(e.emote)] then return true end
    end
    return false
end
