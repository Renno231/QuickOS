--slog
--[[
basically a "log" object that can be "written to" that then swaps to a screen and prints to it
]]
local term = require"term"
local component = require"component"
local screens = require"screens"

local sLog = {}
sLog.__index = sLog

function sLog.new(screenLabel, width, height)
    local newLog = {}
    newLog.screen = screenLabel
    newLog.width = width
    newLog.height = height
    newLog._internalBuffer = {}
    newLog.bufferMode = true

    return setmetatable(newLog, sLog)
end

function sLog:write(...)
    if screens.resolve(self.screen) then
        if self:bufferedMode() and #self._internalBuffer == 0 then
            return
        end
        local gotCurrent, previousScreen = screens.getCurrentScreen()
        local rX, rY = component.gpu.getResolution()
        local tX, tY = term.getCursor()
        if screens.bindTo(self.screen) then
            component.gpu.setResolution(self.width, self.height)
            if (self.tX and self.tY) then
                term.setCursor(self.tX, self.tY)
            else
                term.clear()
            end
            if self:bufferedMode() then
                repeat 
                    print(table.unpack(table.remove(self._internalBuffer, 1)))
                until #self._internalBuffer == 0
            else
                print(...)
            end
            self.tX, self.tY = term.getCursor()
            screens.bindTo(previousScreen)
            component.gpu.setResolution(rX, rY)
            term.setCursor(tX, tY)
        end
    end
end

function sLog:buffer(...) -- can work in a way to do foreground and background color options
    return table.insert(self._internalBuffer, {...})
end

function sLog:bufferedMode(val)
    local oldValue = self.bufferMode
    if type(val) == "boolean" then
        self.bufferMode = val
    end

    return oldValue
end
--test script
--log = sLog.new("test", 54, 50) event.listen("motion", function(_, sens, x,y,z, name) log:buffer(name, sens:sub(1,8),("%0.2f %0.2f %0.2f"):format(x,y,z)) end) event.timer(1, function() log:write() end, 200)
return sLog