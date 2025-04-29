local w, h
local component = require('component')
local screen = component.screen
local gpu = component.gpu
if gpu then
  if not gpu.getScreen() then
    gpu.bind(screen)
  end
  w, h = gpu.maxResolution()
  gpu.setBackground(0x181818)
  gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, w, h, " ")
end

local logoY = (h-12)/2+1
local logoX = (w-61)/2+1
gpu.setForeground(0x00ED8A)
gpu.set(logoX, logoY+0, " ██████╗  ██╗   ██╗  ██╗  ██████╗ ██╗  ██╗  ██████╗  ███████╗")
gpu.set(logoX, logoY+1, "██╔═══██╗ ██║   ██║  ██║ ██╔════╝ ██║ ██╔╝ ██╔═══██╗ ██╔════╝")
gpu.set(logoX, logoY+2, "██║   ██║ ██║   ██║  ██║ ██║      █████╔╝  ██║   ██║ ███████╗")
gpu.set(logoX, logoY+3, "██║   ██║ ██║   ██║  ██║ ██║      ██╔═██╗  ██║   ██║ ╚════██║")
gpu.set(logoX, logoY+4, "╚██████╔╝ ████████║  ██║  ██████╗ ██║ ╚██╗ ╚██████╔╝ ███████║")
gpu.set(logoX, logoY+5, " ╚═════╝  ╚═══════╝  ╚═╝  ╚═════╝ ╚═╝  ╚═╝  ╚═════╝  ╚══════╝") -- Q tail integrated here
gpu.setForeground(0xFFFFFF)
gpu.set(logoX, logoY+6, "            Installation Wizard 1.0.0 made by Renno231              ")

local function drawStatus(str, offset, color)
  local x = (w-utf8.len(str))/2+1
  local y = logoY+8
  if color == nil then
    color = 0xFFFFFF
  end
  gpu.setForeground(color)
  if offset ~= nil then
    y = y+(offset*2)
  end
  gpu.fill(0, y, w, 1, " ")
  gpu.set(x, y, str)
  gpu.setForeground(0xFFFFFF)
end

local function quit(reason)
  require("term").clear()
  gpu.setBackground(0x000000)
  gpu.fill(1, 1, w, h, " ")
  io.write(reason)
end

local cdn = "https://raw.githubusercontent.com/Renno231/QuickOS/main"
local isQuickOS = string.find(_G._OSVERSION, "QuickOS")
local event = require("event")
local web = not isQuickOS
local internet = nil

local comps = require("component").list("filesystem")
local fs = require("filesystem")
local devices = {}

local targets = {}
local found = 0
local index = 1

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
  return
end

local function drawSelector()
  local str = (targets[index].dev.getLabel() or "No Label") .. " (" .. targets[index].dev.address .. ")"
  if targets[index].path == "/" then
    str = "Update your local installation"
  end
  local len = utf8.len(str)
  local x = (w-len)/2+1
  local y = logoY+10
  gpu.fill(0, y, w, 1, " ")
  gpu.set(x, y, str)
  if index == 1 then
    gpu.setForeground(0x3D3D3D)
  else
    gpu.setForeground(0xFFFFFF)
  end
  gpu.set(x-6, y, "❮")
  if index == found then
    gpu.setForeground(0x3D3D3D)
  else
    gpu.setForeground(0xFFFFFF)
  end
  gpu.set(x+len+5, y, "❯")
  gpu.setForeground(0xFFFFFF)
end

::select::
drawStatus("Select a drive to install the OS onto:")
drawStatus("(Press \"Enter\" to select, \"Backspace\" to cancel)", 2, 0x757575)
drawSelector()

while true do
  local type, _, _, code = event.pull()
  if type == "key_down" then
    if code == 205 and index ~= found then -- Right
      index = index + 1
      drawSelector()
    elseif code == 203 and index ~= 1 then -- Left
      index = index - 1
      drawSelector()
    elseif code == 28 then -- Enter
      break
    elseif code == 14 then -- Backspace
      quit("Installation cancelled by user")
      return
    end
  end
end

local update = targets[index].path == "/"
if not update then
  drawStatus("You chose " .. (targets[index].dev.getLabel() or "No Label") .. " (" .. targets[index].dev.address .. ")")
  drawStatus("Are you absolutely sure? It will wipe ALL of your data!", 1)
  drawStatus("(Press \"Y\" for yes, \"N\" for no, \"Backspace\" to cancel)", 2, 0x757575)

  while true do
    local type, _, _, code = event.pull()
    if type == "key_down" then
      if code == 21 then -- Yes
        break
      elseif code == 49 then -- No
        goto select
      elseif code == 14 then -- Backspace
        quit("Installation cancelled by user")
        return
      end
    end
  end
else 
  web = true
end

if web and not component.isAvailable("internet") then
  quit("Error: Internet card is required to continue!")
  return
elseif web then
  internet = require("internet")
end

local exclusions = {
  ["/home/"] = true,
  ["/tmp/"] = true,
  ["/dev/"] = true,
  ["/mnt/"] = true
}

local chosen = targets[index]
function listAll(src)
  local total = 0
  local list = {}
  if web and src == nil then
    drawStatus("Downloading the QuickOS file index...")
    drawStatus("", 1)
    gpu.setBackground(0x3D3D3D)
    local progressX = (w-50)/2+1
    gpu.fill(progressX, logoY+10, 50, 1, " ")
    gpu.setBackground(0x181818)
    drawStatus("(this process might take a bit of time)", 2, 0x757575)
    drawStatus("", 2)
    local result, response = pcall(internet.request, cdn .. "/files.txt", nil, {["User-Agent"]="Wget/OpenComputers"})
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
    local perChar = 50/len
    for i = 1, len do
      local percentage = i/len*100
      gpu.setBackground(0xFFFF00)
      gpu.fill(progressX, logoY+10, math.ceil(perChar*i), 1, " ")
      gpu.setBackground(0x181818)
      local char = fullList:sub(i,i)
      if char == "\n" then
        table.insert(list, line)
        total = total + 1
        line = ""
      else
        line = line .. char
      end
    end
  
    return list, total
  end
  if src == nil then
    src = "/"
  end
  for path in fs.list(src) do
    if exclusions[src .. path] ~= true then
      if string.sub(path, -1) == "/" then
        local found, count = listAll(src .. path)
        total = total + count
        for _,path2 in pairs(found) do
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

if not update then
  local files, total = listAll(chosen.path)
  local perFile = 50 / total
  local done = 0
  drawStatus("", 1)
  drawStatus("(currently wiping the hard drive)", 2, 0x757575)

  gpu.setBackground(0x3D3D3D)
  local progressX = (w-50)/2+1
  gpu.fill(progressX, logoY+10, 50, 1, " ")
  gpu.setBackground(0x181818)

  for _,path in pairs(files) do
    local percentage = done/total*100
    gpu.setBackground(0xFF0000)
    gpu.fill(progressX, logoY+10, math.ceil(perFile*done), 1, " ")
    gpu.setBackground(0x181818)
    drawStatus("[" .. tostring(done+1) .. "/" .. tostring(total) .. "] Deleting \"" .. path .. "\"...")
    fs.remove(chosen.path .. path)
    done = done + 1
  end
end

local files, total = listAll()
if files == nil then
  quit("Error: " .. total)
  return
end

local perFile = 50 / total
local done = 0
drawStatus("", 1)
if web then
  drawStatus("(currently downloading the QuickOS files)", 2, 0x757575)
else
  drawStatus("(currently copying the QuickOS files)", 2, 0x757575)
end

gpu.setBackground(0x3D3D3D)
local progressX = (w-50)/2+1
gpu.fill(progressX, logoY+10, 50, 1, " ")
gpu.setBackground(0x181818)

fs.makeDirectory(chosen.path .. "/home/")
for _,path in pairs(files) do
  local percentage = done/total*100
  gpu.setBackground(0x00FF00)
  gpu.fill(progressX, logoY+10, math.ceil(perFile*done), 1, " ")
  gpu.setBackground(0x181818)
  if web then
    drawStatus("[" .. tostring(done+1) .. "/" .. tostring(total) .. "] Downloading \"" .. path .. "\"...")
  else
    drawStatus("[" .. tostring(done+1) .. "/" .. tostring(total) .. "] Copying \"" .. path .. "\"...")
  end
  fs.makeDirectory(chosen.path .. fs.path(path))
  if not web then
    fs.copy(path, chosen.path .. path)
  else
    local f, reason = io.open(chosen.path .. path, "w")
    -- if not f then
    --   quit("Error: Failed to open \"" .. chosen.path .. path .. "\" for writing!")
    --   return
    -- end
    if f then
        local url = cdn .. path
        local result, response = pcall(internet.request, url, nil, {["User-Agent"]="Wget/OpenComputers"})
        if result then
            for chunk in response do
                string.gsub(chunk, "\r\n", "\n")
                f:write(chunk)
            end

            f:close()
        else
            quit("Error: Failed to download \"" .. cdn .. path .. "\"!")
            return
        end
    else
        drawStatus("Failed to get file object for [" .. chosen.path.."][" .. path .. "]")
    end
  end
  done = done + 1
end

local computer = require("computer")
computer.beep()
chosen.dev.setLabel("QuickOS")
drawStatus("The installation process successfully finished!")
drawStatus("Would you like to make the drive bootable?", 1)
drawStatus("(Press \"Y\" for yes, \"N\" for no)", 2, 0x757575)

while true do
  local type, _, _, code = event.pull()
  if type == "key_down" then
    if code == 21 then -- Yes
      computer.setBootAddress(chosen.dev.address)
      break
    elseif code == 49 then -- No
      break
    end
  end
end

drawStatus("Would you like to reboot your computer?", 1)
drawStatus("(Press \"Y\" for yes, \"N\" for no)", 2, 0x757575)

while true do
  local type, _, _, code = event.pull()
  if type == "key_down" then
    if code == 21 then -- Yes
      computer.shutdown(true)
    elseif code == 49 then -- No
      break
    end
  end
end

quit("Installation wizard successfully finished!")
