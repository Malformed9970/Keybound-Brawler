KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Quest=addon.Quest or {}
local Q=addon.Quest

-- Runs the unlock quest from its sheet data (see Lib): the giver before it is
-- accepted, then each step's ToDo place, an NPC to talk to or an event range
-- to walk into, preferring a place on the current map.

local function quest() return addon.Lib.data.quest end

function Q.completed() return Quest:IsQuestCompleted(quest().id) end

-- Current sequence, or -1 while the quest is not held.
function Q.step() return GetQuestInfo(quest().id,"step") end

-- Why the game would not offer the quest yet, or nil.
function Q.blocker()
    local q=quest()
    if q.prereq and not Quest:IsQuestCompleted(q.prereq) then return "Complete \""..q.prereqName.."\" first" end
    if (Player.level or 0)<q.level then return "Reach level "..q.level.." first" end
end

function Q.target()
    local q=quest()
    local step=Q.step()
    if step==-1 then return q.start end
    local places=q.steps[step]
    if not places then return nil end
    local map=addon.currentMap()
    for _,place in ipairs(places) do if place.map==map then return place end end
    for _,place in ipairs(places) do if place.npc then return place end end
    return places[1]
end

-- A step that hasn't advanced after this many talks (or range visits) pauses.
Q.maxTries=5

function Q.reset() Q.nextInteract=0; Q.rangeFor=nil; Q.stepSeen=nil; Q.placeSeen=nil; Q.tries=0 end

-- Works the current step on its map. Returns true once the quest is
-- complete, false while working, or nil,error.
function Q.tick(place)
    if Q.completed() then return true end
    local acted,err=addon.Dialogs.handle(quest().name)
    if acted==nil then return nil,err end
    if acted then Q.nextInteract=Now()+3000; return false end
    if Now()<(Q.nextInteract or 0) then return false end
    local step=Q.step()
    if step~=Q.stepSeen or place~=Q.placeSeen then Q.stepSeen=step; Q.placeSeen=place; Q.tries=0 end
    if (Q.tries or 0)>=Q.maxTries then
        return nil,string.format("Step %d of \"%s\" didn't advance after %d tries",step,quest().name,Q.maxTries)
    end
    local square=place.map==addon.Lib.data.squareMap
    if place.npc then
        local done,moveErr=addon.Movement.interact({id=place.npc,name=place.name,pos=place.pos},square)
        if done==nil then return nil,moveErr end
        if done then Q.tries=(Q.tries or 0)+1; Q.nextInteract=Now()+3000 end
    else
        -- An event range: first a random point up to 2 y from its centre, so
        -- characters don't share a spot, then the centre itself if the step
        -- didn't advance there (or the point can't be reached).
        if Q.rangeFor~=place then Q.rangeFor=place; Q.rangeSpot=addon.Movement.scatter(place.pos,2); Q.rangeVisits=0 end
        local goal=Q.rangeVisits==0 and Q.rangeSpot or place.pos
        local arrived,moveErr=addon.Movement.goTo(goal,0.5,square)
        if arrived==nil then
            if goal==place.pos then return nil,moveErr end
            Q.rangeVisits=1
            return false
        end
        if arrived then Q.rangeVisits=Q.rangeVisits+1; Q.tries=(Q.tries or 0)+1; Q.nextInteract=Now()+3000 end
    end
    return false
end
