KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Dialogs=addon.Dialogs or {}
local G=addon.Dialogs

-- Answers the windows that talking to quest and warp NPCs opens, with the
-- same control actions ffxivminion uses. Returns true when it acted (or is
-- waiting out a cutscene), false when nothing was open, or nil,error for a
-- menu with no line matching menuText. One action per 300 ms.
function G.handle(menuText)
    if TimeSince(G.lastAction or 0)<300 then return true end
    local acted,err=G.act(menuText)
    if acted then G.lastAction=Now() end
    return acted,err
end

G.windows={"Talk","JournalAccept","JournalResult","SelectYesno","SelectOk","SelectString","SelectIconString"}

-- Any window this module answers is open.
function G.open()
    for _,name in ipairs(G.windows) do if IsControlOpen(name) then return true end end
    return false
end

-- The "Skip cutscene?" menu that Esc brings up during a cutscene.
local function skipMenu()
    local select=IsControlOpen("SelectString") and GetControl("SelectString")
    local strings=select and select:GetStrings()
    local text=strings and strings[2]
    if not text or text=="" then return false end
    local S=FFXIVLib.API.Strings
    for _,key in ipairs({S.SKIP_CUTSCENE,S.SKIP_CUTSCENE_OPENING}) do
        if text==S.Get(key) then return true end
    end
    return false
end

local function answer(menuText)
    if skipMenu() then SelectConversationIndex(1); return true end
    if IsControlOpen("Talk") then UseControlAction("Talk","Click"); return true end
    if IsControlOpen("JournalAccept") then UseControlAction("JournalAccept","Accept"); return true end
    if IsControlOpen("JournalResult") then UseControlAction("JournalResult","Complete"); return true end
    -- CheckAccept ticks the checkbox some confirmations carry, such as the
    -- quest's "I understand" keyboard notice, before Yes.
    if IsControlOpen("SelectYesno") then
        UseControlAction("SelectYesno","CheckAccept"); UseControlAction("SelectYesno","Yes")
        return true
    end
    if IsControlOpen("SelectOk") then UseControlAction("SelectOk","Yes"); return true end
    local lines=GetConversationList()
    if table.valid(lines) then
        for index,line in pairs(lines) do
            if menuText and tostring(line):find(menuText,1,true) then SelectConversationLine(index); return true end
        end
        local shown={}
        for _,line in pairs(lines) do shown[#shown+1]=tostring(line) end
        return nil,"Unexpected menu: "..table.concat(shown," | ")
    end
    return false
end

-- Online status 15 is a cutscene, but the game also reports it while an
-- NPC's windows are up (the quest's keyboard notice), so open windows are
-- answered first. Only after a second with nothing to answer does Esc bring
-- up "Skip cutscene?" (as ffxivminion's c_skipcutscene does).
function G.act(menuText)
    local acted,err=answer(menuText)
    if acted~=false or Player.onlinestatus~=15 then G.quietSince=nil; return acted,err end
    G.quietSince=G.quietSince or Now()
    if TimeSince(G.quietSince)>1000 and TimeSince(G.lastEscape or 0)>1500 then PressKey(27); G.lastEscape=Now() end
    return true
end
