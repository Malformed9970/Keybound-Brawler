KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Coffers=addon.Coffers or {}
local C=addon.Coffers

-- The window's Open Coffers button: opens Keybound Coffers (the shop's
-- repeatable offer) from your bags, the chosen number or, at 0, all of
-- them. One at a time, the way ffxivminion uses an item: once the game says
-- it's ready, and the next only after one has gone from your bags. Not
-- while the loop runs (Start stops it), in combat or in the duty, nor with
-- no free bag slot for what's inside. A coffer still there after waitMs
-- stops it.
C.waitMs,C.stepMs=5000,250

function C.reset() C.active=false; C.status=nil; C.opened=0; C.before=nil; C.notReadySince=nil end

local function finish(text)
    C.active=false; C.before=nil; C.status=text
    addon.Debug.log(text,true)
end

function C.stop() if C.active then finish("Stopped opening coffers after "..C.opened) end end

-- Opens count coffers (0: every one in your bags).
function C.start(count)
    local e=addon.Shop.repeatable()
    if not e or addon.Loop.running() then return end
    C.item=e.item; C.wanted=count; C.opened=0; C.before=nil; C.notReadySince=nil; C.nextAt=0
    C.active=true; C.status="Opening coffers"
end

-- Called each pulse while FFXIVLib's data is loaded.
function C.tick()
    if addon.Loop.running() then
        if C.active then finish("Stopped opening coffers: the loop started") end
        C.status=nil
        return
    end
    if not C.active then return end
    local now=Now()
    if now<C.nextAt then return end
    C.nextAt=now+C.stepMs
    local have=Inventory:GetItemCount(C.item) or 0
    if C.before then
        if have>=C.before then
            if now-C.usedAt>C.waitMs then finish("A coffer didn't open: stopped after "..C.opened) end
            return
        end
        C.opened=C.opened+1; C.before=nil
        C.status="Opened "..C.opened..(C.wanted>0 and (" of "..C.wanted) or "")
    end
    if C.wanted>0 and C.opened>=C.wanted or have==0 then
        return finish(C.opened==0 and "No Keybound Coffers in your bags" or ("Opened "..C.opened..(C.opened==1 and " coffer" or " coffers")))
    end
    if Player.incombat or addon.currentMap()==addon.Lib.data.dutyMap then return finish("Can't open coffers here") end
    if addon.Shop.freeSlots()==0 then return finish("Inventory full: stopped after "..C.opened) end
    local item=GetItem(C.item)
    if not item then return finish("Couldn't find a coffer in your bags") end
    if not item:IsReady(Player.id) then
        C.notReadySince=C.notReadySince or now
        if now-C.notReadySince>C.waitMs then finish("Coffers can't be opened right now") end
        return
    end
    C.notReadySince=nil
    C.before=have; C.usedAt=now
    item:Cast(Player.id)
end
