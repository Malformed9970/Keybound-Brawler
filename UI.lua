KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.UI=addon.UI or {open=false,visible=false}
local U=addon.UI

local INFINITY="\226\136\158"

local MENU_ID="FFXIVMINION##MENU_KeyboundBrawler"

-- Our entry in Minion's menu, when it is already there (a reload that kept
-- Minion's menu): ml_gui.ui_mgr.menu.components[*].members[*].
local function menuEntry()
    local menu=ml_gui.ui_mgr.menu
    for _,component in pairs(menu and menu.components or {}) do
        for _,member in pairs(component.members or {}) do
            if member.id==MENU_ID then return member end
        end
    end
end

function U.init()
    U.drag=nil; U.hover=nil; U.lastHover=nil; U.cofferLabel=nil; U.infinity=nil
    U.padY=nil; U.limitFor=nil
    U.search=U.search or ""; U.shownView=nil
    U.rowFlags=GUI.SelectableFlags_SpanAllColumns+GUI.SelectableFlags_AllowOverlap
    U.limitFlags=GUI.InputTextFlags_CharsDecimal+GUI.InputTextFlags_AutoSelectAll
    U.searchFlags=GUI.InputTextFlags_AutoSelectAll
    -- tools/make_icon.ps1 draws icon.png.
    local entry={id=MENU_ID,name="Keybound Brawler",tooltip="Typing go BRRR",texture=addon.paths.root.."icon.png",
        onClick=function() U.open=not U.open end}
    local existing=menuEntry()
    if existing then
        for key,value in pairs(entry) do existing[key]=value end
    else
        ml_gui.ui_mgr:AddMember(entry,"FFXIVMINION##MENU_HEADER")
    end
end

-- Style values the layout needs, read on the first draw: text sits
-- framePadding.y lower to line up with framed widgets, and list rows are a
-- framed widget tall.
local function measure()
    U.padY=GUI:GetStyle().framepadding.y
    U.rowHeight=GUI:GetFrameHeight()
end

-- Text lined up with the framed widgets on its line.
local function alignedText(text,disabled)
    local x,y=GUI:GetCursorPos()
    GUI:SetCursorPos(x,y+U.padY)
    if disabled then GUI:TextDisabled(text) else GUI:Text(text) end
end

-- The infinity sign when Minion's font has it. A glyph the font lacks is
-- drawn as the fallback character, so it measures the same as "?" or U+FFFD.
function U.noLimit()
    if not U.infinity then
        local width=GUI:CalcTextSize(INFINITY)
        local missing=width==nil or width==GUI:CalcTextSize("?") or width==GUI:CalcTextSize("\239\191\189")
        U.infinity=missing and "No limit" or INFINITY
    end
    return U.infinity
end

local function tip(text) if GUI:IsItemHovered() then GUI:SetTooltip(text) end end

local function slider(label,key,minimum,maximum,format,help)
    local value,changed=GUI:SliderInt(label,addon.settings[key],minimum,maximum,format)
    if changed then addon.settings[key]=value; addon.SettingsChanged() end
    tip(help)
end

local function range(label,low,high,minimum,maximum,format,help)
    local s=addon.settings
    local a,b,changed=GUI:DragIntRange2(label,s[low],s[high],0.25,minimum,maximum,format,format)
    if changed then s[low]=a; s[high]=b; addon.SettingsChanged() end
    tip(help)
end

local function pair(label,value)
    GUI:TableNextRow(); GUI:TableNextColumn(); GUI:TextDisabled(label); GUI:TableNextColumn(); GUI:Text(value)
end

-- Status is whatever the loop is doing (the unlock quest, travelling,
-- shopping, playing, resting) or why it stopped or paused, marked in red
-- while purchases are skipped because the inventory is full.
local function drawStatus()
    local L=addon.Loop
    if GUI:BeginTable("##kbStatus",2) then
        GUI:TableSetupColumn("",0,1); GUI:TableSetupColumn("",0,5)
        -- Opening coffers (the loop is stopped meanwhile) shows its own status.
        local coffers=addon.Coffers.status
        pair("Status",(coffers and not L.running()) and coffers or L.status or "")
        if L.inventoryFull then GUI:SameLine(); GUI:TextColored(1,0.35,0.35,1,"(Inventory full)") end
        if L.state=="rest" then GUI:SameLine(); if GUI:SmallButton("Skip") then L.skipRest() end end
        pair("Games",L.gamesValue or "0")
        GUI:EndTable()
    end
    local view=addon.Shop.view
    local width=GUI:GetContentRegionAvail()
    GUI:ProgressBar(view.fraction,width,0,view.mgcText)
end

local LIMIT_HELP="Games to play before stopping. Click to type a number, or use - and +. 0 means no limit."

-- The limit as shown: the number, or the no-limit sign at 0. Rebuilt only
-- when it changes.
local function limitText(limit)
    local noLimit=U.noLimit()
    if limit~=U.limitFor or noLimit~=U.limitNoLimit then
        U.limitFor,U.limitNoLimit=limit,noLimit
        U.limitText=limit==0 and noLimit or tostring(limit)
    end
    return U.limitText
end

local COFFER_HELP="How many Keybound Coffers to open. Click to type a number, 0 opens every one in your bags."
local OPEN_HELP="Open Keybound Coffers from your bags: the number in the box, or all of them at 0. Not while the loop runs."
local OPEN_WIDTH,OPEN_BOX,OPEN_GAP=110,50,8

-- The coffers to open as shown: the number, or All at 0.
local function cofferText(count)
    if count~=U.cofferFor then U.cofferFor=count; U.cofferText=count==0 and "All" or tostring(count) end
    return U.cofferText
end

-- The next widget on a line whose label alignedText moved down: SameLine
-- returns to the label's height, so each framed widget goes back to y.
local function sameRow(y) GUI:SameLine(); GUI:SetCursorPos(GUI:GetCursorPosX(),y) end

-- Start and Stop in the Lj TensorReactions toolbox's button colours (its
-- healer green and DPS red role buttons), a little brighter on hover.
local function buttonColor(r,g,b)
    return {r,g,b,1,math.min(1,r*1.3),math.min(1,g*1.3),math.min(1,b*1.3)}
end
local START_COLOR,STOP_COLOR=buttonColor(0.2,0.5,0.2),buttonColor(0.7,0.2,0.2)

local function coloredButton(label,c,width)
    GUI:PushStyleColor(GUI.Col_Button,c[1],c[2],c[3],c[4])
    GUI:PushStyleColor(GUI.Col_ButtonHovered,c[5],c[6],c[7],c[4])
    GUI:PushStyleColor(GUI.Col_ButtonActive,c[1],c[2],c[3],c[4])
    local pressed=GUI:Button(label,width,0)
    GUI:PopStyleColor(3)
    return pressed
end

-- Start or Stop, then Games: a box that takes a typed number (Minion's
-- DragInt draws nothing), then - and +; on the far right, how many coffers
-- to open and Open Coffers.
local function drawControls()
    local s,L=addon.settings,addon.Loop
    local startX,y=GUI:GetCursorPos()
    local rowWidth=GUI:GetContentRegionAvail()
    if L.running() then
        if coloredButton("Stop",STOP_COLOR,90) then L.stop() end
    elseif coloredButton("Start",START_COLOR,90) then
        L.start()
    end
    GUI:SameLine()
    alignedText("Games:")
    sameRow(y)
    GUI:PushItemWidth(70)
    local typed,changed=GUI:InputText("##kbLimit",limitText(s.maxGames),U.limitFlags)
    GUI:PopItemWidth()
    tip(LIMIT_HELP)
    local value=changed and tonumber(typed)
    if value then s.maxGames=math.max(0,math.min(9999,math.floor(value))); addon.SettingsChanged() end
    sameRow(y)
    if GUI:Button("-##kbLimitDown",0,0) and s.maxGames>0 then s.maxGames=s.maxGames-1; addon.SettingsChanged() end
    sameRow(y)
    if GUI:Button("+##kbLimitUp",0,0) and s.maxGames<9999 then s.maxGames=s.maxGames+1; addon.SettingsChanged() end
    sameRow(y)
    GUI:SetCursorPos(math.max(GUI:GetCursorPosX(),startX+rowWidth-OPEN_BOX-OPEN_GAP-OPEN_WIDTH),y)
    GUI:PushItemWidth(OPEN_BOX)
    local count,countChanged=GUI:InputText("##kbCoffers",cofferText(s.coffersToOpen),U.limitFlags)
    GUI:PopItemWidth()
    tip(COFFER_HELP)
    local n=countChanged and tonumber(count)
    if n then s.coffersToOpen=math.max(0,math.min(999,math.floor(n))); addon.SettingsChanged() end
    sameRow(y)
    local C=addon.Coffers
    if C.active then
        if coloredButton("Stop opening",STOP_COLOR,OPEN_WIDTH) then C.stop() end
    elseif GUI:Button("Open Coffers",OPEN_WIDTH,0) then
        C.start(s.coffersToOpen)
    end
    tip(OPEN_HELP)
end

-- Drag and drop, tracked by hand (Minion's GUI has no ImGui drag-and-drop
-- API): pressing a row picks it up, the row under the mouse is the drop
-- target, and releasing the mouse moves the picked row there.
--
-- Each row is a checkbox tall: the row's selectable (which carries the hover
-- highlight across every column) is given that height, and the texts sit
-- framePadding.y lower to line up with the checkbox. Names stay on one line
-- so every row is the same height.
local function drawRow(i,e,view)
    local s=addon.settings
    GUI:PushID(e.key)
    GUI:TableNextRow(); GUI:TableNextColumn()
    local x,y=GUI:GetCursorPos()
    GUI:Selectable("##row",U.drag~=nil and U.lastHover==i,U.rowFlags,0,U.rowHeight)
    -- The row's selectable also sees clicks on its checkbox, which sits on
    -- top of it: a press picks the row up only when the checkbox isn't hovered.
    local pressed=GUI:IsItemClicked(0)
    if U.drag and GUI:IsItemHovered(GUI.HoveredFlags_AllowWhenBlockedByActiveItem) then U.hover=i end
    GUI:SetCursorPos(x,y)
    alignedText("::",true)
    GUI:TableNextColumn()
    local checked,changed=GUI:Checkbox("##buy",s.wants[e.key]==1)
    if changed then s.wants[e.key]=checked and 1 or nil; addon.SettingsChanged(); addon.Shop.refreshView() end
    if pressed and not GUI:IsItemHovered() then U.drag=i end
    GUI:TableNextColumn(); alignedText(e.name,view.owned[e.item])
    GUI:TableNextColumn(); alignedText(e.priceText)
    GUI:PopID()
end

-- The rows the list shows (positions in view.list): names containing the
-- search text (any case), minus owned items while Hide owned is on. Rebuilt
-- only when the view, the search or Hide owned changes, along with whether
-- every shown row is ticked and what the shown rows cost.
local function shownRows(view)
    local search,hide=U.search,addon.settings.hideOwned
    if view==U.shownView and search==U.shownSearch and hide==U.shownHide then return U.shown end
    U.shownView,U.shownSearch,U.shownHide=view,search,hide
    local needle,s=search:lower(),addon.settings
    local rows,cost,all={},0,true
    for i,e in ipairs(view.list) do
        e.lowerName=e.lowerName or e.name:lower()
        if (needle=="" or e.lowerName:find(needle,1,true)) and not (hide and view.owned[e.item]) then
            rows[#rows+1]=i
            cost=cost+e.price
            if s.wants[e.key]~=1 then all=false end
        end
    end
    U.shown=rows
    U.shownAllTicked=#rows>0 and all
    U.selectTip=(needle=="" and not hide) and ("Tick every item ("..cost.." MGC for all of them).")
        or ("Tick every item shown ("..cost.." MGC for them).")
    return rows
end

-- Ticks or unticks every shown row.
local function drawSelectAll(view,rows)
    local s=addon.settings
    local checked,changed=GUI:Checkbox("Select all##kbAll",U.shownAllTicked)
    tip(U.selectTip)
    if changed then
        for _,i in ipairs(rows) do s.wants[view.list[i].key]=checked and 1 or nil end
        addon.SettingsChanged(); addon.Shop.refreshView()
    end
end

local function drawHideOwned()
    local s=addon.settings
    local checked,changed=GUI:Checkbox("Hide owned##kbHideOwned",s.hideOwned)
    tip("Leave out items you already own: in your bags, equipped, in the armoury, or unlocked.")
    if changed then s.hideOwned=checked; addon.SettingsChanged() end
end

local function drawSearch()
    local _,y=GUI:GetCursorPos()
    alignedText("Search")
    sameRow(y)
    GUI:PushItemWidth(GUI:GetContentRegionAvail())
    local text,changed=GUI:InputText("##kbSearch",U.search,U.searchFlags)
    GUI:PopItemWidth()
    if changed and text then U.search=text end
end

local function drawShop()
    local s,view=addon.settings,addon.Shop.view
    GUI:Separator()
    local rows=shownRows(view)
    local _,y=GUI:GetCursorPos()
    alignedText("Shopping list")
    sameRow(y); drawSelectAll(view,rows)
    sameRow(y); drawHideOwned()
    drawSearch()
    view=addon.Shop.view
    rows=shownRows(view)
    GUI:BeginChild("##kbList",0,236,true)
    if GUI:BeginTable("##kbShop",4) then
        GUI:TableSetupColumn("",0,0.4); GUI:TableSetupColumn("",0,0.5); GUI:TableSetupColumn("Item",0,6)
        GUI:TableSetupColumn("MGC",0,1)
        GUI:TableHeadersRow()
        U.hover=nil
        for _,i in ipairs(rows) do drawRow(i,view.list[i],view) end
        GUI:EndTable()
    end
    if #rows==0 then GUI:TextDisabled(U.search~="" and "No items match the search." or "Everything is owned.") end
    GUI:EndChild()
    if U.drag then
        if GUI:IsMouseDown(0) then
            U.lastHover=U.hover or U.lastHover
        else
            if U.hover and U.hover~=U.drag then addon.Shop.move(U.drag,U.hover) end
            U.drag=nil; U.lastHover=nil
        end
    end
    GUI:Text(view.tally)
    local repeatable=view.repeatable
    if repeatable then
        U.cofferLabel=U.cofferLabel or ("Spend what's left on "..repeatable.name.." ("..repeatable.priceText.." MGC each)")
        local checked,changed=GUI:Checkbox(U.cofferLabel,s.coffers)
        if changed then s.coffers=checked; addon.SettingsChanged(); addon.Shop.refreshView() end
        tip("Once everything ticked above is bought, spend the rest of your MGC (minus what you keep) on these.")
    end
end

local function drawSettings()
    if not GUI:TreeNode("Settings##kbSettings") then return end
    local s,cap=addon.settings,addon.Lib.data.cap
    GUI:PushItemWidth(170)
    GUI:TextDisabled("Spending")
    slider("Shop at","spendAt",0,cap,"%d MGC","Visit the MGC trader once you have at least this much MGC.")
    slider("Keep","keepReserve",0,cap,"%d MGC","MGC that is never spent, kept back as a reserve.")
    GUI:TextDisabled("Typing")
    slider("Word delay","wordDelayMs",250,5000,"%d ms","Time between words, give or take 20% at random (in the duty, while the text box takes input).")
    local longer,longerChanged=GUI:Checkbox("Increase timer for longer sentences",s.longSentenceDelay)
    if longerChanged then s.longSentenceDelay=longer; addon.SettingsChanged() end
    tip("Wait twice the word delay, up to 5000 ms, before a long sentence (28 characters or more), such as the green ones by the party.")
    GUI:TextDisabled("Rest between games")
    range("Rest after each game","restMin","restMax",0,600,"%d s",
        "After every game, wait a random time between these two values before queuing again, so games don't start back to back.")
    slider("Long break every","breakEvery",0,50,s.breakEvery==0 and "Never" or "%d games",
        "About this many games apart (give or take 2), take a long break instead of the usual rest. 0 turns long breaks off.")
    range("Long break length","breakMin","breakMax",1,25,"%d min","A long break lasts a random time between these two values.")
    GUI:PopItemWidth()
    local checked,changed=GUI:Checkbox("Print the log to the console",s.consoleLog)
    if changed then s.consoleLog=checked; addon.SettingsChanged() end
    tip("Also print the addon's log lines to Minion's console.")
    GUI:TreePop()
end

local function drawLog()
    if not GUI:TreeNode("Log##kbLog") then return end
    local D=addon.Debug
    for i=math.max(1,D.count-14),D.count do GUI:TextWrapped(D.line(i)) end
    GUI:TreePop()
end

function U.draw()
    if not U.open then return end
    GUI:SetNextWindowSize(520,640,GUI.SetCond_FirstUseEver)
    U.visible,U.open=GUI:Begin("Keybound Brawler##KeyboundBrawler",U.open)
    if U.visible then
        if not U.padY then measure() end
        if not (addon.Lib.ready() and addon.Shop.view) then
            local missing=addon.Lib.missingText or ""
            if missing~=U.loadingFor then U.loadingFor=missing; U.loadingText="Loading FFXIVLib data: "..missing end
            GUI:TextWrapped(addon.Lib.available() and U.loadingText or "FFXIVLib is unavailable (Optifine disables it).")
        else
            drawStatus(); drawControls(); drawShop()
            GUI:Separator(); drawSettings(); drawLog()
        end
    end
    GUI:End()
end
