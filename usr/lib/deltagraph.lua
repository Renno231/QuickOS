--[[
  DeltaGraph Library
]]
local graph = {}
local component = require("component")
local unicode = require("unicode")
local gpu = component.gpu
local math, string = math, string

-- Masks for drawing a bar from the BOTTOM of a character cell UPWARDS.
local FILLED_MASKS = {[0] = 0, [1] = 192, [2] = 228, [3] = 246, [4] = 255}

local graph_mt = {__index = {}}

-- Generates a string for a SOLID bar from the bottom (dot 0) up to a given height.
function graph_mt.__index:_getBarString(dots, endDots)
    if (not endDots and dots <= 0) or (endDots and dots >= endDots) then
        return nil, nil
    end

    local topDot = (endDots or dots) - 1
    local topCharRow = math.floor(topDot / 4)
    local screenY = self.y + self.height - 1 - topCharRow

    local topperChar = unicode.char(0x2800 + FILLED_MASKS[(topDot % 4) + 1])

    local numStemChars = endDots and math.floor((endDots - dots - 1) / 4) or topCharRow
    local stem = string.rep(" ", numStemChars)

    return topperChar .. stem, screenY
end

function graph_mt.__index:update(barIndex, newValue)
    if barIndex < 1 or barIndex > self.numBars then
        return false, "barIndex out of bounds (bar not found)"
    end

    local previousValue = self.values[barIndex] or 0
    if newValue == previousValue then return end

    self.values[barIndex] = newValue
    local x = self.x + barIndex - 1

    local currentDots = math.floor((newValue / self.maxValue) * self.pixelHeight + 0.5)
    local previousDots = math.floor((previousValue / self.maxValue) * self.pixelHeight + 0.5)

    if currentDots == previousDots then return end
    local bFore,bBack = gpu.getForeground(), gpu.getBackground()
    if currentDots > previousDots then
        -- Step 1: Draw the new, taller bar in solid white. This sets the final shape
        local whiteStr, whiteY = self:_getBarString(currentDots)
        if whiteStr then
            gpu.setBackground(self.BASE_COLOR)
            gpu.set(x, whiteY, whiteStr, true)
        else
            -- If the new bar is somehow zero (shouldn't happen in gain), clear the column.
            gpu.setBackground(self.BG_COLOR)
            gpu.fill(x, self.y, 1, self.height, " ")
        end
        -- Step 2: Draw a green "ghost" segment ONLY for the delta. This uses setForeground
        local greenStr, greenY = self:_getBarString(previousDots, currentDots)
        if greenStr then
            gpu.setForeground(self.GAIN_COLOR)
            gpu.setBackground(self.BG_COLOR) -- Set background to white to blend with the bar
            gpu.set(x, greenY, greenStr, true)
        end
    else
        -- Step 1: Draw the new, shorter white bar.
        local whiteStr, whiteY = self:_getBarString(currentDots)
        if whiteStr then
            gpu.setBackground(self.BASE_COLOR)
            gpu.set(x, whiteY, whiteStr, true)
        end

        -- Step 2: Erase everything above the new bar.
        local clearY, clearHeight
        if currentDots > 0 then
            local topCharRow = math.floor((currentDots - 1) / 4)
            clearY = self.y
            clearHeight = self.height - 1 - topCharRow
        else
            clearY = self.y
            clearHeight = self.height
        end

        if clearHeight > 0 then
            gpu.setBackground(self.BG_COLOR)
            gpu.fill(x, clearY, 1, clearHeight, " ")
        end

        -- Step 3: Draw the red ghost flash in the now-cleared area.
        local redStr, redY = self:_getBarString(currentDots, previousDots)
        if redStr then
            gpu.setForeground(self.LOSS_COLOR)
            gpu.setBackground(self.BG_COLOR)
            gpu.set(x, redY, redStr, true)
        end
    end
    
    gpu.setForeground(bFore)
    gpu.setBackground(bBack)
end

function graph.new(x, y, height, numBars, maxValue)
    local self = setmetatable({}, graph_mt)
    self.x, self.y, self.height, self.numBars = x, y, height, numBars
    self.pixelHeight = height * 4
    self.maxValue = maxValue or self.pixelHeight
    self.values = {}
    
    self.GAIN_COLOR = 0x28A745 -- Green
    self.LOSS_COLOR = 0xDC3545 -- Red
    self.BASE_COLOR = 0xFFFFFF -- White
    self.BG_COLOR = 0x000000 -- Black
    gpu.setBackground(self.BG_COLOR)
    gpu.fill(x, y, numBars, height, " ")
    return self
end

return graph