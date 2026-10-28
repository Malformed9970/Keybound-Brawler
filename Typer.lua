KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Typer=addon.Typer or {}
local T=addon.Typer

-- Types in the duty: a casting enemy's word first, then the word on the
-- enemy nearest you (a bigger enemy when two are as near), only for an
-- enemy that is alive and targetable. Only while the loop runs (Stop halts
-- it at once) and the duty's text box takes input (KTGInput r3 is false
-- during Letterlock). An enemy finishing a Letterlock cast (Cursed Gaze,
-- Sensory Jammer) makes the game punish typing: words are held from guardMs
-- before such a cast ends until guardMs after.
-- Between words it waits the Word delay setting, give or take jitter at
-- random, and one delay after Letterlock or when the text box opens. A word
-- isn't sent twice within recentFor ms.
-- (Until v0.9.0 an outside OCR helper did this: see dev\archive\0.9.0-ocr.)

T.checkEvery,T.jitter,T.recentFor,T.guardMs=100,0.2,3000,500
T.letterlockCasts={[49529]=true,[49532]=true,[49702]=true}

function T.reset()
    T.nextAt=nil; T.checkAt=0; T.holdUntil=nil; T.hits=0; T.misses=0; T.lastError=nil
    T.recent=T.recent or {}
    for text in pairs(T.recent) do T.recent[text]=nil end
    T.status="Idle"
end

-- The time to the next word: the Word delay, give or take jitter.
function T.delay()
    local base=addon.settings.wordDelayMs
    return base+(math.random()*2-1)*T.jitter*base
end

-- The duty's text box: its control when open (nil otherwise), and whether
-- it takes input.
local function inputState()
    if addon.currentMap()~=addon.Lib.data.dutyMap or not IsControlOpen("KTGInput") then return nil,false end
    local control=GetControl("KTGInput")
    local raw=control and control:GetRawData()
    local enabled=raw and raw[3] and raw[3].value
    return control,enabled==true or enabled=="true"
end

local function canSubmit(control)
    for _,action in pairs(control:GetActions() or {}) do
        if action=="SubmitWord" then return true end
    end
    return false
end

-- Whether an entity is casting, by Minion's castinginfo.
local function casting(e)
    local cast=e.castinginfo
    return type(cast)=="table" and (tonumber(cast.channelingid) or 0)~=0
end

-- The word to type next, or nil.
function T.pick(words,now)
    local best,bestCasting,bestDistance,bestHp
    local me=Player.pos
    for _,w in pairs(words or {}) do
        local text=(w.text~=nil and w.text~="") and w.text or w.reading
        local recent=text and T.recent[text]
        if text and text~="" and not (recent and now<recent) then
            local e=EntityList:Get(w.id)
            local hp=e and e.hp
            if e and e.targetable and type(hp)=="table" and (hp.current or 0)>0 then
                local isCasting=casting(e)
                local distance=math.distance2d(me,e.pos)
                local max=hp.max or 0
                local better
                if not best then better=true
                elseif isCasting~=bestCasting then better=isCasting
                elseif distance~=bestDistance then better=distance<bestDistance
                else better=max>bestHp end
                if better then best,bestCasting,bestDistance,bestHp=text,isCasting,distance,max end
            end
        end
    end
    return best
end

-- Time left on the soonest Letterlock cast nearby (ms), or nil.
local function letterlockCastLeft()
    local soonest
    for _,e in pairs(EntityList("alive,maxdistance=100") or {}) do
        local cast=e.castinginfo
        if type(cast)=="table" and T.letterlockCasts[tonumber(cast.channelingid) or 0] then
            local left=((tonumber(cast.casttime) or 0)-(tonumber(cast.channeltime) or 0))*1000
            if not soonest or left<soonest then soonest=left end
        end
    end
    return soonest
end

-- Runs every update while FFXIVLib's data is loaded.
function T.tick()
    local now=Now()
    if now<T.checkAt then return end
    T.checkAt=now+T.checkEvery
    local control,enabled
    if addon.Loop.running() then control,enabled=inputState() end
    if not control then T.nextAt=nil; T.status="Idle"; return end
    if not enabled then T.nextAt=nil; T.status="Letterlock: holding"; return end
    if not canSubmit(control) then T.status="This Minion build can't submit words (update Minion)"; return end
    if not T.nextAt then T.nextAt=now+T.delay() end
    if now<T.nextAt then return end
    if T.holdUntil and now<T.holdUntil then T.status="Holding for a Letterlock cast"; return end
    local left=letterlockCastLeft()
    if left and left<=T.guardMs then
        T.holdUntil=now+math.max(0,left)+T.guardMs
        T.status="Holding for a Letterlock cast"
        return
    end
    local text=T.pick(control:GetData(),now)
    if not text then T.status="No word to type"; return end
    T.nextAt=now+T.delay()
    T.recent[text]=now+T.recentFor
    local ok,hit=pcall(control.Action,control,"SubmitWord",text)
    if not ok then
        T.lastError=tostring(hit)
        T.status="Submitting failed: "..T.lastError
    elseif hit then
        T.hits=T.hits+1; T.lastError=nil
        T.status="Typed "..text
    else
        T.misses=T.misses+1
        T.status="Missed "..text
        addon.Debug.log("Missed: "..text)
    end
end
