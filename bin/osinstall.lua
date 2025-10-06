local w, h
local component = require('component')
local screen = component.screen
local gpu = component.gpu
local sFG, sBG, gSet
local white = 0xffffff
if gpu then
    sFG, sBG, gSet = gpu.setForeground, gpu.setBackground, gpu.set
    if not gpu.getScreen() then
        gpu.bind(screen)
    end
    w, h = gpu.maxResolution()
    sBG(0x181818)
    sFG(white)
    gpu.fill(1, 1, w, h, " ")
end

local logoY = 3
local logoX = (w-61)/2+1
sFG(0x00ED8A)
local isT1 = h == 16
if not isT1 then
    gSet((w-56)/2+1, logoY-2, "(Use arrow keys to navigate, Enter to activate, Q to quit)")
    gSet(logoX, logoY+0, " ██████╗  ██╗   ██╗  ██╗  ██████╗ ██╗  ██╗  ██████╗  ███████╗")
    gSet(logoX, logoY+1, "██╔═══██╗ ██║   ██║  ██║ ██╔════╝ ██║ ██╔╝ ██╔═══██╗ ██╔════╝")
    gSet(logoX, logoY+2, "██║   ██║ ██║   ██║  ██║ ██║      █████╔╝  ██║   ██║ ███████╗")
    gSet(logoX, logoY+3, "██║   ██║ ██║   ██║  ██║ ██║      ██╔═██╗  ██║   ██║ ╚════██║")
    gSet(logoX, logoY+4, "╚██████╔╝ ████████║  ██║  ██████╗ ██║ ╚██╗ ╚██████╔╝ ███████║")
    gSet(logoX, logoY+5, " ╚════██╗ ╚═══════╝  ╚═╝  ╚═════╝ ╚═╝  ╚═╝  ╚═════╝  ╚══════╝")
else
    logoY = -7
end
sFG(white)
gSet(logoX, logoY+7, "            Installation Wizard 1.0.0 made by Renno231       ")

local computer = require("computer")
local event = require("event")
local fs = require("filesystem")
local internet = require("internet")
local keys = require("keyboard").keys
local unicode = require("unicode")

-- Constants
local cdn = "https://raw.githubusercontent.com/Renno231/QuickOS/main"
local isQuickOS = string.find(_G._OSVERSION, "QuickOS")
local overwriteDest, web = true

local qmenu, result = pcall(require, "qmenu")
if result then
    qmenu = result --if true, it's the 2nd arg returned
else
    if component.isAvailable("internet") then
        local result, response = pcall(internet.request, cdn .. "/lib/qmenu.lua", nil, {["User-Agent"] = "Wget/OpenComputers"})
        if result then
            local qmenu_mini = ""
            for chunk in response do
                qmenu_mini = qmenu_mini .. chunk
            end
            -- local env = {require = require}
            qmenu = load(qmenu_mini,"qmenu_fallback", "t", setmetatable({require=require}, {__index = _G}))()
        else
            error("Failed to download \"" .. cdn .. "/lib/qmenu.lua" .. "\"!")
        end
    else
        error("qmenu library not found and internet source is unavailable")
    end
end

-- State variables
local running = true
local state = "drive_selection"
local selectedDrive = nil
local selectedFiles = {}

-- Helper functions
local function clearScreenArea(y, height)
    sBG(0x000000)
    y=y or logoY+8
    gpu.fill(1, y, w, (height or h), " ")
end

local function status(str, offset, fg, bg)
    local x = (w - unicode.len(str)) / 2 + 1
    local y = logoY + 9 + (offset or 0)
    if fg == nil then fg = white end
    local bfg, bbg = gpu.getForeground(), gpu.getBackground()
    sFG(fg)
    sBG(bg or 0)
    gpu.fill(1, y, w, 1, " ")
    gSet(x, y, str)
    sFG(bfg)
    sBG(bbg)
end

local function quit(reason)
    running = false
    state = "cancelled"
    require("term").clear()
    sBG(0x000000)
    gpu.fill(1, 1, w, h, " ")
    io.write(reason)
    os.exit()
end

-- Helper function to link menu options for navigation
local function linkMenuOptions(options)
    for i = 1, #options do
        if i > 1 then
            options[i]:bind(keys.up, options[i - 1].name)
        end
        if i < #options then
            options[i]:bind(keys.down, options[i + 1].name)
        end
    end
end

-- Helper function to draw progress bar
local function drawProgressBar(progress, total, color)
    local progressX = (w - 50) / 2 + 1
    local perItem = 50 / total
    sBG(0x3D3D3D)
    local fill = math.ceil(perItem * progress)
    gpu.fill(progressX + fill, logoY + 10, 50 - fill, 1, " ")
    sBG(color or 0x00FF00)
    gpu.fill(progressX, logoY + 10, fill, 1, " ")
    sBG(0x181818)
end

-- Helper function to process file (download or copy)
local function processFile(srcPath, destPath, isDownload, replaceExisting)
    if replaceExisting == false and fs.exists(destPath) then
        return true, "file already exists at destination"
    end
    if isDownload then
        local f, reason = io.open(destPath, "w")
        if f then
            local url = cdn .. srcPath
            local result, response = pcall(internet.request, url, nil, {
                ["User-Agent"] = "Wget/OpenComputers"
            })
            if result then
                for chunk in response do
                    string.gsub(chunk, "\r\n", "\n")
                    f:write(chunk)
                end
                f:close()
                return true
            else
                return false, "Failed to download \"" .. cdn .. srcPath .. "\"!"
            end
        else
            return false, "Failed to open file for writing"
        end
    else
        return pcall(fs.copy, srcPath, destPath)
    end
end

-- Create confirmation menu with horizontal Yes/No buttons
local function createConfirmationMenu(onYes, onNo, defaultToNo)
    local menu = qmenu.create()
    local buttonY = logoY + 11

    local yOpt = menu:addOption("yes", (w - 10) / 2 + 5, buttonY, "Yes")
    local nOpt = menu:addOption("no", (w - 10) / 2 - 1, buttonY, "No")
    if defaultToNo then
        menu:setSelected("no")
    end
    yOpt:bind(keys.right, "no")
    yOpt:bind(keys.left, "no")
    yOpt:bind(keys.down, "no")
    yOpt:bind(keys.up, "no")
    nOpt:bind(keys.left, "yes")
    nOpt:bind(keys.right, "yes")
    nOpt:bind(keys.up, "yes")
    nOpt:bind(keys.down, "yes")

    yOpt:onActivate(onYes)
    nOpt:onActivate(onNo)

    return menu
end

-- Helper function to show confirmation dialog
local function showConfirmationDialog(title, message, onYes, onNo, defaultToNo)
    clearScreenArea()
    status(title)
    if message then status(message, 1, 0xcc0000) end

    local menu = createConfirmationMenu(onYes, onNo, defaultToNo)
    menu:draw(true)
    local initState = state
    while state == initState do
        local _, _, _, key = event.pull("key_down")
        if key == keys.q then
            onNo()
        else
            menu:handleEvent(key)
            menu:draw()
        end
    end
    return true
end

-- Find available drives
local function findDrives()
    local comps = component.list("filesystem")
    local devices = {}
    local targets = {}
    local found = 0

    for dev, path in fs.mounts() do
        if comps[dev.address] then
            local known = devices[dev]
            devices[dev] = known and #known < #path and known or path
        end
    end

    devices[fs.get("/dev")] = nil
    devices[fs.get("/tmp")] = nil

    for dev, path in pairs(devices) do
        if path ~= nil and not dev.isReadOnly() then
            table.insert(targets, {dev = dev, path = path})
            found = found + 1
        end
    end

    if found == 0 then
        quit("Error: Failed to find any non-readonly drives!")
        return nil
    end

    return targets
end

-- Create drive selection menu
local function createDriveSelectionMenu(drives)
    clearScreenArea()
    local menu = qmenu.create()
    local startY = logoY + 11
    local options = {}
    table.sort(drives,function(a) return a.path == "/" end)
    for i, drive in ipairs(drives) do
        local label = drive.dev.getLabel() or "No Label"
        local path = drive.path
        local desc = label .. " (/mnt/" .. drive.dev.address:sub(1,3) .. ")"

        if path == "/" then desc = "Update your local installation" end

        local optionName = "drive" .. i
        local option = menu:addOption(optionName, (w - unicode.len(desc)) / 2 + 1, startY + (i - 1) * 1, desc)
        option.drive = drive
        table.insert(options, option)
    end

    local cancelOption = menu:addOption("cancel", (w - unicode.len("Cancel Installation")) / 2 + 1, startY + #drives * 1 + 1, "Cancel Installation")
    table.insert(options, cancelOption)

    linkMenuOptions(options)

    cancelOption:onActivate(function() quit("Installation cancelled by user") end)
    for _, option in ipairs(options) do
        if option.drive then
            option:onActivate(function()
                selectedDrive = option.drive
                if selectedDrive.path == "/" then
                    -- Update installation
                    if component.isAvailable("internet") then
                        web = true
                        state = "file_selection"
                    else
                        status("(internet card not found, install an internet card for download updates)", 1)
                    end
                else
                    -- Fresh installation - need confirmation
                    state = "confirm_installation"
                end
            end)
        end
    end

    return menu
end

local function createBuckets(allFiles)
    local qTools = {"tnet.lua","api.lua","dataio.lua","realtime.lua","screens.lua","qmenu.lua","cbor.lua","hosts.lua","json.lua","liblz16.lua","lzss.lua","inventory.lua"}
    local bucketDefinitions = {
        {id = "required", name = "Required",     isRequired = true,  defaultSelected = true,  matcher = function(f) return f:match("^/lib/") or f:match("^/etc/") or f:match("^/bin/sh.lua") or f:match("^/bin/rc.lua") or f == "/init.lua" or f == "/base.lua" end},
        {id = "qos",      name = "QOS Tools",    isRequired = false, defaultSelected = true,  matcher = function(f) for i, t in ipairs (qTools) do if f:match(t) then return true end end end},
        {id = "sys",      name = "Sys Tools",    isRequired = false, defaultSelected = true,  matcher = function(f) return f:match("cfgemu.lua") or f:match("flash.lua") or f:match("lshw.lua") or f:match("mount.lua") or f:match("pastebin.lua") or f:match("wget.lua") end},
        {id = "basic",    name = "Basic Tools",  isRequired = false, defaultSelected = true,  matcher = function(f) return f:match("^/bin/") end},
        {id = "man",      name = "Man Pages",    isRequired = false, defaultSelected = false, matcher = function(f) return f:match("^/usr/man/") end},
        {id = "unsorted", name = "Unsorted",     isRequired = false, defaultSelected = false, matcher = function(f) return true end}
    }
    local isUpgrade = isQuickOS and selectedDrive.path == "/"
    local buckets = {}
    for _, def in ipairs(bucketDefinitions) do
        local bucket = {
            id = def.id,
            name = def.name,
            files = {},
            selected = def.defaultSelected,
            isRequired = def.isRequired
        }
        if isUpgrade then
            bucket.isRequired = false
            bucket.selected = false
            if bucket.name == "Required" then
                bucket.name = "Core Files"
            end
        end
        buckets[def.id] = bucket
    end

    for _, file in ipairs(allFiles) do
        for _, def in ipairs(bucketDefinitions) do
            if def.matcher(file) then
                table.insert(buckets[def.id].files, { path = file, selected = buckets[def.id].selected })
                break
            end
        end
    end

    local orderedBuckets = {}
    for _, def in ipairs(bucketDefinitions) do
        if #buckets[def.id].files > 0 then
            table.insert(orderedBuckets, buckets[def.id])
        end
    end
    return orderedBuckets
end

local function createFileSelectionMenu(allFiles)
    clearScreenArea()
    local menu = qmenu.create()
    local startY, leftPaneWidth = logoY + 11, 25
    local rightPaneX = leftPaneWidth + 3
    local buckets = createBuckets(allFiles)

    sFG(0xAAAAAA)
    gSet(2, startY - 2, (web and "cloud" or fs.get("/").address:sub(1, 5)) .. " -> " .. selectedDrive.dev.address:sub(1, 5))
    gSet(2, startY - 1, ("─"):rep(leftPaneWidth - 2))
    gSet(rightPaneX, startY - 1, ("─"):rep(w - rightPaneX))
    sFG(white)

    local currentPage, maxPages, filesPerPage = 1, 1, h - startY - 3
    local currentBucketOption, fileOptions = nil, {}

    -- Pagination Buttons
    local pageLeft = menu:addOption("pageLeft", rightPaneX, startY, "<-")
    local pageRight = menu:addOption("pageRight", rightPaneX + 21, startY, "->")
    pageLeft:bind(keys.right, pageRight); pageRight:bind(keys.left, pageLeft)
    pageLeft:setStyle("selected", isT1 and 0 or 0x88D700, isT1 and white or 0); pageRight:setStyle("selected", isT1 and 0 or 0x88D700, isT1 and white or 0)

    local filePathY = startY + 1
    local function updateFilePathDisplay(text, color)
        gpu.fill(rightPaneX, filePathY, w - rightPaneX + 1, 1, " ")
        if text and text ~= "" then
            sFG(color or 0xAAAAAA)
            gSet(rightPaneX, filePathY, text)
            sFG(white)
        end
    end

    local function updateFilePane(bucketOption, pageIncrement, force)
        local lastPage = currentPage
        currentPage = currentPage + (pageIncrement or 0)
        
        local bucket = bucketOption.bucket
        maxPages = math.max(1, math.ceil(#bucket.files / filesPerPage))
        currentPage = math.min(math.max(1, currentPage), maxPages)

        if force~=true and currentPage == lastPage and currentBucketOption == bucketOption then return end
        if currentBucketOption ~= bucketOption then currentPage = 1 end
        currentBucketOption = bucketOption

        updateFilePathDisplay("")
        gpu.fill(rightPaneX, startY + 2, w - rightPaneX + 1, h, " ")
        for _, opt in ipairs(fileOptions) do menu:removeOption(opt.name) end
        fileOptions = {}
        
        bucketOption:bind(keys.right, false)

        local fileCount = #bucket.files
        local startFile = (currentPage - 1) * filesPerPage + 1
        local endFile = math.min(currentPage * filesPerPage, fileCount)
        local pageText = string.format("Files %d-%d (%d)", startFile, endFile, fileCount)
        pageText = string.format("%16s", pageText)
        gpu.fill(rightPaneX + 4, startY, 15, 1, " ")
        gSet(rightPaneX + 4, startY, pageText)

        for i = 1, filesPerPage do
            local fileIndex = i + (currentPage - 1) * filesPerPage
            local file = bucket.files[fileIndex]
            if not file then break end

            local check = file.selected and "✓" or " "
            local fileName = fs.name(file.path)
            local option = menu:addOption(bucket.id .. fileIndex, rightPaneX, startY + 1 + i, "[" .. check .. " ] " .. fileName)
            option.file, option.bucket = file, bucket
            
            option:onSelect(function(opt)
                local color = opt.bucket.isRequired and 0x00BFFF or 0xAAD700
                updateFilePathDisplay(opt.file.path, color)
            end)
            option:onActivate(function(opt)
                if not opt.bucket.isRequired then
                    opt.file.selected = not opt.file.selected
                    opt:text("[" .. (opt.file.selected and "✓" or " ") .. " ] " .. fs.name(opt.file.path))
                end
            end)

            if i == 1 then
                bucketOption:bind(keys.right, option)
                pageLeft:bind(keys.down, option)
                pageRight:bind(keys.down, option)
                option:bind(keys.up, pageLeft)
            end
            option:bind(keys.left, bucketOption)
            table.insert(fileOptions, option)
        end
        linkMenuOptions(fileOptions)
        if #fileOptions > 0 then
            fileOptions[#fileOptions]:bind(keys.down, fileOptions[1])
        end
    end

    local goPrevPage = function() if currentBucketOption then updateFilePane(currentBucketOption, currentPage-1 < 1 and maxPages or -1); menu:draw() end end
    local goNextPage = function() if currentBucketOption then updateFilePane(currentBucketOption, currentPage+1 > maxPages and -maxPages or 1); menu:draw() end end
    pageLeft:onActivate(goPrevPage)
    pageRight:onActivate(goNextPage)
    pageLeft:bind(keys.left, goPrevPage)
    pageRight:bind(keys.right, goNextPage)

    local mainOptions = {}
    for i, bucket in ipairs(buckets) do
        local check = bucket.selected and "✓" or " "
        local option = menu:addOption(bucket.id, 2, startY + i - 1, "[" .. check .. " ] " .. bucket.name)
        option.bucket = bucket
        table.insert(mainOptions, option)
        option:setStyle("selected", isT1 and 0 or (bucket.isRequired and 0x00BFFF or 0xAAD700), isT1 and white or 0)
        option:onSelect(function(opt) updateFilePane(opt, 0) end)
        if not bucket.isRequired then
            option:onActivate(function(opt)
                opt.bucket.selected = not opt.bucket.selected
                for _, file in ipairs(opt.bucket.files) do file.selected = opt.bucket.selected end
                opt:text("[" .. (opt.bucket.selected and "✓" or " ") .. " ] " .. opt.bucket.name)
                updateFilePane(opt, 0, true)
                menu:draw()
            end)
        end
    end
    
    local bottomY = startY + #mainOptions + 3
    local replaceOption = menu:addOption("replace", 2, bottomY, "Replace Existing: "..tostring(overwriteDest))
    replaceOption:onActivate(function(opt) overwriteDest = not overwriteDest opt:text("Replace Existing: "..tostring(overwriteDest).." ") end)
    local continueOption = menu:addOption("continue", 2, bottomY + 1, "Continue Installation")
    local cancelOption = menu:addOption("cancel", 2, bottomY + 2, "Cancel Installation")
    table.insert(mainOptions, replaceOption)
    table.insert(mainOptions, continueOption)
    table.insert(mainOptions, cancelOption)
    replaceOption:setStyle("selected", isT1 and 0 or 0xFFD700,isT1 and white or 0)
    continueOption:setStyle("selected", isT1 and 0 or 0xFFD700,isT1 and white or 0); cancelOption:setStyle("selected", isT1 and 0 or 0xFFD700,isT1 and white or 0)
    cancelOption:onActivate(function() state = "cancelled" end)
    continueOption:onActivate(function()
        selectedFiles = {}
        for _, bucket in ipairs(buckets) do
            for _, file in ipairs(bucket.files) do
                if file.selected then table.insert(selectedFiles, file.path) end
            end
        end
    end)
    linkMenuOptions(mainOptions)
    menu:setSelected(mainOptions[1])

    return menu
end

local function listAll(src)
    local total = 0
    local list = {}

    if src == "internet" then
        clearScreenArea()
        status("Downloading the QuickOS file index...")
        status("", 1)
        drawProgressBar(0, 1, 0xFFFF00)
        status("(this process might take some time)", 2, 0x757575)
        status("", 2)

        local result, response = pcall(internet.request, cdn .. "/files.txt", nil, {["User-Agent"] = "Wget/OpenComputers"})
        local fullList = ""
        if result then
            for chunk in response do
                string.gsub(chunk, "\r\n", "\n")
                fullList = fullList .. chunk
            end
        else
            return nil, "Failed to fetch the file list!"
        end

        local line = ""
        local len = #fullList
        for i = 1, len do
            drawProgressBar(i, len, 0xFFFF00)
            local char = fullList:sub(i, i)
            if char == "\n" then
                table.insert(list, line)
                status(line, 3, 0x757575)
                total = total + 1
                line = ""
            else
                line = line .. char
            end
        end

        return list, total
    end

    if src == nil or type(src) ~= "string" then src = "/" end

    local exclusions = {
        ["/home/"] = true,
        ["/tmp/"] = true,
        ["/dev/"] = true,
        ["/mnt/"] = true
    }

    for path in fs.list(src) do
        if exclusions[src .. path] ~= true then
            if string.sub(path, -1) == "/" then
                local found, count = listAll(src .. path)
                total = total + count
                for _, path2 in pairs(found) do
                    table.insert(list, path2)
                end
            else
                total = total + 1
                table.insert(list, src .. path)
            end
        end
    end

    return list, total
end

-- Main installation function
local function installOS(drive, files)
    local update = drive.path == "/"

    if not update then
        local filesToDelete, total = listAll(drive.path)
        local done = 0
        status("", 1)
        status("(currently wiping the hard drive)", 2, 0x757575)

        for _, path in pairs(filesToDelete) do
            if fs.exists(drive.path .. path) then
                drawProgressBar(done, total, 0xFF0000)
                status("[" .. tostring(done + 1) .. "/" .. tostring(total) .. "] Deleting \"" .. path .. "\"...")
                fs.remove(drive.path .. path)
                done = done + 1
            end
        end
    end

    local total = #files
    local done = 0
    status("", 1)
    status("(currently "..(web and "downloading" or "copying").." the QuickOS files)", 2, 0x757575)

    fs.makeDirectory(drive.path .. "/home/")
    for _, path in pairs(files) do
        drawProgressBar(done, total, 0x00FF00)
        status("[" .. tostring(done + 1) .. "/" .. tostring(total) .. (web and "] Downloading \"" or "] Copying \"").. path .. "\"...")
        fs.makeDirectory(drive.path .. fs.path(path))

        local success, reason = processFile(path, drive.path .. path, web, overwriteDest)
        if not success then
            quit("Error: " .. reason)
            return false
        end
        done = done + 1
    end

    computer.beep()
    drive.dev.setLabel("QuickOS")
    return true
end

-- Main program
local drives = findDrives()
if not drives then return end

-- Initialize menus
local driveMenu = createDriveSelectionMenu(drives)
local fileMenu = nil

-- Main event loop
while running do
    if state == "drive_selection" then
        clearScreenArea()
        status("Select a drive to install the OS onto:")
        driveMenu:draw(true)
        while state == "drive_selection" do
            local _, _, _, key = event.pull("key_down")
            if key == keys.q then
                running = false
                quit("Installation cancelled by user")
            else
                driveMenu:handleEvent(key)
                driveMenu:draw()
            end
        end
    elseif state == "confirm_installation" then
        showConfirmationDialog("Confirm " .. (selectedDrive.dev.getLabel() or "No Label") .. " (" .. selectedDrive.dev.address .. ")", "Are you absolutely sure? It will wipe ALL of your data!",
        function() -- Yes callback
            state = "file_source_selection"
        end, function() -- No callback
            selectedDrive = nil
            state = "drive_selection"
        end)
    elseif state == "file_source_selection" then
        if component.isAvailable("internet") then
            showConfirmationDialog("Download QuickOS files from the internet?", "(no to install from local)",
            function() -- Yes callback
                web = true
                state = "file_selection"
            end, function() -- No callback
                state = "file_selection"
            end,
            isQuickOS)
        end
        state = "file_selection"
    elseif state == "file_selection" then
        -- Get file list
        local files, total = listAll(web and "internet")
        if not files then
            quit("Error: " .. total)
            return
        end

        status("Select files to install:")
        status(web and "QuickOS internet download" or "QuickOS copy", 1)

        fileMenu = createFileSelectionMenu(files)
        fileMenu:draw(true)

        local filesSelected = false
        while state == "file_selection" do
            local _, _, _, key = event.pull("key_down")
            if key == keys.q then
                running = false
                quit("Installation cancelled by user")
            else
                fileMenu:handleEvent(key)
                fileMenu:draw()

                -- Check if files were selected and continue was pressed
                if #selectedFiles > 0 then
                    filesSelected = true
                    state = "installation"
                end
            end
        end
    elseif state == "installation" then -- Install OS
        if installOS(selectedDrive, selectedFiles) then
            state = "boot_confirmation"
        else
            quit("Installation failed!")
        end
    elseif state == "boot_confirmation" then
        local confirmed = false
        showConfirmationDialog(
            "The installation process successfully finished!",
            "Would you like to make the drive bootable?",
            function() -- Yes callback
                confirmed = true
                computer.setBootAddress(selectedDrive.dev.address)
                state = "reboot_confirmation"
            end, function() -- No callback
                confirmed = true
                state = "reboot_confirmation"
            end)

        if not confirmed then
            running = false
        end
    elseif state == "reboot_confirmation" then
        showConfirmationDialog("Would you like to reboot your computer?", "",
        function()
            computer.shutdown(true)
        end, function()
            quit("")
        end)

    elseif state == "cancelled" then
        running = false
    end
end

quit("Installation wizard successfully finished!")