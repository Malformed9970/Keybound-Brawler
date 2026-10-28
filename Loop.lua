KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Loop=addon.Loop or {}
local L=addon.Loop
local H={}

function L.reset()
    L.state="off"; L.status="Stopped"; L.games=0; L.since=0; L.step=nil; L.tries=0; L.map=nil; L.arrivedAt=0
    L.sinceBreak=0; L.nextBreak=nil; L.restUntil=0
end

-- Changes state; a new status is logged as the activity (always printed to
-- the console when show is set).
local function set(state,status,show)
    if state~=L.state then
        L.state=state; L.since=Now(); L.step=nil; L.tries=0; L.shown=nil
        L.dutyLimit=nil; L.dutyTimed=nil; L.unqueuedAt=nil; L.resultsAt=nil; L.leftAt=nil; L.leaves=nil
        if status then addon.Debug.log(status,show) end
    end
    L.status=status or state
end

-- Watchdog: a state that lasts this many minutes without moving on pauses,
-- so a hang nobody foresaw shows up as a pause with a reason. L.since is
-- when the state began, or its last progress (L.touch). The duty's limit
-- comes from the game's duty timer (H.duty); rest has its own timer.
L.limits={route=1,teleport=5,enter=5,quest=10,shop=5,register=5,queued=30,emotes=1}

function L.touch() L.since=Now() end

local function watchdogLimit()
    if L.state=="duty" then return L.dutyLimit end
    local minutes=L.limits[L.state]
    return minutes and minutes*60000
end

local function halt(state,reason)
    addon.Movement.stop(); addon.Shop.reset()
    set(state,state=="paused" and ("Paused: "..reason) or reason,true)
end
local function pause(reason) halt("paused",reason) end
local function stop(reason) halt("off",reason) end

-- Start counts games afresh against the window's "Games" limit (0 = no limit).
function L.start()
    addon.Shop.reset(); addon.Quest.reset()
    L.games=0; L.sinceBreak=0; L.nextBreak=nil; L.spaceCheckedAt=0
    L.event=nil; L.eventCheckedAt=0; L.requeues=0; L.questStep=nil; L.restShop=false; L.shopInRest=false
    L.run=(L.run or 0)+1
    set("route","Starting")
end
function L.stop() addon.Movement.stop(); addon.Shop.reset(); set("off","Stopped") end
function L.running() return L.state~="off" and L.state~="paused" end

-- Whether this character queues: solo, or the party's leader. A member
-- leaves that to the leader and accepts the duty when it pops. Minion's
-- party list marks the leader (isleader, as ffxivminion reads it); a
-- member in another zone may have no entity id, so the name counts too.
function L.queues()
    local party=EntityList.myparty
    if type(party)~="table" then return true end
    for _,member in pairs(party) do
        if member.isleader then return member.id==Player.id or member.name==Player.name end
    end
    return true
end

-- Rest after each game: a short random rest, and every breakEvery games
-- (give or take two) a longer random break. Both ranges come from settings.
local function restAfterGame()
    local s=addon.settings
    L.sinceBreak=L.sinceBreak+1
    L.nextBreak=L.nextBreak or s.breakEvery
    local seconds,kind
    if s.breakEvery>0 and L.sinceBreak>=L.nextBreak then
        seconds,kind=math.random(s.breakMin*60,s.breakMax*60),"Taking a break"
        L.sinceBreak=0
        L.nextBreak=math.random(math.max(1,s.breakEvery-2),s.breakEvery+2)
    else
        seconds,kind=math.random(s.restMin,s.restMax),"Resting"
    end
    L.restUntil=Now()+seconds*1000; L.restKind=kind; L.restShop=true
    set("rest",string.format("%s %d:%02d",kind,math.floor(seconds/60),seconds%60),true)
end

function L.skipRest() if L.state=="rest" then L.restUntil=Now() end end

-- KTGEnterDialogue's Register button, sent the way Minion's agent spy saw a
-- click send it (2026-10-28): agent 399 (unnamed in Minion, so by index;
-- a patch that adds agents could move it), command 0, one Int 0. The window
-- then closes by itself.
L.registerEvent={agent=399,cmd=0,args={{3,0}}}
function L.confirmRegister()
    if type(UIEvent)~="function" then return nil,"Minion's UIEvent isn't available" end
    local e=L.registerEvent
    UIEvent(e.agent,e.cmd,e.args)
    addon.Debug.log("Registered")
    return true
end

-- Keybound Brawler runs during an event (the quest's and shop's Festival).
-- Its NPCs (the entry NPCs with a warp into the square, the quest giver, the
-- square's registrar and trader) sit in map layers tied to that festival, so
-- they only exist while it runs; Minion and FFXIVLib expose no festival
-- state, so their presence is the check. Returns true or false, or nil when
-- this map cannot tell yet (no such NPC here, or not 3 s within 30 y of one).
function L.eventRunning()
    local d=addon.Lib.data
    local map=addon.currentMap()
    local nearest
    local function present(n)
        if n.map~=map then return false end
        if addon.Movement.find(n.id) then return true end
        local distance=math.distance2d(Player.pos,n.pos)
        if not nearest or distance<nearest then nearest=distance end
        return false
    end
    for _,n in ipairs(d.entries) do if present(n) then return true end end
    if present(d.npcs.registrar) or present(d.npcs.trader) then return true end
    if present({id=d.quest.start.npc,map=d.quest.start.map,pos=d.quest.start.pos}) then return true end
    if nearest and nearest<=30 and TimeSince(L.arrivedAt)>3000 then return false end
    return nil
end

local eventMessage="Keybound Brawler's event isn't running"

-- Uses the result L.tick keeps (checked at most once a second).
local function eventStopped()
    if L.event==false then
        stop(eventMessage)
        return true
    end
end

-- An NPC that should be here is missing: the event has ended unless the
-- presence check says otherwise.
local function fail(err)
    if L.eventRunning()==false then return stop(eventMessage) end
    pause(err)
end

local function nearestEntry()
    local map,best,bestDistance=addon.currentMap()
    for _,n in ipairs(addon.Lib.data.entries) do
        if n.map==map then
            local distance=math.distance2d(Player.pos,n.pos)
            if not bestDistance or distance<bestDistance then best,bestDistance=n,distance end
        end
    end
    return best
end

-- Heads for map: Keybound Square through the nearest entry NPC (teleporting
-- to the Gold Saucer first when none is on this map), the Gold Saucer by
-- teleport.
local function travel(map)
    local d=addon.Lib.data
    if map==d.squareMap and nearestEntry() then return set("enter","Walking to the nearest entry NPC") end
    if map==d.squareMap or map==d.hubMap then return set("teleport","Teleporting to the Gold Saucer") end
    pause("No route to map "..tostring(map))
end

function H.route()
    local d=addon.Lib.data
    local map=addon.currentMap()
    if map==d.dutyMap then return set("duty","In Keybound Brawler") end
    -- First thing after Start: a quick look at the Emote window, while one
    -- of the shop's emotes isn't known to be learned.
    if addon.Emotes.needsCheck(L.run) then
        addon.Emotes.checkedRun=L.run
        return set("emotes","Checking your emotes")
    end
    if eventStopped() then return end
    local Q=addon.Quest
    if not Q.completed() then
        local blocker=Q.blocker()
        if blocker then return pause(blocker) end
        local place=Q.target()
        if not place then return pause("Unknown step "..tostring(Q.step()).." of \""..d.quest.name.."\"") end
        if place.map==map then return set("quest","Unlock quest \""..d.quest.name.."\", step "..tostring(Q.step())) end
        return travel(place.map)
    end
    if addon.settings.maxGames>0 and L.games>=addon.settings.maxGames then return stop("Finished "..L.games.." games") end
    -- At the cap, games earn nothing: stop once nothing is left to buy.
    local mgc=addon.mgc()
    if mgc and mgc>=d.cap and #addon.Shop.plan(mgc,addon.settings)==0 then
        return stop("MGC is at the "..d.cap.." cap with nothing left to buy")
    end
    if map==d.squareMap then
        if addon.Shop.due() then L.fullNoted=nil; return set("shop","Spending MGC") end
        -- A full inventory skips the trader and the games go on, until MGC
        -- reaches the cap and more games would only waste it.
        if addon.Shop.blockedBySpace() then
            if addon.mgc()>=d.cap then return stop("Inventory full and MGC at the "..d.cap.." cap") end
            if not L.fullNoted then addon.Debug.log("Inventory full: not buying anything",true); L.fullNoted=true end
        else
            L.fullNoted=nil
        end
        if not L.queues() then return set("member","Waiting for the party leader to queue") end
        return set("register","Walking to the registrar")
    end
    travel(d.squareMap)
end

-- Opens the Emote window with /emotelist (unless you have it open), reads
-- which of the shop's emotes you've learned (addon.Emotes), and closes it
-- again. Gives up after 5 s; purchases made by this addon still count.
function H.emotes()
    if not L.step then
        L.emoteWindowWasOpen=IsControlOpen("Emote")
        if not L.emoteWindowWasOpen then SendTextCommand("/emotelist") end
        L.step=Now()
        return
    end
    local read=addon.Emotes.read()
    if not read and TimeSince(L.step)<=5000 then return end
    if not read then addon.Debug.log("Couldn't read the Emote window") end
    if not L.emoteWindowWasOpen and IsControlOpen("Emote") then GetControl("Emote"):Close() end
    set("route")
end

function H.teleport()
    local d=addon.Lib.data
    if addon.currentMap()==d.hubMap then return set("route") end
    if not L.step then
        if Player.incombat then L.status="Waiting to leave combat"; return end
        Player:Teleport(d.aetheryte); L.step=Now()
    elseif TimeSince(L.step)>30000 then
        pause("Teleport to the Gold Saucer did not finish")
    end
end

-- Talks to the nearest entry NPC and accepts its warp into the square.
function H.enter()
    if addon.currentMap()==addon.Lib.data.squareMap then return set("route") end
    if eventStopped() then return end
    if L.step then
        local acted,err=addon.Dialogs.handle(nil)
        if acted==nil then return pause(err.." at the entry NPC") end
        if TimeSince(L.step)>15000 then
            L.tries=L.tries+1; L.step=nil
            if L.tries>=2 then pause("The warp into Keybound Square did not happen") end
        end
        return
    end
    local entry=nearestEntry()
    if not entry then return set("route") end
    local done,err=addon.Movement.interact(entry,false)
    if done==nil then return fail(err) end
    if done then L.step=Now(); L.status="Waiting for the warp prompt" end
end

function H.quest()
    local place=addon.Quest.target()
    if not place or place.map~=addon.currentMap() then return set("route") end
    if eventStopped() then return end
    -- Each quest step reached restarts the watchdog.
    local step=addon.Quest.step()
    if step~=L.questStep then L.questStep=step; L.touch() end
    local done,err=addon.Quest.tick(place)
    if done==nil then return fail(err) end
    if done then
        addon.Debug.log("Quest \""..addon.Lib.data.quest.name.."\" complete",true)
        set("route")
    end
end

function H.shop()
    local done,err=addon.Shop.tick()
    if done==nil then return fail(err) end
    if not done then return end
    -- Shopping during a rest: back to it while time is left.
    if L.shopInRest then
        L.shopInRest=false
        if Now()<L.restUntil then return set("rest",L.restKind) end
    end
    set("register","Walking to the registrar")
end

function H.register()
    local d=addon.Lib.data
    if addon.currentMap()==d.dutyMap then return set("duty") end
    if eventStopped() then return end
    if not L.queues() then return set("member","Waiting for the party leader to queue") end
    -- Already open (opened by hand, or still up from before Start): register.
    if IsControlOpen("KTGEnterDialogue") then
        local ok,err=L.confirmRegister()
        if not ok then return pause(err) end
        return set("queued","Waiting for the duty")
    end
    if not L.step then
        local done,err=addon.Movement.interact(d.npcs.registrar,true)
        if done==nil then return fail(err) end
        if done then L.step=Now(); L.status="Waiting for the registration window" end
        return
    end
    local acted,err=addon.Dialogs.handle(nil)
    if acted==nil then return pause(err.." at the registrar") end
    -- Nothing opened: talk again once (Movement steps in close for a repeat).
    if TimeSince(L.step)>8000 then
        L.tries=L.tries+1; L.step=nil
        if L.tries>=2 then pause("The registration window did not open") end
    end
end

-- A party member: the leader registers the party; this waits and accepts
-- the duty when it pops. Back to registering itself if it becomes the
-- leader or leaves the party.
function H.member()
    if addon.currentMap()==addon.Lib.data.dutyMap then return set("duty","In Keybound Brawler") end
    if eventStopped() then return end
    if L.queues() then return set("route") end
    if IsControlOpen("ContentsFinderConfirm") then
        UseControlAction("ContentsFinderConfirm","Confirm")
        L.status="Accepting the duty"
    end
end

-- Duty:GetQueueStatus(): 0 not queued, 1 queued, 2 confirming, 3 readying,
-- 4 in the duty (ffxivminion's NotQueued/InQueue).
function H.queued()
    if addon.currentMap()==addon.Lib.data.dutyMap then return set("duty","In Keybound Brawler") end
    if IsControlOpen("ContentsFinderConfirm") then UseControlAction("ContentsFinderConfirm","Confirm") end
    -- Registered but not in the queue for 10 s (registration didn't take, or
    -- the queue was dropped): register again, twice at most.
    if Duty:GetQueueStatus()==0 then
        L.unqueuedAt=L.unqueuedAt or Now()
        if TimeSince(L.unqueuedAt)>10000 then
            L.requeues=(L.requeues or 0)+1
            if L.requeues>2 then return pause("Not in the queue after registering 3 times") end
            return set("register","Not in the queue: registering again",true)
        end
    else
        L.unqueuedAt=nil
    end
end

-- The results window (KTGResult): MGC is credited before it shows, and
-- closing it leaves the duty at once (both hand-played games, 2026-10-28),
-- so it's closed after resultsWait rather than sitting out its 60 s
-- countdown, with Esc as you would (PressKey: a game keybind). Minion's
-- Close only hides it and the duty goes on (2026-10-28: stuck until Esc by
-- hand). If it's still open leaveRetry later, the events a click sent
-- (agent spy): agent 401 by index (unnamed in Minion), {3:-1} then {3:-2},
-- with the cmd the spy reported; then Esc again every leaveRetry. Esc is
-- pressed only while the window is open: with nothing open it brings up the
-- system menu. Still in the duty stuckAfter the results showed, it pauses.
L.resultsWait,L.leaveRetry,L.stuckAfter=3000,3000,90000
L.leaveEvent={agent=401,cmd=4945409,args={{{3,-1}},{{3,-2}}}}

local function leaveResults()
    if not L.resultsAt then L.resultsAt=Now() end
    if TimeSince(L.resultsAt)<L.resultsWait then return end
    if L.leftAt and TimeSince(L.leftAt)<L.leaveRetry then return end
    L.leftAt=Now(); L.leaves=(L.leaves or 0)+1
    if L.leaves==2 and type(UIEvent)=="function" then
        addon.Debug.log("Esc didn't close the results: sending their Leave event")
        local e=L.leaveEvent
        for _,args in ipairs(e.args) do UIEvent(e.agent,e.cmd,args) end
        return
    end
    addon.Debug.log("Leaving from the results (Esc)")
    PressKey(27)
end

-- The typer plays; the loop waits for the duty to end and leaves from the
-- results. The watchdog allows the game's duty timer plus 2 minutes, or 25
-- minutes when the timer can't be read.
function H.duty()
    if not L.dutyTimed then
        local remaining=tonumber(Duty:GetDutyTimeRemaining()) or 0
        if remaining>0 then L.dutyLimit=TimeSince(L.since)+(remaining+120)*1000; L.dutyTimed=true
        else L.dutyLimit=25*60000 end
    end
    if addon.currentMap()~=addon.Lib.data.dutyMap then
        L.games=L.games+1; L.requeues=0
        addon.Debug.log("Game "..L.games.." finished, MGC "..tostring(addon.mgc()),true)
        local limit=addon.settings.maxGames
        if limit>0 and L.games>=limit then return stop("Finished "..L.games.." games") end
        -- A party member doesn't rest: the leader sets the pace, and a duty
        -- that popped during a rest would go unanswered.
        if not L.queues() then return set("route") end
        return restAfterGame()
    end
    local results=IsControlOpen("KTGResult")
    if results then leaveResults()
    elseif L.resultsAt and TimeSince(L.resultsAt)>L.stuckAfter then
        return pause("Still in the duty after the results: leave it by hand")
    end
    -- The status string is rebuilt only when what it shows changes.
    local shown=results and "Results" or addon.Typer.status
    if shown~=L.shown then
        L.shown=shown
        L.status=shown=="Results" and shown or ("Playing: "..shown)
    end
end

-- The rest between games is when the trader is visited: first thing, when
-- shopping is due, and the rest goes on afterwards while time is left (it
-- counts down meanwhile, so shopping uses the rest rather than adding to it).
function H.rest()
    if L.restShop then
        L.restShop=false
        if addon.currentMap()==addon.Lib.data.squareMap and addon.Shop.due() then
            L.shopInRest=true
            return set("shop","Spending MGC")
        end
    end
    local left=math.ceil((L.restUntil-Now())/1000)
    if left<=0 then return set("route") end
    if left~=L.shown then
        L.shown=left
        L.status=string.format("%s %d:%02d",L.restKind,math.floor(left/60),left%60)
    end
end

-- The window's Games value: played/limit, with the window's no-limit sign
-- (the infinity sign when Minion's font has it) when there is no limit.
local function describe()
    local limit,noLimit=addon.settings.maxGames,addon.UI.infinity or "\226\136\158"
    if L.games~=L.gamesShown or limit~=L.limitShown or noLimit~=L.noLimitShown then
        L.gamesShown,L.limitShown,L.noLimitShown=L.games,limit,noLimit
        L.gamesValue=L.games.."/"..(limit>0 and limit or noLimit)
    end
    -- Marks the Status line while purchases are skipped for lack of space.
    -- Minion has no inventory-change event, so this polls, but only every
    -- 2 s while the loop runs (and blockedBySpace reads no bags below the
    -- spending threshold).
    if not L.running() then
        L.inventoryFull=false
    elseif TimeSince(L.spaceCheckedAt or 0)>=2000 then
        L.spaceCheckedAt=Now()
        L.inventoryFull=addon.Shop.blockedBySpace()
    end
end

function L.tick()
    if not L.state then L.reset() end
    local map=addon.currentMap()
    if map~=L.map then L.map=map; L.arrivedAt=Now(); L.event=nil; L.eventCheckedAt=0 end
    -- The event NPCs are looked for only while the loop runs, at most once a
    -- second, and not again on this map once found (a missing NPC at
    -- interaction re-checks via fail).
    if L.running() and L.event~=true and TimeSince(L.eventCheckedAt or 0)>=1000 then
        L.eventCheckedAt=Now()
        local running=L.eventRunning()
        if running~=nil then L.event=running end
    end
    if L.running() then
        H[L.state]()
        local limit=L.running() and watchdogLimit()
        if limit and TimeSince(L.since)>limit then
            pause(string.format("No progress for %d min (%s)",math.floor(limit/60000+0.5),L.status))
        end
    end
    describe()
end
