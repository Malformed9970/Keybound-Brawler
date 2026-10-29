KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Shop=addon.Shop or {}
local S=addon.Shop

S.windows={"ShopExchangeCurrency","ShopExchangeItem"}

-- The shop's repeatable offer (non-unique and stackable: the Keybound coffer).
function S.repeatable()
    for _,e in ipairs(addon.Lib.data.shop.items) do if e.repeatable then return e end end
end

-- Every other offer in the buy order: the saved drag order first, then any
-- offer missing from it in shop order.
function S.ordered(settings)
    local byId,seen,out={},{},{}
    local items=addon.Lib.data.shop.items
    for _,e in ipairs(items) do if not e.repeatable then byId[e.item]=e end end
    for _,id in ipairs(settings.order) do
        if byId[id] and not seen[id] then out[#out+1]=byId[id]; seen[id]=true end
    end
    for _,e in ipairs(items) do
        if not e.repeatable and not seen[e.item] then out[#out+1]=e end
    end
    return out
end

-- Moves the offer at position from to position to (1-based); saved with the
-- window's other edits.
function S.move(from,to)
    local list=S.ordered(addon.settings)
    if from==to or not list[from] or not list[to] then return end
    table.insert(list,to,table.remove(list,from))
    local order={}
    for i,e in ipairs(list) do order[i]=e.item end
    addon.settings.order=order
    addon.SettingsChanged()
    S.refreshView()
end

-- Free slots in the four inventory bags (Inventory:Get(0..3), the bags
-- ffxivminion's IsInventoryFull counts).
function S.freeSlots()
    local free=0
    for bag=0,3 do
        local b=Inventory:Get(bag)
        if b then free=free+(b.free or 0) end
    end
    return free
end

-- How many of qty fit in slots free slots, and how many slots they take. A
-- stackable item first tops up the partial stack already held.
local function fit(e,qty,slots)
    local stack=e.stack or 1
    if stack<=1 then
        qty=math.min(qty,slots)
        return qty,qty
    end
    local held=ItemCount(e.item)
    local room=held%stack>0 and (stack-held%stack) or 0
    qty=math.min(qty,room+slots*stack)
    return qty,math.ceil(math.max(0,qty-room)/stack)
end

-- Which offers you own (S.owned[item]): in the bags, equipped or in the
-- armoury (Inventory:GetItemCount counts all of those), or already unlocked
-- for an item that teaches a minion, mount, orchestrion roll, fashion
-- accessory or framer's kit (Lib marks those). An emote counts once the
-- Emote window has listed it (addon.Emotes). Any unlock link without a check
-- counts once this addon has bought one. Read at most every 2 s (force after
-- a purchase); a change rebuilds the window's view.
S.owned=S.owned or {}
-- Bought during the current trader visit, in case the item shows up in the
-- inventory a moment after the MGC is taken.
S.runBought=S.runBought or {}
function S.checkOwned(force)
    if not force and S.ownedAt and TimeSince(S.ownedAt)<2000 then return end
    S.ownedAt=Now()
    local bought,emotes=addon.settings.bought,addon.settings.emotes
    for _,e in ipairs(addon.Lib.data.shop.items) do
        if not e.repeatable then
            local owned=(Inventory:GetItemCount(e.item) or 0)>0
                or (e.unlock~=nil and Inventory:IsUnlocked(e.unlock.kind,e.unlock.id)==true)
                or (e.emote~=nil and emotes[tostring(e.emote)]==true)
                or (e.learnable==true and (bought[e.key] or 0)>0)
            if S.owned[e.item]~=owned then S.owned[e.item]=owned; S.dirty=true end
        end
    end
end

-- What to buy with mgc: ticked items you don't own, in the buy order, while
-- the budget (mgc minus the reserve) lasts; an item that is too expensive
-- for now is skipped and the next one tried. The repeatable offer takes what
-- is left only once every ticked item is bought, so it never eats MGC saved
-- for one. At most 99 per purchase. With slots, only what fits in that many
-- free inventory slots is planned; without, inventory space is ignored.
function S.plan(mgc,settings,slots)
    S.checkOwned()
    local out,budget,pending={},(mgc or 0)-settings.keepReserve,false
    for _,e in ipairs(S.ordered(settings)) do
        local remaining=(settings.wants[e.key]==1 and not S.owned[e.item] and not S.runBought[e.item]) and 1 or 0
        local qty=math.max(0,math.min(remaining,math.floor(budget/e.price),99))
        if qty>0 and slots then
            local used
            qty,used=fit(e,qty,slots)
            slots=slots-used
        end
        if qty>0 then out[#out+1]={item=e.item,key=e.key,name=e.name,price=e.price,qty=qty}; budget=budget-qty*e.price end
        if remaining>qty then pending=true end
    end
    local repeatable=S.repeatable()
    if settings.coffers and repeatable and not pending then
        local qty=math.min(math.floor(budget/repeatable.price),99)
        if qty>0 and slots then qty=fit(repeatable,qty,slots) end
        if qty>0 then out[#out+1]={item=repeatable.item,key=repeatable.key,name=repeatable.name,price=repeatable.price,qty=qty,repeatable=true} end
    end
    return out,pending
end

-- Whether there's anything to buy at all, whatever MGC you hold: coffers
-- are on, or a ticked offer isn't owned yet.
function S.anythingToBuy(settings)
    if settings.coffers and S.repeatable() then return true end
    S.checkOwned()
    for _,e in ipairs(addon.Lib.data.shop.items) do
        if not e.repeatable and settings.wants[e.key]==1 and not S.owned[e.item] then return true end
    end
    return false
end

-- Time to visit the trader: MGC has reached the threshold and something
-- planned fits in the inventory.
function S.due()
    local mgc=addon.mgc()
    return mgc~=nil and mgc>=addon.settings.spendAt and #S.plan(mgc,addon.settings,S.freeSlots())>0
end

-- MGC has reached the threshold and there is something to buy, but none of
-- it fits in the inventory.
function S.blockedBySpace()
    local mgc=addon.mgc()
    if not mgc or mgc<addon.settings.spendAt then return false end
    return #S.plan(mgc,addon.settings)>0 and #S.plan(mgc,addon.settings,S.freeSlots())==0
end

-- What the window shows, so drawing allocates nothing: the buy order, which
-- rows you own (drawn dimmed), the tally of what's left to buy, and the MGC
-- bar. Checked each pulse but only rebuilt when MGC, ownership or settings
-- changed (S.dirty).
function S.refreshView()
    local s=addon.settings
    local mgc=addon.mgc() or 0
    S.checkOwned()
    if S.view and not S.dirty and S.view.mgc==mgc then return end
    S.dirty=false
    local cap=addon.Lib.data.cap
    local view={list=S.ordered(s),repeatable=S.repeatable(),owned={},mgc=mgc}
    local ticked,count,cost,total=0,0,0,0
    for _,e in ipairs(view.list) do
        local owned=S.owned[e.item]==true
        view.owned[e.item]=owned
        total=total+e.price
        if s.wants[e.key]==1 then
            ticked=ticked+1
            if not owned then count=count+1; cost=cost+e.price end
        end
    end
    view.toBuy,view.toBuyCost,view.totalCost=count,cost,total
    view.tally=count>0 and string.format("To buy: %d %s, %d MGC",count,count==1 and "item" or "items",cost)
        or (ticked>0 and "Everything ticked is owned" or "Nothing ticked")
    view.fraction=math.min(1,mgc/cap)
    view.mgcText=mgc.." / "..cap.." MGC"
    S.view=view
end

local function openWindow()
    for _,name in ipairs(S.windows) do if IsControlOpen(name) then return name end end
end

function S.reset()
    S.state="approach"; S.line=nil; S.window=nil; S.tries=0
    for item in pairs(S.runBought) do S.runBought[item]=nil end
end

-- One purchase run at the MGC trader. Returns true when finished, false while
-- working, or nil,error.
function S.tick()
    S.state=S.state or "approach"
    if S.state=="approach" then
        local done,err=addon.Movement.interact(addon.Lib.data.npcs.trader,true)
        if done==nil then return nil,err end
        if done then S.state="open"; S.since=Now() end
        return false
    elseif S.state=="open" then
        S.window=openWindow()
        if S.window then S.state="buy"; return false end
        -- The trader opens the shop (ShopExchangeCurrency) straight away, with
        -- no talk or menu (captured 2026-10-28). A menu means something else
        -- is going on.
        if IsControlOpen("SelectIconString") or IsControlOpen("SelectString") then
            return nil,"The MGC trader opened a menu instead of the shop"
        end
        -- Talk lines get 15 s in all; nothing at all gets 5 s, then one more
        -- try (Movement walks up close for a repeat).
        local talking=IsControlOpen("Talk")
        if TimeSince(S.since)>(talking and 15000 or 5000) then
            if talking then return nil,"The MGC trader's talk didn't end" end
            if (S.tries or 0)<1 then S.tries=1; S.state="approach"; return false end
            return nil,"The MGC trader's shop did not open"
        end
        if talking then UseControlAction("Talk","Click") end
        return false
    elseif S.state=="buy" then
        local line=S.plan(addon.mgc(),addon.settings,S.freeSlots())[1]
        if not line then S.state="close"; S.since=Now(); return false end
        S.line=line; S.before=addon.mgc(); S.since=Now()
        addon.Debug.log(string.format("Buying %dx %s for %d MGC",line.qty,line.name,line.qty*line.price),true)
        if not Inventory:BuyShopItem(line.item,line.qty) then return nil,"Could not buy "..line.name end
        S.state="confirm"
        return false
    elseif S.state=="confirm" then
        local now=addon.mgc()
        if now and S.before and now<S.before then
            -- Remembered for items with no unlock check (S.checkOwned).
            if not S.line.repeatable then
                addon.settings.bought[S.line.key]=(addon.settings.bought[S.line.key] or 0)+S.line.qty
                S.runBought[S.line.item]=true
            end
            addon.SaveSettings()
            S.checkOwned(true)
            S.state="buy"
            return false
        end
        -- Checked before the dialogs, so one that won't close can't hold it.
        if TimeSince(S.since)>5000 then return nil,"No MGC was spent on "..S.line.name end
        if IsControlOpen("ShopExchangeItemDialog") then UseControlAction("ShopExchangeItemDialog","Exchange"); return false end
        if IsControlOpen("SelectYesno") then UseControlAction("SelectYesno","Yes"); return false end
        return false
    elseif S.state=="close" then
        local window=openWindow()
        if window then
            if TimeSince(S.since)>5000 then return nil,"The shop window didn't close" end
            GetControl(window):Close()
            return false
        end
        S.reset()
        return true
    end
end
