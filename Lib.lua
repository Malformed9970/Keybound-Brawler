KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Lib=addon.Lib or {}
local L=addon.Lib

-- The one fixed ID: Keybound Brawler's ContentFinderCondition row. Everything
-- else is derived from it through FFXIVLib (sheet rows via FFXIVLib.Cache SQL,
-- plus its NPC/shop/map/quest APIs):
--   duty row -> territory and unlock quest
--   quest row -> event (Festival), prerequisite, level, giver and the ToDo
--                Level rows (who or where each step happens)
--   registrar -> the NPC whose CustomTalk requires the unlock quest
--   square    -> the registrar's map; entry NPCs hold a Warp into it
--   shop      -> the SpecialShop that requires the event: its offers, cost
--                currency, trader, and repeatable (non-unique, stackable) items
-- FFXIVLib lookups are async (nil until loaded), so refresh() runs every pulse
-- until ready().
L.cfc=1095

function L.available() return FFXIVLib~=nil and FFXIVLib.API~=nil and FFXIVLib.Cache~=nil end

function L.reset() L.data={npcs={}}; L.isReady=false end

local function query(key,sql)
    L.cache=L.cache or FFXIVLib.Cache.Create("keybound_sheets")
    return L.cache:QueryAll(key,sql)
end

local function npc(id)
    local A=FFXIVLib.API
    local name=A.NPC.GetENpcName(id)
    local spawns=A.NPC.GetENpcSpawns(id)
    local spawn=type(spawns)=="table" and spawns[1]
    if not spawn or not name or name=="" then return nil end
    return {id=id,name=name,map=spawn.mapid,pos={x=spawn.x,y=spawn.y,z=spawn.z}}
end

local function npcs(ids)
    local out,complete={},true
    for i,id in ipairs(ids) do
        out[i]=npc(id)
        if not out[i] then complete=false end
    end
    return complete and out or nil
end

local function joined(ids)
    local parts={}
    for i,id in ipairs(ids) do parts[i]=tostring(id) end
    return table.concat(parts,",")
end

local function loadDuty(d)
    local rows=query("kb-cfc-v1:"..L.cfc,"SELECT TerritoryType, UnlockCriteria FROM ContentFinderCondition WHERE RowId = "..L.cfc)
    if rows then d.dutyMap=rows[1].TerritoryType; d.questRow=rows[1].UnlockCriteria end
end

-- Quest columns: Festival, PreviousQuest[], ClassJobLevel[], IssuerStart,
-- IssuerLocation (Level), TodoParams_ToDoCompleteSeq[] and
-- TodoParams_ToDoLocation<N>[] (Level rows per ToDo, N = 0..7).
local function loadQuest(d)
    local rows=query("kb-quest-v1:"..d.questRow,"SELECT * FROM Quest WHERE RowId = "..d.questRow)
    if not rows then return end
    local r=rows[1]
    local q={row=d.questRow,id=d.questRow-65536,festival=r.Festival,level=r.ClassJobLevel[1],
        giver=r.IssuerStart,giverLevel=r.IssuerLocation,todo={},levelIds={r.IssuerLocation}}
    local previous=r.PreviousQuest[1]
    if previous and previous>0 then q.prereq=previous-65536 end
    local columns={}
    for key in pairs(r) do
        local n=tostring(key):match("^TodoParams_ToDoLocation(%d+)$")
        if n then columns[#columns+1]=tonumber(n) end
    end
    table.sort(columns)
    for i,seq in ipairs(r.TodoParams_ToDoCompleteSeq) do
        local levels={}
        for _,n in ipairs(columns) do
            local level=r["TodoParams_ToDoLocation"..n][i]
            if level and level>0 then levels[#levels+1]=level; q.levelIds[#q.levelIds+1]=level end
        end
        if #levels>0 then q.todo[#q.todo+1]={seq=seq,levels=levels} end
    end
    d.quest=q
end

-- Resolves the giver and every ToDo Level row into {npc, name, map, pos}.
local function loadQuestPlaces(d)
    local q=d.quest
    local rows=query("kb-levels-v1:"..q.row,"SELECT RowId, Type, Object, Territory, X, Y, Z FROM Level WHERE RowId IN ("..joined(q.levelIds)..")")
    if not rows then return end
    local A=FFXIVLib.API
    local byId,complete={},true
    for _,row in ipairs(rows) do
        local place={map=row.Territory,pos={x=row.X,y=row.Y,z=row.Z}}
        if row.Type==8 then
            place.npc=row.Object
            place.name=A.NPC.GetENpcName(row.Object)
            if not place.name or place.name=="" then complete=false end
        end
        byId[row.RowId]=place
    end
    if not complete then return end
    local steps={}
    for _,todo in ipairs(q.todo) do
        local places={}
        for _,level in ipairs(todo.levels) do places[#places+1]=byId[level] end
        steps[todo.seq]=places
    end
    q.start=byId[q.giverLevel]
    q.steps=steps
end

local function loadQuestNames(d)
    local A,q=FFXIVLib.API,d.quest
    local name=A.Quest.GetQuestName(q.id)
    if name and name~="" then q.name=name end
    if q.prereq then
        local prereqName=A.Quest.GetQuestName(q.prereq)
        if prereqName and prereqName~="" then q.prereqName=prereqName end
    end
end

local function loadRegistrar(d)
    local rows=query("kb-registrar-v1:"..d.questRow,
        "SELECT RowId FROM ENpcBase WHERE list_has_any(ENpcData, (SELECT list(RowId) FROM CustomTalk WHERE list_contains(Script_ScriptArg, "..d.questRow..")))")
    if rows then d.registrarId=rows[1].RowId end
end

local function loadEntries(d)
    local rows=query("kb-entries-v1:"..d.squareMap,
        "SELECT RowId FROM ENpcBase WHERE list_has_any(ENpcData, (SELECT list(RowId) FROM Warp WHERE TerritoryType = "..d.squareMap.."))")
    if not rows then return end
    local ids={}
    for i,row in ipairs(rows) do ids[i]=row.RowId end
    d.entryIds=ids
end

-- Offers in shop order: {item, key, name, price, priceText, count, index, stack, repeatable}.
local function loadShopRow(d)
    local rows=query("kb-shop-v1:"..d.quest.festival,
        "SELECT RowId, Item_Item0, Item_ReceiveCount0, Item_ItemCost0, Item_CurrencyCost0 FROM SpecialShop WHERE RequiredFestival = "..d.quest.festival)
    if not rows then return end
    local r=rows[1]
    local shop={id=r.RowId,currency=r.Item_ItemCost0[1],items={},itemIds={}}
    for i,item in ipairs(r.Item_Item0) do
        if item>0 then
            local price=r.Item_CurrencyCost0[i]
            shop.items[#shop.items+1]={item=item,price=price,count=r.Item_ReceiveCount0[i],index=i-1,key=tostring(item),priceText=tostring(price)}
            shop.itemIds[#shop.itemIds+1]=item
        end
    end
    d.shopRow=shop
end

local function loadShopItems(d)
    local shop=d.shopRow
    local rows=query("kb-items-v1:"..shop.id,"SELECT RowId, IsUnique, StackSize FROM Item WHERE RowId IN ("..joined(shop.itemIds)..")")
    if not rows then return end
    local flags,complete={},true
    for _,row in ipairs(rows) do flags[row.RowId]=row end
    for _,e in ipairs(shop.items) do
        local name=FFXIVLib.API.Items.GetItemName(e.item)
        if name and name~="" then e.name=name else complete=false end
        e.stack=flags[e.item].StackSize
        e.repeatable=not flags[e.item].IsUnique and e.stack>1
    end
    if complete then d.shop=shop end
end

-- What each unlock item teaches, as Minion's Inventory:IsUnlocked(kind, id)
-- sees it: ItemAction.Action -> the kind, and where the unlocked row's id
-- sits (ItemAction.Data[1] or Item.AdditionalData). The kinds were matched to
-- sheets by their highest unlocked id (probed 2026-10-25).
L.unlockKinds={
    [853]={kind=0,from="data"},           -- minion (Companion)
    [1322]={kind=2,from="data"},          -- mount
    [25183]={kind=6,from="additional"},   -- orchestrion roll
    [20086]={kind=7,from="data"},         -- fashion accessory (Ornament)
    [29459]={kind=10,from="additional"},  -- framer's kit
}

-- Unlock links (Action 2633) have no Inventory:IsUnlocked kind. For an emote
-- (the Emote row whose UnlockLink is Data[1], as Dalamud finds it) the Emote
-- window tells (addon.Emotes); kind 9, which looked like an emote check,
-- agreed with that window on only 196 of 333 emotes. Other unlock links
-- count as owned once this addon has bought one.
L.unlockLinkAction=2633

-- Marks each offer with unlock={kind, id}, or learnable=true (plus the
-- emote it teaches, if any) for an unlock link.
local function loadShopUnlocks(d)
    local shop=d.shop
    local rows=query("kb-unlocks-v2:"..shop.id,
        "SELECT i.RowId, i.AdditionalData, a.Action, a.Data, e.RowId AS Emote FROM Item i JOIN ItemAction a ON a.RowId = i.ItemAction"
        .." LEFT JOIN Emote e ON a.Action = 2633 AND a.Data[1] > 0 AND e.UnlockLink = a.Data[1] WHERE i.RowId IN ("..joined(shop.itemIds)..")")
    if rows==nil then return end
    local byItem={}
    for _,row in ipairs(rows or {}) do byItem[row.RowId]=row end
    for _,e in ipairs(shop.items) do
        local row=byItem[e.item]
        local unlock=row and L.unlockKinds[row.Action]
        if unlock then
            local id=unlock.from=="data" and row.Data[1] or row.AdditionalData
            if id and id>0 then e.unlock={kind=unlock.kind,id=id} end
        elseif row and row.Action==L.unlockLinkAction then
            e.learnable=true; e.emote=row.Emote
        end
    end
    shop.unlocksLoaded=true
end

local function loadWords(d)
    local rows=query("kb-words-v1","SELECT RowId, col_0 FROM KTGTypeWordTextData")
    if rows==nil then return end
    local words={}
    for _,row in ipairs(rows or {}) do
        local text=FFXIVLib.Cache.Text(row.col_0)
        if text and text~="" then words[row.RowId]=text end
    end
    d.words=words
end

-- KTGBNpc: enemy BNpcBase -> word program and kind. In the duty every regular
-- enemy has content ID 108 (2026-10-28), so this only labels the few that
-- match in the capture.
local function loadEnemies(d)
    local rows=query("kb-enemies-v1","SELECT RowId, col_0 AS bnpc, col_1 AS program, col_2 AS kind, col_3 AS value FROM KTGBNpc WHERE col_0 > 0")
    if rows==nil then return end
    local enemies={}
    for _,row in ipairs(rows or {}) do enemies[row.bnpc]={row=row.RowId,program=row.program,kind=row.kind,value=row.value} end
    d.enemies=enemies
end

-- Advances every pending lookup; call it until it returns true.
function L.refresh()
    if L.isReady then return true end
    if not L.available() then return false end
    L.data=L.data or {npcs={}}
    local A,d=FFXIVLib.API,L.data
    if not d.questRow then loadDuty(d) end
    if d.questRow and not d.quest then loadQuest(d) end
    if d.quest and not d.quest.steps then loadQuestPlaces(d) end
    -- Until both names are in: the prerequisite's can come later than the
    -- quest's (live, 2026-10-28: stuck on "quest names" otherwise).
    if d.quest and not (d.quest.name and (not d.quest.prereq or d.quest.prereqName)) then loadQuestNames(d) end
    if d.questRow and not d.registrarId then loadRegistrar(d) end
    if d.registrarId and not d.npcs.registrar then
        d.npcs.registrar=npc(d.registrarId)
        if d.npcs.registrar then d.squareMap=d.npcs.registrar.map end
    end
    if d.squareMap and not d.entryIds then loadEntries(d) end
    if d.entryIds and not d.entries then d.entries=npcs(d.entryIds) end
    if d.quest and d.quest.start and not d.aetheryte then
        d.hubMap=d.quest.start.map
        for id,row in pairs(A.Map.GetAetherytesByMapId(d.hubMap) or {}) do
            if row.IsAetheryte then d.aetheryte=id end
        end
    end
    if d.quest and not d.shopRow then loadShopRow(d) end
    if d.shopRow and not d.shop then loadShopItems(d) end
    if d.shop and not d.shop.unlocksLoaded then loadShopUnlocks(d) end
    if d.shop and not d.npcs.trader then
        local vendor=(A.Shop.GetInclusionShopVendors(d.shop.id) or {})[1]
        if vendor then d.npcs.trader=npc(vendor.npcId) end
    end
    if d.shop and not d.cap then
        local cap=FFXIVLib.ItemHelpers.GetCurrencyCap(d.shop.currency)
        if cap and cap>0 then d.cap=cap end
    end
    if not d.words then loadWords(d) end
    if not d.enemies then loadEnemies(d) end
    local missing=L.missing()
    L.isReady=#missing==0
    -- The window's loading line, built here so drawing doesn't.
    L.missingText=table.concat(missing,", ")
    if L.isReady then
        addon.Debug.log(string.format("FFXIVLib data ready: quest %s, %d offers, duty map %d, square %d, %d entry NPCs",
            d.quest.name,#d.shop.items,d.dutyMap,d.squareMap,#d.entries))
    end
    return L.isReady
end

function L.ready() return L.isReady==true end

-- Pieces still loading, for the UI and the environment test.
function L.missing()
    local d,out=L.data or {npcs={}},{}
    local q=d.quest
    if not d.dutyMap then out[#out+1]="duty" end
    if not (q and q.steps and q.start) then out[#out+1]="quest" end
    if not (q and q.name and (not q.prereq or q.prereqName)) then out[#out+1]="quest names" end
    for _,key in ipairs({"registrar","trader"}) do if not d.npcs[key] then out[#out+1]=key end end
    for _,key in ipairs({"entries","aetheryte","shop","cap","words","enemies"}) do
        if not d[key] then out[#out+1]=key end
    end
    if d.shop and not d.shop.unlocksLoaded then out[#out+1]="unlocks" end
    return out
end
