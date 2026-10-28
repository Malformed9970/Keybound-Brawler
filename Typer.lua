KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Typer=addon.Typer or {}
local T=addon.Typer

-- The enemies' words come from the OCR helper (helper\KeyboundOcr.ps1), a
-- separate program that reads this game's window: Minion can't see them
-- (KTGEWord holds no text, captures of 2026-10-28). Start launches it
-- (Windows PowerShell, part of Windows: nothing to install) and Stop ends
-- it. Started from inside the game, it has the game's rights: the game often
-- runs as administrator, and Windows drops key presses sent to it by a
-- program that isn't (2026-10-28: every outside test until then was refused
-- this way). The two talk through small files in this addon's ocr folder:
--   <pid>.state    written here while the loop runs (at least once a second;
--                  the helper quits after 10 s without a write, or on
--                  run=0): whether the duty's text box is open and takes
--                  input (Letterlock turns that off), the part of the window
--                  around the enemies (area) and this addon's window (skip)
--   <pid>.words    written by the helper: "seq N", then one line per
--                  stretch of text it read in that area, normalized: text,
--                  x, y (window pixels), its label's kind (0 usual, 1 gold,
--                  2 green) and r,g,b
--   <pid>.helper   written by the helper every second: alive, and a status
-- The helper reads only around the enemies: chat, the hotbars and this
-- window's shop list hold known words too ("avalanche", "jump": a
-- full-window read, 2026-10-28). Only text that is a known word counts:
-- this addon matches it against FFXIVLib's word list (T.dictionary).
-- Each enemy's position is put on screen with WorldToScreen, which matches
-- the helper's window pixels (checked against nameplates 2026-10-28); only
-- words sitting by an enemy count. Words on a green label go first, then
-- gold ones, then the word on the enemy nearest you.
--
-- The helper also types: Enter, the word key by key, Enter, each key
-- posted to the game window as key-down and key-up messages (no focus
-- needed). The duty
-- ignores a paste and got only each word's first letter from Minion's
-- PressKey; real input plus posted characters typed, but the game expelled
-- the player for inactivity (2026-10-28). Two more files:
--   <pid>.type     written here: "seq N", then the word and the keys per
--                  second, then "end"; a request with no word cancels
--   <pid>.typed    written by the helper: "seq N done" or "seq N stopped"
-- Nothing is typed during Letterlock (the helper checks the state file
-- before every key, and the request is cancelled), or once Stop is pressed.

-- Virtual-key codes for every character a normalized word can contain (the
-- in-game typing test presses them; the helper has its own table). The game
-- ignores case and treats ? ! - ' as optional, while spaces, periods
-- and commas are required (Keybound Brawler guide, DescriptionString 1683).
local keys={[" "]=0x20,["."]=0xBE,[","]=0xBC}
for i=0,25 do keys[string.char(97+i)]=0x41+i end
for i=0,9 do keys[tostring(i)]=0x30+i end
T.keys=keys
T.enterKey=0x0D

-- Lowercases text and drops the optional punctuation (including the curly
-- apostrophe). Returns nil when anything left cannot be typed with T.keys.
function T.normalize(text)
    local s=tostring(text):lower():gsub("\226\128\153",""):gsub("[%?!%-']","")
    if s=="" or s:find("[^a-z0-9 .,]") then return nil end
    return s
end

-- Appends the keys for a normalized word plus Enter to out.
function T.keysFor(word,out)
    for i=1,#word do out[#out+1]=keys[word:sub(i,i)] end
    out[#out+1]=T.enterKey
    return out
end

-- Normalized forms of every word in KTGTypeWordTextData (client language),
-- built once FFXIVLib has loaded the sheet.
function T.knownWords()
    if not T.known then
        T.known={}
        for _,text in pairs(addon.Lib.data.words) do
            local word=T.normalize(text)
            if word then T.known[word]=true end
        end
    end
    return T.known
end

-- Matching what the helper read to the word list. OCR misreads letters
-- ("c1oud") and reads more than labels, so a stretch of text counts only
-- when it is a known word as a whole: equal; or, from 5 characters, one
-- character wrong, missing or extra with no other word as close; or, from
-- 12, two apart with no other word as close. A one-delete index finds the
-- one-apart words: each word and every way of deleting one of its
-- characters points to it (false when two words share a key). It's built
-- buildBudget words per call, so a load doesn't stall a frame; until it's
-- done only equal text matches. Results are cached (OCR reads the same text
-- frame after frame), cleared at cacheSize entries.
local Dictionary={}
Dictionary.__index=Dictionary
T.buildBudget,T.cacheSize=200,4000

-- A dictionary of words (a set, as T.knownWords gives).
function T.dictionary(words)
    local list={}
    for word in pairs(words) do list[#list+1]=word end
    return setmetatable({words=words,list=list,next=1,index={},byLength={},cache={},cached=0},Dictionary)
end

local function point(index,key,word)
    local old=index[key]
    if old==nil then index[key]=word elseif old~=word then index[key]=false end
end

-- Indexes up to budget more words; true once all are in.
function Dictionary:build(budget)
    local list,index,byLength=self.list,self.index,self.byLength
    local last=math.min(#list,self.next+budget-1)
    for i=self.next,last do
        local word=list[i]
        point(index,word,word)
        for k=1,#word do point(index,word:sub(1,k-1)..word:sub(k+1),word) end
        local same=byLength[#word]
        if not same then same={}; byLength[#word]=same end
        same[#same+1]=word
    end
    self.next=last+1
    self.built=self.next>#list
    return self.built
end

-- Levenshtein distance between a and b, or limit+1 once it's over limit.
local previousRow,currentRow={},{}
local function distance(a,b,limit)
    local la,lb=#a,#b
    if math.abs(la-lb)>limit then return limit+1 end
    local prev,cur=previousRow,currentRow
    for j=0,lb do prev[j]=j end
    for i=1,la do
        cur[0]=i
        local smallest,ca=i,a:byte(i)
        for j=1,lb do
            local cost=ca==b:byte(j) and 0 or 1
            local v=math.min(prev[j]+1,cur[j-1]+1,prev[j-1]+cost)
            cur[j]=v
            if v<smallest then smallest=v end
        end
        if smallest>limit then return limit+1 end
        prev,cur=cur,prev
    end
    return prev[lb]
end

local function lookup(self,text)
    if self.words[text] then return text end
    local n=#text
    if n<5 or not self.built then return nil end
    local index,found=self.index,nil
    -- The candidate under key: nil (none), a word, or false (several).
    local function take(key)
        local w=index[key]
        if w==nil then return true end
        if w==false or (found and found~=w) then return false end
        found=w
        return true
    end
    if not take(text) then return nil end
    for k=1,n do
        if not take(text:sub(1,k-1)..text:sub(k+1)) then return nil end
    end
    if found or n<12 then return found end
    local best,bestDistance,tied=nil,3,false
    for length=n-2,n+2 do
        for _,word in ipairs(self.byLength[length] or {}) do
            local d=distance(text,word,2)
            if d<bestDistance then best,bestDistance,tied=word,d,false
            elseif d==bestDistance then tied=true end
        end
    end
    if tied then return nil end
    return best
end

-- The known word text is, or nil.
function Dictionary:match(text)
    local hit=self.cache[text]
    if hit==nil then
        hit=lookup(self,text) or false
        -- Cached only once the index is complete (before, a miss may not stay one).
        if self.built then
            if self.cached>=T.cacheSize then self.cache={}; self.cached=0 end
            self.cache[text]=hit; self.cached=self.cached+1
        end
    end
    return hit or nil
end

-- Timing (ms): input checked and the helper's file read every readEvery,
-- the state file written every stateEvery in the duty and every leaseEvery
-- otherwise while the loop runs, the helper counted as stopped when its
-- words file hasn't changed for staleAfter, a submitted word skipped for
-- recentFor (its enemy takes a moment to go).
T.readEvery,T.stateEvery,T.leaseEvery,T.staleAfter,T.recentFor=100,250,1000,1500,2000
-- The helper is started when its heartbeat is older than helperFresh
-- seconds, again after launchFirst ms if it still isn't running, then twice
-- as long each time up to launchMax.
T.helperFresh,T.launchFirst,T.launchMax=5,15000,120000
-- Where a word may sit relative to its enemy's feet on screen (pixels; up is
-- negative), which is also the area the helper reads. Regular labels were
-- read 80 to 155 px above the feet (at, about 120) and within 135 px to the
-- side (2026-10-28); long phrases are wider. A big enemy's (the airbuster)
-- sat about 355 px above at 51 y and climbed out of a 500 px box as it came
-- closer (a 26 y boss read none of its phrases for 9 s at a time,
-- 2026-10-28): its box reaches the top of the screen, and anything from
-- from up counts as where its labels are.
T.label={side=300,up=-500,down=100,at=-120,
    big={side=400,up=-1500,down=100,from=-150}}
-- Enemies have 44 to 8,400 HP; the scenery beside the players has 188,300
-- (2026-10-28 captures). Big ones have bigHp or more: the airbuster, wave
-- 3's goal (6,600 to 8,400), and one in wave 2 (4,800 to 5,300); the others
-- have 44 to 800. Their labels sit higher (see label).
T.enemyMaxHp,T.bigHp=100000,1000

function T.reset()
    T.abort()
    -- Request numbers keep rising across reloads, so the helper never takes
    -- a new request for one it already answered.
    T.typeSeq=os.time()*100
    T.words=T.words or {}; T.count=0
    T.enemies=T.enemies or {}; T.enemyCount=0
    T.area=T.area or {}; T.area.set=false
    T.shown=T.shown or {}
    for word in pairs(T.shown) do T.shown[word]=nil end
    T.recent=T.recent or {}
    for word in pairs(T.recent) do T.recent[word]=nil end
    T.known=nil; T.paths=nil; T.dict=nil
    T.seq=nil; T.seqAt=0; T.checkAt=0; T.stateAt=0; T.nextPick=0; T.reads=0
    T.open=false; T.enabled=false
    -- run is nil until the first update writes the state file, so a helper
    -- left from before a reload hears run=0 at once.
    T.run=nil; T.active=false; T.input=false; T.leaseAt=0
    T.helperCheckAt=0; T.launchAt=0; T.launchDelay=T.launchFirst
    T.helperAlive=false; T.helperStatus=nil; T.launchError=nil; T.launches=0
    T.submitted=0
    T.status="Idle"
end

local writeType

-- Drops the word under way, telling the helper to stop typing it (it erases
-- what it typed before its next word).
function T.abort()
    if T.step and T.paths then writeType(nil) end
    T.word=nil; T.step=nil
end

-- File paths for this game process, all in this addon's folder.
local function paths()
    if not T.paths then
        local root=addon.paths.root
        local folder=root.."ocr\\"
        if not FolderExists(folder) then FolderCreate(folder) end
        local pid=tostring(GetCurrentPID())
        T.pid=pid
        T.paths={root=root,folder=folder,state=folder..pid..".state",words=folder..pid..".words",
            type=folder..pid..".type",typed=folder..pid..".typed",helper=folder..pid..".helper",
            script=root.."helper\\KeyboundOcr.ps1"}
    end
    return T.paths
end

-- Opens one of the ocr folder's files for writing, putting the folder back
-- first when it's gone: it's made at runtime, so it may be deleted while
-- the addon runs (2026-10-28: nothing was typed until it came back).
local function create(path)
    local file=io.open(path,"w")
    if file then return file end
    FolderCreate(paths().folder)
    return io.open(path,"w")
end

local function box(file,key,b)
    file:write(string.format("%s=%d,%d,%d,%d\n",key,math.floor(b[1]),math.floor(b[2]),math.floor(b[3]),math.floor(b[4])))
end

-- The state file the helper follows; "end" marks it whole.
local function writeState()
    local file=create(paths().state)
    if not file then return end
    file:write("run=",T.run and 1 or 0,"\nactive=",T.active and 1 or 0,"\ninput=",T.input and 1 or 0,"\n")
    if T.active and T.area.set then
        box(file,"area",T.area)
        local window=addon.UI.rect
        if window and window.set then box(file,"skip",window) end
    end
    file:write("time=",os.time(),"\nend\n")
    file:close()
    T.stateAt=Now()
end

-- A new typing request for word, or a cancel (no word).
writeType=function(word)
    T.typeSeq=T.typeSeq+1
    local file=create(paths().type)
    if not file then return false end
    file:write("seq ",T.typeSeq,"\n")
    if word then file:write(word,"\n",addon.settings.charsPerSecond,"\n") end
    file:write("end\n")
    file:close()
    return true
end

-- The helper's answer to the latest request, or nil while it's typing.
local function readTyped()
    local file=io.open(paths().typed,"r")
    if not file then return end
    local text=file:read("*a")
    file:close()
    local seq,result=text:match("^seq (%d+) (%a+)")
    if tonumber(seq)==T.typeSeq then return result end
end

-- Whether the helper is running (its heartbeat is recent), and its status.
local function readHelper()
    local file=io.open(paths().helper,"r")
    if not file then return false end
    local text=file:read("*a")
    file:close()
    local alive=tonumber(text:match("^alive (%d+)"))
    local err=text:match("\nerror ([^\n]*)")
    local status=err and ("error: "..err) or text:match("\nstatus ([^\n]*)")
    return alive~=nil and math.abs(os.time()-alive)<=T.helperFresh,status
end

-- Starts the helper, hidden, the way Centurio starts its feed worker:
-- Windows PowerShell 5.1 runs helper\KeyboundOcr.ps1 from this addon's
-- folder for this game. It inherits the game's rights (see the top).
local function launch()
    local p=paths()
    T.launchError=nil
    if type(io.popen)~="function" then T.launchError="Minion's io.popen is unavailable"; return end
    local script=io.open(p.script,"r")
    if not script then T.launchError="helper\\KeyboundOcr.ps1 is missing from the addon folder"; return end
    script:close()
    local folder=p.folder:gsub("\\$","")
    if (p.script..folder):find('"',1,true) then T.launchError="the addon's folder has a quote in its path"; return end
    local command='start "" /b "%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -NonInteractive'
        ..' -WindowStyle Hidden -ExecutionPolicy Bypass -File "'..p.script..'" -GamePid '..T.pid..' -Folder "'..folder..'" >NUL 2>&1'
    local ok,process=pcall(io.popen,command,"r")
    if not ok or not process then T.launchError="PowerShell didn't start: "..tostring(process); return end
    process:close()
    T.launches=T.launches+1
    addon.Debug.log("Started the OCR helper")
end

-- Runs on every update, loading screens included: says run=0 at once on
-- Stop, keeps the state file fresh while the loop runs (the helper quits
-- after 10 s without a write), and starts the helper whenever it isn't
-- running.
function T.lease()
    local run=addon.Loop.running()
    if run~=T.run then
        T.run=run
        if run then T.launchAt=0; T.launchDelay=T.launchFirst; T.helperCheckAt=0
        else T.active=false; T.input=false end
        writeState()
    end
    local now=Now()
    if not run or now<T.leaseAt then return end
    T.leaseAt=now+T.readEvery
    -- No text box behind a loading screen.
    if T.active and addon.loading() then T.active=false; T.input=false; writeState() end
    if now-T.stateAt>=T.leaseEvery then writeState() end
    if now>=T.helperCheckAt then
        T.helperCheckAt=now+1000
        T.helperAlive,T.helperStatus=readHelper()
        if T.helperAlive then
            T.launchDelay=T.launchFirst
        elseif now>=T.launchAt then
            launch()
            T.launchAt=now+T.launchDelay; T.launchDelay=math.min(T.launchDelay*2,T.launchMax)
        end
    end
end

-- The helper's state for the window: off, starting, its own status (waiting
-- for the duty, reading), or why it can't run.
function T.helperText()
    if not T.run then return "Off" end
    if T.launchError then return "Can't start: "..T.launchError end
    if T.helperAlive then return T.helperStatus or "Running" end
    if T.helperStatus and T.helperStatus:find("^error") then return T.helperStatus end
    return "Starting"
end

-- The duty's text box: open, and whether it takes input (r3; false while
-- Letterlock counts down, 2026-10-28 captures).
local function inputState()
    if addon.currentMap()~=addon.Lib.data.dutyMap or not IsControlOpen("KTGInput") then return false,false end
    local raw=GetControl("KTGInput"):GetRawData()
    local enabled=raw and raw[3] and raw[3].value
    return true,enabled==true or enabled=="true"
end

-- Every enemy on screen (T.enemies, entries reused): its id, its feet on
-- screen, and how far it is from you. T.area becomes their label boxes
-- merged: the part of the window the helper reads.
local function readEnemies()
    local n,me,label,area=0,Player.pos,T.label,T.area
    area.set=false
    for _,e in pairs(EntityList("alive,maxdistance=100") or {}) do
        local hp=e.hp
        if e.type==2 and type(hp)=="table" and (hp.max or 0)<T.enemyMaxHp then
            local s=RenderManager:WorldToScreen(e.pos)
            if s then
                n=n+1
                local a=T.enemies[n] or {}
                T.enemies[n]=a
                a.id=e.id; a.x=s.x; a.y=s.y; a.dist=math.distance2d(me,e.pos); a.big=hp.max>=T.bigHp
                local b=a.big and label.big or label
                local x0,y0,x1,y1=s.x-b.side,s.y+b.up,s.x+b.side,s.y+b.down
                if area.set then
                    area[1]=math.min(area[1],x0); area[2]=math.min(area[2],y0)
                    area[3]=math.max(area[3],x1); area[4]=math.max(area[4],y1)
                else
                    area[1],area[2],area[3],area[4],area.set=x0,y0,x1,y1,true
                end
            end
        end
    end
    T.enemyCount=n
end

-- The enemy a word at x,y belongs to, or nil: of the enemies whose box it
-- sits in, the one whose labels sit closest to it (a regular enemy's about
-- label.at above its feet, a big one's anywhere from big.from up, so an add
-- below the boss doesn't take the boss's phrases). Also returns the closest
-- enemy at all (for the capture).
local function owner(x,y)
    local best,bestScore,near,nearScore
    for i=1,T.enemyCount do
        local a=T.enemies[i]
        local b=a.big and T.label.big or T.label
        local dx,dy=x-a.x,y-a.y
        local score=math.abs(dx)+(a.big and math.max(0,dy-b.from) or math.abs(dy-b.at))
        if not nearScore or score<nearScore then near,nearScore=a,score end
        if math.abs(dx)<=b.side and dy>=b.up and dy<=b.down and (not bestScore or score<bestScore) then
            best,bestScore=a,score
        end
    end
    return best,near
end

-- Notes a word's first sighting in the capture: where it was relative to
-- its enemy, or to the closest enemy when it was left out, and its label's
-- colour and kind (to tune the helper's colour test).
local kinds={[1]=" gold",[2]=" green"}
local function noteSighting(word,x,y,kind,colour,best,near)
    -- Only with the development capture (dev\Capture.lua) loaded and recording.
    if not (addon.Capture and addon.Capture.path) then return end
    local a=best or near
    addon.Capture.add(string.format("ocr %s: %s at %d,%d colour %s%s%s",best and "word" or "skipped",word,x,y,colour~="" and colour or "-",
        kinds[kind] or "",
        a and string.format(" enemy %s dx %d dy %d dist %.0f",tostring(a.id),x-a.x,y-a.y,a.dist) or " no enemies"))
end

-- Reads the helper's latest frame into T.words (entries reused), keeping
-- the text that is a known word (T.dict) and sits by an enemy. A new
-- sequence number means the helper is running.
local function readWords(now)
    local file=io.open(paths().words,"r")
    if not file then return end
    local text=file:read("*a")
    file:close()
    local seq=tonumber(text:match("^seq (%d+)"))
    if not seq or seq==T.seq then return end
    T.seq=seq; T.seqAt=now
    T.reads=T.reads+1
    local dict,n=T.dict,0
    for read,x,y,kind,colour in text:gmatch("\n([^\t\n]+)\t(%-?%d+)\t(%-?%d+)\t?(%d?)\t?([%d,]*)") do
        local word=dict:match(read)
        if word then
            x,y,kind=tonumber(x),tonumber(y),tonumber(kind) or 0
            local best,near=owner(x,y)
            -- Noted once when it appears (not seen in the last frame read),
            -- once per frame however many times it's on screen.
            if (T.shown[word] or -1)<T.reads-1 then noteSighting(word,x,y,kind,colour,best,near) end
            T.shown[word]=T.reads
            if best then
                n=n+1
                local e=T.words[n] or {}
                T.words[n]=e
                e.word=word; e.y=y; e.dist=best.dist; e.kind=kind; e.big=best.big
            end
        end
    end
    T.count=n
end

-- Whether e goes before best: a green label (the user wants those above
-- anything else), then a gold one (the user: anything but the usual blue
-- first), then the word on the enemy nearest you (enemies walk toward the
-- players; the user wants that before the boss), then a big enemy's (the
-- boss) when as near, then the lower one on screen.
local function before(e,best)
    if e.kind~=best.kind then return e.kind>best.kind end
    if e.dist~=best.dist then return e.dist<best.dist end
    if e.big~=best.big then return e.big end
    return e.y>best.y
end

-- The word to type next, leaving out those just submitted.
function T.pick(now)
    local best
    for i=1,T.count do
        local e=T.words[i]
        local recent=T.recent[e.word]
        if not (recent and now<recent) and (not best or before(e,best)) then best=e end
    end
    return best and best.word
end

local function finish(now,submitted)
    if submitted then T.recent[T.word]=now+T.recentFor; T.submitted=T.submitted+1 end
    T.word=nil; T.step=nil
    T.nextPick=now+addon.settings.submitDelayMs
end

-- Time allowed for the helper to type a word: its keys at the set speed,
-- plus this much (ms), before the request is given up.
T.typeSlack=3000

-- Asks the helper to type word.
local function start(now,word)
    if not writeType(word) then T.status="Can't write the typing request"; return end
    T.word=word; T.step="sent"; T.sentAt=now; T.checkTypedAt=now+50
    T.status="Typing "..word
end

-- Waits for the helper's answer: done (submitted) or stopped.
local function advance(now)
    if now<T.checkTypedAt then return end
    T.checkTypedAt=now+50
    local result=readTyped()
    if result=="done" then return finish(now,true) end
    if result=="stopped" then return finish(now,false) end
    if now-T.sentAt>(#T.word+1)*1000/addon.settings.charsPerSecond+T.typeSlack then
        T.abort(); T.nextPick=now+addon.settings.submitDelayMs
    end
end

-- Runs every update while FFXIVLib's data is loaded. It types only while
-- the loop runs (Start): Stop drops the word under way at once, and
-- T.lease tells the helper.
function T.tick()
    local now=Now()
    local on=addon.Loop.running()
    -- The word list's index, a little per update until it's complete.
    if not T.dict then T.dict=T.dictionary(T.knownWords()) end
    if not T.dict.built then T.dict:build(T.buildBudget) end
    if now>=T.checkAt then
        T.checkAt=now+T.readEvery
        T.open,T.enabled=inputState()
        local active=on and T.open
        if active then readEnemies() end
        -- At once when the text box opens or closes or input turns on or off
        -- (the helper checks it before every key), and every stateEvery in
        -- the duty for the enemies' area.
        local changed=active~=T.active or (active and T.enabled~=T.input)
        T.active=active; T.input=active and T.enabled
        if on and (changed or (active and now-T.stateAt>=T.stateEvery)) then writeState() end
        if active then readWords(now) end
    end
    if not (on and T.open) then
        if T.step then T.abort() end
        T.status="Idle"
        return
    end
    if not T.enabled then
        if T.step then T.abort() end
        T.status="Letterlock: holding keys"
        return
    end
    if now-T.seqAt>T.staleAfter then
        if T.step then T.abort() end
        T.status=T.seq and "The OCR helper stopped" or "Waiting for the OCR helper"
        return
    end
    if T.step then return advance(now) end
    if now<T.nextPick then return end
    local word=T.pick(now)
    if not word then T.status="No word read"; return end
    start(now,word)
end
