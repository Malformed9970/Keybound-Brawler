KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Movement=addon.Movement or {}
local M=addon.Movement

-- Before a standing spot is picked, the walk aims this close to the NPC.
M.interactRange=3.5
-- Standing spots: 1.8-3 y from the NPC, within 70 degrees either side of the
-- direction you come from, picked within 12 y of it (the final approach).
M.standNear,M.standFar,M.standArc,M.pickWithin=1.8,3,math.rad(70),12
-- How close a step toward the NPC goes when the game says it's out of reach.
M.closeRange=1.2
-- Sidesteps (yalms, alternating sides) when a straight walk is blocked.
M.detourSizes={4,8,12}

function M.stop()
    if M.owns then Player:Stop(); M.owns=false end
    M.mode=nil; M.target=nil; M.progress=nil; M.detour=nil
end

local function here() local p=Player.pos; return {x=p.x,y=p.y,z=p.z} end

-- Nearest targetable entity with this content ID (ENpc row id), or nil.
function M.find(contentId)
    local best,bestDistance
    for _,e in pairs(EntityList("targetable,contentid="..tostring(contentId)) or {}) do
        local d=math.distance2d(Player.pos,e.pos)
        if not bestDistance or d<bestDistance then best,bestDistance=e,d end
    end
    return best,bestDistance
end

-- Walks toward pos. Returns true once within range, false while walking, or
-- nil,error. Uses the navmesh; when the map has none and straight is set (only
-- for Keybound Square, a small open plaza), faces the goal and walks forward,
-- sidestepping when something is in the way. A new goal replaces the path
-- without stopping first.
--
-- Stuck means not moving: a path can lead away from the goal for a while
-- (around a building, down a ramp), so only the distance walked counts. A
-- yalm every 4 s, or it gives up.
function M.goTo(pos,range,straight)
    local d=math.distance2d(Player.pos,pos)
    if d<=range then M.stop(); return true end
    if not M.target or math.distance2d(M.target,pos)>0.5 then
        M.target={x=pos.x,y=pos.y,z=pos.z}; M.detour=nil; M.detours=0
        M.progress={pos=here(),at=Now()}
        local built=Player:MoveTo(pos.x,pos.y,pos.z,range,0,0,0)
        if built==false or (type(built)=="number" and built<=0) then
            if not straight then M.stop(); return nil,"No navigable path" end
            M.mode="straight"
        else
            M.mode="mesh"
        end
        M.owns=true
    end
    if M.mode=="straight" then
        if M.detour and math.distance2d(Player.pos,M.detour)<=1 then M.detour=nil end
        local goal=M.detour or pos
        Player:SetFacing(goal.x,goal.y,goal.z)
        if not Player:IsMoving() then Player:Move(FFXIV.MOVEMENT.FORWARD) end
    end
    if math.distance3d(Player.pos,M.progress.pos)>=1 then
        M.progress.pos=here(); M.progress.at=Now()
    elseif TimeSince(M.progress.at)>4000 then
        local size=M.mode=="straight" and M.detourSizes[M.detours+1]
        if size then
            M.detours=M.detours+1
            local a=math.atan2(pos.z-Player.pos.z,pos.x-Player.pos.x)+(M.detours%2==1 and 1 or -1)*math.pi/2
            M.detour={x=Player.pos.x+size*math.cos(a),y=Player.pos.y,z=Player.pos.z+size*math.sin(a)}
            M.progress.pos=here(); M.progress.at=Now()
            addon.Debug.log("Something is in the way: sidestepping")
            return false
        end
        M.stop(); return nil,string.format("Stuck %.1f y from the goal",d)
    end
    return false
end

-- The current walk hasn't covered a yalm in ms.
function M.stalled(ms) return M.progress~=nil and TimeSince(M.progress.at)>ms end

-- pos snapped onto the navmesh, or nil when the nearest mesh is over a yalm
-- away (inside a wall or a prop). Maps without a navmesh return pos as is:
-- there the walk is a straight line.
local function onMesh(pos)
    local p,snap=NavigationManager:GetClosestPointOnMesh(pos)
    if not table.valid(p) then return pos end
    local off=tonumber(p.distance) or tonumber(snap) or 0
    if off>1 then return nil end
    return {x=p.x,y=p.y,z=p.z}
end

-- A random walkable point within radius of pos (uniform over the disc), so
-- characters sent to the same place don't stand on one spot; pos itself when
-- none of a few tries is walkable.
function M.scatter(pos,radius)
    for _=1,6 do
        local a,r=math.random()*2*math.pi,radius*math.sqrt(math.random())
        local spot=onMesh({x=pos.x+r*math.cos(a),y=pos.y,z=pos.z+r*math.sin(a)})
        if spot then return spot end
    end
    return pos
end

-- A standing spot for the NPC at pos: a random distance and angle on the side
-- facing the player, so you don't walk around the NPC to reach it.
local function standSpot(pos)
    local facing=math.atan2(Player.pos.z-pos.z,Player.pos.x-pos.x)
    for _=1,6 do
        local a=facing+(math.random()*2-1)*M.standArc
        local r=M.standNear+math.random()*(M.standFar-M.standNear)
        local spot=onMesh({x=pos.x+r*math.cos(a),y=pos.y,z=pos.z+r*math.sin(a)})
        if spot then return spot end
    end
end

-- The NPC's entity, looked up at most every 500 ms (and again on a map
-- change): EntityList is the costliest native call here, and NPCs don't move.
local function lookup(contentId)
    local cached,map=M.lookup,Player.localmapid
    if not cached or cached.id~=contentId or cached.map~=map or TimeSince(cached.at)>=500 then
        cached={id=contentId,map=map,at=Now(),entity=M.find(contentId)}
        M.lookup=cached
    end
    return cached.entity
end

local function talk(npc,entity,map)
    M.stop()
    Player:SetTarget(entity.id)
    Player:Interact(entity.id)
    M.lastInteract={id=npc.id,map=map,at=Now()}
    M.stand=nil
    addon.Debug.log("Interacted with "..npc.name)
    return true
end

-- Walks to an NPC ({id, name, pos}) and interacts with it. Returns true once
-- the interaction was issued, false while approaching, or nil,error.
--
-- Each visit stands on its own random spot near the NPC (standSpot). The
-- interaction is only issued once the game flags the NPC as in reach
-- (entity.interactable); until then the walk steps in toward closeRange and
-- talks the moment it is. Asked again for the same NPC within 30 s (the last
-- interaction opened nothing), it walks right up to closeRange first. When
-- it can't get that close (a counter in the way), it tries from where it is.
-- A spot that can't be reached is replaced (three tries), then the walk heads
-- for the NPC itself. At its spawn point the NPC gets 3 s to stream in
-- before it counts as absent.
--
-- Already in reach, it talks from where it is: when a visit starts there
-- (the unlock quest ends beside the registrar), or once the walk has stalled
-- for a second (Keybound Square has no navmesh, so a counter or wall between
-- you and the spot only shows as not moving).
function M.interact(npc,straight)
    local entity=lookup(npc.id)
    local pos=entity and entity.pos or npc.pos
    local map=Player.localmapid
    local s=M.stand
    local fresh=false
    if not s or s.id~=npc.id or s.map~=map or TimeSince(s.at)>60000 then
        local last=M.lastInteract
        local retry=last and last.id==npc.id and last.map==map and TimeSince(last.at)<30000
        s={id=npc.id,map=map,at=Now(),fails=0,close=retry or nil,retry=retry or nil}
        M.stand=s
        fresh=not retry
    end
    if entity and (fresh or M.stalled(1000)) and math.distance2d(Player.pos,pos)<=M.pickWithin then
        local live=EntityList:Get(entity.id)
        if live and live.interactable then return talk(npc,entity,map) end
    end
    if not s.close and not s.spot and s.fails<3 and math.distance2d(Player.pos,pos)<=M.pickWithin then
        s.spot=standSpot(pos)
        if not s.spot then s.fails=3 end
    end
    local arrived,err
    if s.close then
        local live=entity and not s.retry and EntityList:Get(entity.id)
        if live and live.interactable then return talk(npc,entity,map) end
        arrived,err=M.goTo(pos,M.closeRange,straight)
        if arrived==nil and entity and math.distance2d(Player.pos,pos)<=M.interactRange then arrived=true end
    elseif s.spot then
        arrived,err=M.goTo(s.spot,0.5,straight)
        if arrived==nil then
            s.fails=s.fails+1; s.spot=nil
            return false
        end
    else
        arrived,err=M.goTo(pos,M.interactRange,straight)
    end
    if not arrived then M.missingSince=nil; return arrived,err end
    if not entity then
        M.missingSince=M.missingSince or Now()
        if TimeSince(M.missingSince)<3000 then return false end
        M.missingSince=nil
        return nil,npc.name.." is not here"
    end
    M.missingSince=nil
    if not s.close then
        local live=EntityList:Get(entity.id)
        if live and not live.interactable then
            s.close=true
            addon.Debug.log(npc.name.." is out of reach: stepping closer")
            return false
        end
    end
    return talk(npc,entity,map)
end
