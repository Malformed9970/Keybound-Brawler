KeyboundBrawler = KeyboundBrawler or {}
local addon=KeyboundBrawler
addon.Debug=addon.Debug or {}
local D=addon.Debug
D.size=200
D.lines=D.lines or {}
D.count=D.count or 0

-- Keeps the last 200 lines, with the time, in a ring for the window's Log
-- (D.line). Prints "[KeyboundBrawler] message" to Minion's console when show
-- is set (purchases, finished games, rests, stops and pauses) or console
-- logging is on.
function D.log(message,show)
    message=tostring(message)
    D.count=D.count+1
    D.lines[(D.count-1)%D.size+1]=os.date("%H:%M:%S").." "..message
    if show or (addon.settings and addon.settings.consoleLog) then d("[KeyboundBrawler] "..message) end
end

-- Line number i (1 = the first ever logged); only the last 200 are kept.
function D.line(i) return D.lines[(i-1)%D.size+1] end
