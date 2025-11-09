--[[
  Braille Graphing Library for OpenComputers (Optimized Version 3)
  - Achieves 2x horizontal and 4x vertical resolution per character cell.

  Creates a high-resolution, scrolling graph using Braille characters.
  - Uses an optimized "flat array" for the data buffer to minimize memory.
  - Supports optional per-character foreground coloring without extra memory usage.
  - Automatically scrolls the graph content to the left when full.
]]
local graph = {}
local component = require("component")
local unicode = require("unicode")
local gpu = component.gpu
local math, table = math, table

-- Masks for FILLED columns (bottom-up)
local FILLED_LEFT_MASKS = {[0] = 0, [1] = 64, [2] = 68, [3] = 70, [4] = 71}
local FILLED_RIGHT_MASKS = {[0] = 0, [1] = 128, [2] = 160, [3] = 176, [4] = 184}

-- Masks for a SINGLE DOT in a column (0=bottom, 3=top)
local LINE_LEFT_MASKS = {[0] = 64, [1] = 4, [2] = 2, [3] = 1}
local LINE_RIGHT_MASKS = {[0] = 128, [1] = 32, [2] = 16, [3] = 8}

local function getBraille(leftMask, rightMask)
    return unicode.char(0x2800 + leftMask + rightMask)
end

local graph_mt = {__index = {}}

function graph_mt.__index:drawColumn(charIndex)
    local leftIndex = (charIndex - 1) * 2 + 1
    local rightIndex = leftIndex + 1

    local leftValue = self.buffer[leftIndex] or 0
    local rightValue = self.buffer[rightIndex] or 0

    local totalDotsLeft = math.floor((leftValue / self.maxValue) * self.pixelHeight + 0.5)
    totalDotsLeft = math.max(0, math.min(self.pixelHeight, totalDotsLeft))

    local totalDotsRight = math.floor((rightValue / self.maxValue) * self.pixelHeight + 0.5)
    totalDotsRight = math.max(0, math.min(self.pixelHeight, totalDotsRight))

    local columnChars = {}

    if self.filled then
        -- RENDER FILLED BAR CHART
        for i = 0, self.height - 1 do
            local dotsCoveredByLowerCells = (self.height - 1 - i) * 4
            local dotsLeftInCell = math.max(0, math.min(4, totalDotsLeft - dotsCoveredByLowerCells))
            local dotsRightInCell = math.max(0, math.min(4, totalDotsRight - dotsCoveredByLowerCells))
            table.insert(columnChars, getBraille(FILLED_LEFT_MASKS[dotsLeftInCell], FILLED_RIGHT_MASKS[dotsRightInCell]))
        end
    else
        -- RENDER LINE GRAPH
        for i = 0, self.height - 1 do
            local leftMask, rightMask = 0, 0
            local charRowDotStart = (self.height - 1 - i) * 4 + 1
            local charRowDotEnd = charRowDotStart + 3

            if totalDotsLeft >= charRowDotStart and totalDotsLeft <= charRowDotEnd then
                local dotInCharIndex = (totalDotsLeft - 1) % 4
                leftMask = LINE_LEFT_MASKS[dotInCharIndex]
            end

            if totalDotsRight >= charRowDotStart and totalDotsRight <= charRowDotEnd then
                local dotInCharIndex = (totalDotsRight - 1) % 4
                rightMask = LINE_RIGHT_MASKS[dotInCharIndex]
            end
            table.insert(columnChars, getBraille(leftMask, rightMask))
        end
    end

    gpu.set(self.x + charIndex - 1, self.y, table.concat(columnChars, ""), true)
end

function graph_mt.__index:scroll()
    gpu.copy(self.x + 1, self.y, self.width - 1, self.height, -1, 0)

    for i = 1, (self.width - 1) * 2 do self.buffer[i] = self.buffer[i + 2] end

    self.buffer[self.width * 2 - 1] = nil
    self.buffer[self.width * 2] = nil

    gpu.fill(self.x + self.width - 1, self.y, 1, self.height, " ")
end

--[[
  Adds a new data point to the graph.
  @param value (number): The data point to plot.
  @param color (number, optional): The hex color for this character-column.
                                   If provided, it will apply to both the left
                                   and right data points within this character.
]]
function graph_mt.__index:push(value, color)
    if self.cursor > self.width * 2 then
        self:scroll()
        self.cursor = self.width * 2 - 1
    end

    self.buffer[self.cursor] = value
    local charIndex = math.ceil(self.cursor / 2)
    local originalForeground

    if color then
        originalForeground = gpu.getForeground()
        gpu.setForeground(color)
    end
    self:drawColumn(charIndex)
    if color then gpu.setForeground(originalForeground) end

    self.cursor = self.cursor + 1
end

function graph_mt.__index:clear()
    gpu.fill(self.x, self.y, self.width, self.height, " ")
    self.buffer = {}
    self.cursor = 1
end

function graph.new(x, y, width, height, maxValue, filled)
    local self = setmetatable({}, graph_mt)
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.pixelHeight = height * 4
    self.maxValue = maxValue or self.pixelHeight
    self.filled = (filled ~= false)

    self:clear()

    return self
end

return graph