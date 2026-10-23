-- Memory-efficient Grid system with GPU buffer rendering and custom borders for OpenComputers
local Grid = {}
Grid.__index = Grid

function Grid.new()
    local self = setmetatable({}, Grid)
    self.data = {} -- Sparse 2D table: [row][col] = value
    self.maxRow = 0 -- Highest row index that has been set
    self.maxCol = 0 -- Highest column index that has been set

    -- Row-level formatting storage
    self.rowFormatters = {} -- [row] = { [colStr] = formatter }
    self.rowBackgroundColors = {} -- [row] = { [colStr] = color }
    self.rowForegroundColors = {} -- [row] = { [colStr] = color }
    self.rowAlignments = {} -- [row] = { [colStr] = alignment }

    -- Row heights and column widths (for visual formatting)
    self.rowHeights = {} -- [row] = height in characters
    self.colWidths = {} -- [col] = width in characters
    self.defaultRowHeight = 1 -- Default row height
    self.defaultColWidth = 10 -- Default column width

    -- Border settings
    self.rowBorders = {} -- [row] = border thickness below row
    self.colBorders = {} -- [col] = border thickness right of column
    self.defaultRowBorder = 0 -- Default row border thickness
    self.defaultColBorder = 0 -- Default column border thickness
    self._borderColor = 0xCCCCCC -- Default border color (light gray)

    -- Border set: 9 characters in order:
    -- 1: left vertical, 2: right vertical, 3: top horizontal, 4: bottom horizontal,
    -- 5: top-left corner, 6: top-right corner, 7: bottom-left corner, 8: bottom-right corner, 9: intersection
    self.borderSet = "││──┌┐└┘┼"
    self.borderChars = {
        leftVertical = "│",
        rightVertical = "│",
        topHorizontal = "─",
        bottomHorizontal = "─",
        topLeftCorner = "┌",
        topRightCorner = "┐",
        bottomLeftCorner = "└",
        bottomRightCorner = "┘",
        intersection = "┼"
    }

    -- Default formatting
    self.defaultFormat = {
        backgroundColor = 0x000000,
        foregroundColor = 0xFFFFFF,
        align = "left"
    }

    -- Position and drawing state
    self._x = 1 -- Internal X position
    self._y = 1 -- Internal Y position
    self.shouldDraw = false

    -- GPU and buffer management
    self.gpu = nil
    self.screen = nil
    self.buffer = nil
    self.bufferWidth = 0
    self.bufferHeight = 0

    return self
end

-- Set GPU and screen components
function Grid:setGPU(gpu, screen)
    self.gpu = gpu
    self.screen = screen
    -- Free existing buffer if any
    if self.buffer then
        self.gpu.freeBuffer(self.buffer)
        self.buffer = nil
    end
    self.bufferWidth = 0
    self.bufferHeight = 0
    self.shouldDraw = true
end

-- Free allocated buffer
function Grid:freeBuffer()
    if self.buffer and self.gpu then
        self.gpu.freeBuffer(self.buffer)
        self.buffer = nil
        self.bufferWidth = 0
        self.bufferHeight = 0
    end
end

-- Helper to convert coordinates to string key
local function coordKey(col) return tostring(col) end

-- Helper to get or create row table
local function getOrCreateRow(table, row)
    if not table[row] then table[row] = {} end
    return table[row]
end

-- Set a cell's value and update grid dimensions
function Grid:setCell(row, col, value)
    if row > self.maxRow then self.maxRow = row end
    if col > self.maxCol then self.maxCol = col end

    if not self.data[row] then self.data[row] = {} end

    self.data[row][col] = value
    self.shouldDraw = true
end

-- Get a cell's value (returns nil if cell doesn't exist)
function Grid:getCell(row, col)
    if self.data[row] then return self.data[row][col] end
    return nil
end

-- Get/set background color (supports hex values or callbacks)
function Grid:backgroundColor(row, col, newBg)
    if newBg ~= nil then
        local rowTable = getOrCreateRow(self.rowBackgroundColors, row)
        rowTable[coordKey(col)] = newBg
        self.shouldDraw = true
        return self
    else
        if self.rowBackgroundColors[row] then
            return self.rowBackgroundColors[row][coordKey(col)]
        end
        return self.defaultFormat.backgroundColor
    end
end

-- Get/set foreground color (supports hex values or callbacks)
function Grid:foregroundColor(row, col, newFg)
    if newFg ~= nil then
        local rowTable = getOrCreateRow(self.rowForegroundColors, row)
        rowTable[coordKey(col)] = newFg
        self.shouldDraw = true
        return self
    else
        if self.rowForegroundColors[row] then
            return self.rowForegroundColors[row][coordKey(col)]
        end
        return self.defaultFormat.foregroundColor
    end
end

-- Get/set text alignment (supports values or callbacks)
function Grid:align(row, col, newAlign)
    if newAlign ~= nil then
        local rowTable = getOrCreateRow(self.rowAlignments, row)
        rowTable[coordKey(col)] = newAlign
        self.shouldDraw = true
        return self
    else
        if self.rowAlignments[row] then
            return self.rowAlignments[row][coordKey(col)]
        end
        return self.defaultFormat.align
    end
end

-- Get/set formatter (supports string format or callback function)
function Grid:formatter(row, col, newFormatter)
    if newFormatter ~= nil then
        local rowTable = getOrCreateRow(self.rowFormatters, row)
        rowTable[coordKey(col)] = newFormatter
        self.shouldDraw = true
        return self
    else
        if self.rowFormatters[row] then
            return self.rowFormatters[row][coordKey(col)]
        end
        return nil
    end
end

-- Get/set row height
function Grid:rowHeight(row, newHeight)
    if newHeight ~= nil then
        self.rowHeights[row] = newHeight
        self.shouldDraw = true
        return self
    else
        return self.rowHeights[row] or self.defaultRowHeight
    end
end

-- Get/set column width
function Grid:colWidth(col, newWidth)
    if newWidth ~= nil then
        self.colWidths[col] = newWidth
        self.shouldDraw = true
        return self
    else
        return self.colWidths[col] or self.defaultColWidth
    end
end

-- Get/set row border thickness
function Grid:rowBorder(row, newThickness)
    if newThickness ~= nil then
        self.rowBorders[row] = newThickness
        self.shouldDraw = true
        return self
    else
        return self.rowBorders[row] or self.defaultRowBorder
    end
end

-- Get/set column border thickness
function Grid:colBorder(col, newThickness)
    if newThickness ~= nil then
        self.colBorders[col] = newThickness
        self.shouldDraw = true
        return self
    else
        return self.colBorders[col] or self.defaultColBorder
    end
end

-- Get/set border color
function Grid:borderColor(newColor)
    if newColor ~= nil then
        self._borderColor = newColor
        self.shouldDraw = true
        return self
    else
        return self._borderColor
    end
end

-- Get/set border set (9 characters: left, right, top, bottom, top-left, top-right, bottom-left, bottom-right, intersection)
function Grid:borderSet(newSet)
    if newSet ~= nil then
        if #newSet ~= 9 then
            error("Border set must be exactly 9 characters")
        end
        self.borderSet = newSet
        self.borderChars = {
            leftVertical = newSet:sub(1, 1),
            rightVertical = newSet:sub(2, 2),
            topHorizontal = newSet:sub(3, 3),
            bottomHorizontal = newSet:sub(4, 4),
            topLeftCorner = newSet:sub(5, 5),
            topRightCorner = newSet:sub(6, 6),
            bottomLeftCorner = newSet:sub(7, 7),
            bottomRightCorner = newSet:sub(8, 8),
            intersection = newSet:sub(9, 9)
        }
        self.shouldDraw = true
        return self
    else
        return self.borderSet
    end
end

-- Safely resolve a formatting property (handles callbacks)
function Grid:_resolveProperty(row, col, propertyTable, defaultValue)
    if propertyTable[row] then
        local rawValue = propertyTable[row][coordKey(col)]
        if rawValue ~= nil then
            if type(rawValue) == "function" then
                local cellValue = self:getCell(row, col)
                local success, result = pcall(rawValue, cellValue)
                if success then
                    return result
                else
                    print("Error in property callback for (" .. row .. "," ..
                              col .. "): " .. result)
                    return defaultValue
                end
            else
                return rawValue
            end
        end
    end
    return defaultValue
end

-- Get the formatted value of a cell (applies formatter if present)
function Grid:getFormattedValue(row, col)
    local rawValue = self:getCell(row, col)
    if rawValue == nil then return "" end

    local formatter = self:_resolveProperty(row, col, self.rowFormatters, nil)
    if formatter == nil then return tostring(rawValue) end

    -- Handle string formatter
    if type(formatter) == "string" then
        local success, result = pcall(string.format, formatter, rawValue)
        if success then
            return result
        else
            print("Error formatting cell (" .. row .. "," .. col .. "): " ..
                      result)
            return tostring(rawValue)
        end
    end

    -- Handle function formatter
    if type(formatter) == "function" then
        local success, result = pcall(formatter, rawValue)
        if success then
            return tostring(result)
        else
            print(
                "Error in formatter function for cell (" .. row .. "," .. col ..
                    "): " .. result)
            return tostring(rawValue)
        end
    end

    -- Fallback to raw value
    return tostring(rawValue)
end

-- Get all display properties for a cell
function Grid:getDisplayProperties(row, col)
    return {
        value = self:getFormattedValue(row, col),
        backgroundColor = self:_resolveProperty(row, col,
                                                self.rowBackgroundColors,
                                                self.defaultFormat
                                                    .backgroundColor),
        foregroundColor = self:_resolveProperty(row, col,
                                                self.rowForegroundColors,
                                                self.defaultFormat
                                                    .foregroundColor),
        align = self:_resolveProperty(row, col, self.rowAlignments,
                                      self.defaultFormat.align)
    }
end

-- Get/set grid X position
function Grid:x(newX)
    if newX ~= nil then
        self._x = newX
        self.shouldDraw = true
        return self
    else
        return self._x
    end
end

-- Get/set grid Y position
function Grid:y(newY)
    if newY ~= nil then
        self._y = newY
        self.shouldDraw = true
        return self
    else
        return self._y
    end
end

-- Get current grid dimensions
function Grid:getDimensions() return self.maxRow, self.maxCol end

-- Check if a cell exists
function Grid:cellExists(row, col)
    return self.data[row] ~= nil and self.data[row][col] ~= nil
end

-- Draw function using GPU buffer
function Grid:draw()
    if not self.shouldDraw then return end
    if not self.gpu or not self.screen then error("GPU and screen not set") end
    
    -- Get screen resolution
    local screenWidth, screenHeight = self.gpu.getResolution()
    
    -- Calculate visible area
    local startRow = math.max(1, math.ceil(2 - self._y))
    local endRow = math.min(self.maxRow, screenHeight - self._y + 1)
    local startCol = math.max(1, math.ceil(2 - self._x))
    local endCol = math.min(self.maxCol, screenWidth - self._x + 1)
    
    -- If there's nothing to draw, reset flag and return
    if endRow < startRow or endCol < startCol then
        self.shouldDraw = false
        return
    end
    
    -- Calculate total buffer dimensions including borders
    local totalWidth = 0
    for col = startCol, endCol do
        totalWidth = totalWidth + self:colWidth(col) + self:colBorder(col)
    end
    local totalHeight = 0
    for row = startRow, endRow do
        totalHeight = totalHeight + self:rowHeight(row) + self:rowBorder(row)
    end
    
    -- Check if dimensions exceed reasonable limits
    -- local maxBufferWidth = 80
    -- local maxBufferHeight = 30
    -- if totalWidth > maxBufferWidth or totalHeight > maxBufferHeight then
    --     print("Warning: Grid dimensions too large for buffer (", totalWidth, "x", totalHeight, ")")
    --     self.shouldDraw = false
    --     return
    -- end
    
    -- Check if we need to allocate or resize the buffer
    if not self.buffer or self.bufferWidth ~= totalWidth or self.bufferHeight ~= totalHeight then
        -- Free existing buffer if any
        if self.buffer then self.gpu.freeBuffer(self.buffer) end
        -- Allocate new buffer
        self.buffer = self.gpu.allocateBuffer(totalWidth, totalHeight)
        if not self.buffer then 
            print("Error: Failed to allocate buffer of size", totalWidth, "x", totalHeight)
            self.shouldDraw = false
            return
        end
        self.bufferWidth = totalWidth
        self.bufferHeight = totalHeight
    end

    -- Set active buffer to our buffer
    local oldBuffer = self.gpu.setActiveBuffer(self.buffer)

    -- Clear the buffer to default background
    self.gpu.setBackground(self.defaultFormat.backgroundColor)
    self.gpu.fill(1, 1, totalWidth, totalHeight, " ")

    -- Calculate starting positions for each row and column
    local rowPositions = {}
    local currentPos = 1
    for row = startRow, endRow do
        rowPositions[row] = currentPos
        currentPos = currentPos + self:rowHeight(row) + self:rowBorder(row)
    end

    local colPositions = {}
    currentPos = 1
    for col = startCol, endCol do
        colPositions[col] = currentPos
        currentPos = currentPos + self:colWidth(col) + self:colBorder(col)
    end

    -- Draw visible cells
    for row = startRow, endRow do
        for col = startCol, endCol do
            if self:cellExists(row, col) then
                local props = self:getDisplayProperties(row, col)
                -- Set colors for this cell
                self.gpu.setBackground(props.backgroundColor)
                self.gpu.setForeground(props.foregroundColor)

                -- Get the formatted value
                local text = props.value
                local colWidth = self:colWidth(col)
                local rowHeight = self:rowHeight(row)

                -- Truncate text to column width
                if #text > colWidth then
                    text = text:sub(1, colWidth)
                end

                -- Calculate position in the buffer
                local bufferRow = rowPositions[row]
                local bufferCol = colPositions[col]

                -- Apply alignment
                if props.align == "center" then
                    bufferCol = bufferCol + math.floor((colWidth - #text) / 2)
                elseif props.align == "right" then
                    bufferCol = bufferCol + (colWidth - #text)
                end

                -- Draw the text at the buffer position
                self.gpu.set(bufferCol, bufferRow, text)
            end
        end
    end

    -- Draw borders using border set characters
    self.gpu.setForeground(self._borderColor)
    self.gpu.setBackground(0x000000) -- Black text for borders

    -- Step 1: Draw horizontal borders
    for row = startRow, endRow do
        local borderThickness = self:rowBorder(row)
        if borderThickness > 0 then
            local y = rowPositions[row] + self:rowHeight(row)
            for dy = 0, borderThickness - 1 do
                -- Draw horizontal line segments between vertical borders
                local x = colPositions[startCol]
                for col = startCol, endCol do
                    local colWidth = self:colWidth(col)
                    -- Check if we're at the last column or if there's no vertical border after this column
                    if col == endCol or self:colBorder(col) == 0 then
                        -- Draw the full width of this column
                        self.gpu.set(x, y + dy, string.rep(
                                         self.borderChars.bottomHorizontal,
                                         colWidth))
                    else
                        -- Draw up to the vertical border
                        self.gpu.set(x, y + dy, string.rep(
                                         self.borderChars.bottomHorizontal,
                                         colWidth))
                    end
                    x = x + colWidth + self:colBorder(col)
                end
            end
        end
    end

    -- Step 2: Draw vertical borders
    for col = startCol, endCol do
        local borderThickness = self:colBorder(col)
        if borderThickness > 0 then
            local x = colPositions[col] + self:colWidth(col)
            for dx = 0, borderThickness - 1 do
                -- Draw vertical line segments between horizontal borders
                local y = rowPositions[startRow]
                for row = startRow, endRow do
                    local rowHeight = self:rowHeight(row)
                    -- Check if we're at the last row or if there's no horizontal border after this row
                    if row == endRow or self:rowBorder(row) == 0 then
                        -- Draw the full height of this row
                        for dy = 0, rowHeight - 1 do
                            self.gpu.set(x + dx, y + dy,
                                         self.borderChars.rightVertical)
                        end
                    else
                        -- Draw up to the horizontal border
                        for dy = 0, rowHeight - 1 do
                            self.gpu.set(x + dx, y + dy,
                                         self.borderChars.rightVertical)
                        end
                    end
                    y = y + rowHeight + self:rowBorder(row)
                end
            end
        end
    end
    
    -- Step 3: Draw corners (only at the actual corners of the grid)
    for row = startRow, endRow do
        for col = startCol, endCol do
            local x = colPositions[col] + self:colWidth(col)
            local y = rowPositions[row] + self:rowHeight(row)
            
            -- Only draw if both row and column have borders
            if self:rowBorder(row) > 0 and self:colBorder(col) > 0 then
                -- Only draw corner characters at the four corners of the entire grid
                if (row == startRow and col == startCol) then
                    -- Top-left corner of the grid (at the top-left of the grid area)
                    self.gpu.set(colPositions[startCol] - 1, rowPositions[startRow] - 1, 
                                self.borderChars.topLeftCorner)
                elseif (row == startRow and col == endCol) then
                    -- Top-right corner of the grid
                    self.gpu.set(x, rowPositions[startRow] - 1, 
                                self.borderChars.topRightCorner)
                elseif (row == endRow and col == startCol) then
                    -- Bottom-left corner of the grid
                    self.gpu.set(colPositions[startCol] - 1, y, 
                                self.borderChars.bottomLeftCorner)
                elseif (row == endRow and col == endCol) then
                    -- Bottom-right corner of the grid
                    self.gpu.set(x, y, 
                                self.borderChars.bottomRightCorner)
                end
            end
        end
    end

    -- Step 4: Draw intersections (where horizontal and vertical borders meet)
    for row = startRow, endRow do
        for col = startCol, endCol do
            local x = colPositions[col] + self:colWidth(col)
            local y = rowPositions[row] + self:rowHeight(row)
            
            -- Only draw if both row and column have borders
            if self:rowBorder(row) > 0 and self:colBorder(col) > 0 then
                -- Skip the corners we already drew
                if not ((row == startRow and col == endCol) or
                        (row == endRow and col == startCol) or
                        (row == endRow and col == endCol)) then
                    -- Draw the intersection character
                    self.gpu.set(x, y, self.borderChars.intersection)
                end
            end
        end
    end
    -- Calculate screen position for the buffer
    local screenX = self._x
    local screenY = self._y

    -- Switch to screen buffer and copy our buffer to it
    self.gpu.setActiveBuffer(0)
    self.gpu.bitblt(0, screenX, screenY, totalWidth, totalHeight, self.buffer,
                    1, 1)

    -- Restore the old active buffer
    self.gpu.setActiveBuffer(oldBuffer)

    -- Reset the draw flag
    self.shouldDraw = false
end

-- Iterate through all existing cells (sparse iteration)
function Grid:iterate()
    local rows = {}
    for row in pairs(self.data) do table.insert(rows, row) end
    table.sort(rows)

    local rowIdx = 0
    local colKeys = {}
    local colIdx = 0

    return function()
        -- Move to next row if needed
        if colIdx >= #colKeys then
            rowIdx = rowIdx + 1
            if rowIdx > #rows then
                return nil -- End of iteration
            end

            local row = rows[rowIdx]
            colKeys = {}
            for col in pairs(self.data[row]) do
                table.insert(colKeys, col)
            end
            table.sort(colKeys)
            colIdx = 0
        end

        colIdx = colIdx + 1
        local row = rows[rowIdx]
        local col = colKeys[colIdx]
        return row, col, self.data[row][col]
    end
end

-- Cell class for OOP interface to grid cells
local Cell = {}
Cell.__index = Cell

function Cell.new(grid, row, col)
    local self = setmetatable({}, Cell)
    self.grid = grid
    self.row = row
    self.col = col
    return self
end

-- Get cell value
function Cell:getValue() return self.grid:getCell(self.row, self.col) end

-- Set cell value
function Cell:setValue(value) self.grid:setCell(self.row, self.col, value) end

-- Check if cell exists in grid
function Cell:exists() return self.grid:cellExists(self.row, self.col) end

-- Get/set background color (supports hex values or callbacks)
function Cell:backgroundColor(newBg)
    if newBg ~= nil then
        self.grid:backgroundColor(self.row, self.col, newBg)
        return self
    else
        return self.grid:backgroundColor(self.row, self.col)
    end
end

-- Get/set foreground color (supports hex values or callbacks)
function Cell:foregroundColor(newFg)
    if newFg ~= nil then
        self.grid:foregroundColor(self.row, self.col, newFg)
        return self
    else
        return self.grid:foregroundColor(self.row, self.col)
    end
end

-- Get/set text alignment (supports values or callbacks)
function Cell:align(newAlign)
    if newAlign ~= nil then
        self.grid:align(self.row, self.col, newAlign)
        return self
    else
        return self.grid:align(self.row, self.col)
    end
end

-- Get/set formatter (supports string format or callback function)
function Cell:formatter(newFormatter)
    if newFormatter ~= nil then
        self.grid:formatter(self.row, self.col, newFormatter)
        return self
    else
        return self.grid:formatter(self.row, self.col)
    end
end

-- Get the formatted value of a cell (applies formatter if present)
function Cell:getFormattedValue()
    return self.grid:getFormattedValue(self.row, self.col)
end

-- Get all display properties for a cell
function Cell:getDisplayProperties()
    return self.grid:getDisplayProperties(self.row, self.col)
end

-- Create a Cell object for a specific position
function Grid:getCellObject(row, col) return Cell.new(self, row, col) end

-- Example usage:
local component = require("component")
local gpu = component.gpu
local screen = component.screen
local term = require("term")

-- Clear the terminal
term.clear()

-- Create a new grid
local myGrid = Grid.new()

-- Set GPU and screen
myGrid:setGPU(gpu, screen)

-- Set grid position
myGrid:x(5)
myGrid:y(3)

-- Set some cells with full words
myGrid:setCell(1, 1, "Name")
myGrid:setCell(1, 2, "Type")
myGrid:setCell(1, 3, "Count")
myGrid:setCell(1, 4, "Status")

myGrid:setCell(2, 1, "Iron")
myGrid:setCell(2, 2, "Ore")
myGrid:setCell(2, 3, "64")
myGrid:setCell(2, 4, "Full")

myGrid:setCell(3, 1, "Gold")
myGrid:setCell(3, 2, "Ingot")
myGrid:setCell(3, 3, "32")
myGrid:setCell(3, 4, "Available")

myGrid:setCell(4, 1, "Diamond")
myGrid:setCell(4, 2, "Gem")
myGrid:setCell(4, 3, "16")
myGrid:setCell(4, 4, "Available")

-- Set column widths for better visual formatting
myGrid:colWidth(1, 12) -- Name column
myGrid:colWidth(2, 10) -- Type column
myGrid:colWidth(3, 12) -- Count column
myGrid:colWidth(4, 12) -- Status column

-- Set row heights for header
-- myGrid:rowHeight(1, 2) -- Header row is taller

-- Set borders
myGrid:rowBorder(1, 1) -- Border below header row
myGrid:rowBorder(2, 1) -- Border below row 2
myGrid:rowBorder(3, 1) -- Border below row 3

myGrid:colBorder(1, 1) -- Border right of column 1
myGrid:colBorder(2, 1) -- Border right of column 2
myGrid:colBorder(3, 1) -- Border right of column 3

-- Set border color
myGrid:borderColor(0x0080FF) -- Blue borders

-- Use default border set (already set in constructor)
-- myGrid:borderSet("││──┌┐└┘┼")

-- Set formatting with static values
myGrid:backgroundColor(1, 1, 0x000080) -- Navy background for header
myGrid:backgroundColor(1, 2, 0x000080)
myGrid:backgroundColor(1, 3, 0x000080)
myGrid:backgroundColor(1, 4, 0x000080)

myGrid:foregroundColor(1, 1, 0x00FFFF) -- Cyan text for header
myGrid:foregroundColor(1, 2, 0x00FFFF)
myGrid:foregroundColor(1, 3, 0x00FFFF)
myGrid:foregroundColor(1, 4, 0x00FFFF)

myGrid:align(1, 1, "center")
myGrid:align(1, 2, "center")
myGrid:align(1, 3, "center")
myGrid:align(1, 4, "center")

-- Set formatting with callbacks
myGrid:foregroundColor(2, 4, function(value)
    if value == "Full" then
        return 0xFF0000 -- Red for "Full"
    else
        return 0x00FF00 -- Green otherwise
    end
end)

myGrid:foregroundColor(3, 4, function(value)
    if value == "Available" then
        return 0x00FF00 -- Green for "Available"
    else
        return 0xFFFFFF -- White otherwise
    end
end)

-- Using Cell objects
local cell = myGrid:getCellObject(3, 3)
cell:align("center")
cell:backgroundColor(function(value)
    -- Make background color depend on numeric value
    local num = tonumber(value) or 0
    if num > 50 then
        return 0x008000 -- Dark green for high values
    else
        return 0x800000 -- Dark red for low values
    end
end)

-- Set formatters
myGrid:formatter(2, 3, "%s units") -- String formatter
myGrid:formatter(3, 3, function(value)
    local num = tonumber(value) or 0
    if num > 50 then
        return ("%s (high)"):format(value)
    else
        return ("%s (low)"):format(value)
    end
end)

myGrid:formatter(4, 3, "%s in stock")

-- Draw the grid
myGrid:draw()

-- Change a value and redraw
myGrid:setCell(2, 3, "128")
myGrid:draw()
os.sleep(1)
for i=1,10 do
    myGrid:colWidth(3, 12+i*3) -- Count column
    myGrid:rowHeight(3, 1+math.floor(math.abs(math.cos(i))*4))
    myGrid:draw()
end

-- Wait 5 seconds before freeing the buffer
os.sleep(3)

-- Free the buffer when done
myGrid:freeBuffer()
