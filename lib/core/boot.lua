local raw_loadfile = ...

_G._OSVERSION = "QuickOS 1.0.0"

local component = component
local computer = computer
local unicode = unicode

_G.runlevel = "S"
local shutdown = computer.shutdown
computer.runlevel = function() return _G.runlevel end
computer.shutdown = function(reboot)
  _G.runlevel = reboot and 6 or 0
  if os.sleep then
    computer.pushSignal("shutdown")
    os.sleep(0.1)
  end
  shutdown(reboot)
end

local w, h
local screen = component.list("screen", true)()
local gpu = screen and component.list("gpu", true)()
if gpu then
  gpu = component.proxy(gpu)
  if not gpu.getScreen() then
    gpu.bind(screen)
  end
  _G.boot_screen = gpu.getScreen()
  w, h = gpu.maxResolution()
  gpu.setResolution(w, h)
  gpu.setBackground(0x181818)
  gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, w, h, " ")
end

local function centerText(y, str)
  gpu.fill(1, y, w, 1, " ")
  gpu.set((w-utf8.len(str))/2+1, y, str)
end

local logoY = (h-11)/2+1
gpu.setForeground(0x00ED8A)
centerText(logoY+0, " ██████╗  ██╗   ██╗  ██╗  ██████╗ ██╗  ██╗  ██████╗  ███████╗")
centerText(logoY+1, "██╔═══██╗ ██║   ██║  ██║ ██╔════╝ ██║ ██╔╝ ██╔═══██╗ ██╔════╝")
centerText(logoY+2, "██║   ██║ ██║   ██║  ██║ ██║      █████╔╝  ██║   ██║ ███████╗")
centerText(logoY+3, "██║   ██║ ██║   ██║  ██║ ██║      ██╔═██╗  ██║   ██║ ╚════██║")
centerText(logoY+4, "╚██████╔╝ ████████║  ██║  ██████╗ ██║ ╚██╗ ╚██████╔╝ ███████║")
centerText(logoY+5, " ╚═════╝  ╚═══════╝  ╚═╝  ╚═════╝ ╚═╝  ╚═╝  ╚═════╝  ╚══════╝")
gpu.setForeground(0xFFFFFF)
centerText(logoY+6, "            Installation Wizard 1.0.0 made by Renno231       ")
local baseY = logoY+7
gpu.setForeground(0x3D3D3D)
centerText(baseY+3, "██████████████████████████████████████████████████")
gpu.setForeground(0xFFFFFF)

local function dofile(file)
  local program, reason = raw_loadfile(file)
  if program then
    local result = table.pack(pcall(program))
    if result[1] then
      return table.unpack(result, 2, result.n)
    else
      error(result[2])
    end
  else
    error(reason)
  end
end

centerText(baseY+1, "Initializing the OS...")
do
  local package = dofile("/lib/package.lua")
  _G.component = nil
  _G.computer = nil
  _G.process = nil
  _G.unicode = nil
  _G.package = package
  _G.io = dofile("/lib/io.lua")
  package.loaded.component = component
  package.loaded.computer = computer
  package.loaded.unicode = unicode
  package.loaded.buffer = dofile("/lib/buffer.lua")
  package.loaded.filesystem = dofile("/lib/filesystem.lua")
end
require("filesystem").mount(computer.getBootAddress(), "/")
dofile("base.lua")

function shell()
  local term = require("term")
  pwd = io.open("/home/.pwd")
  if pwd ~= nil then
    local pass = pwd:read("*a");
    gpu.fill(1, baseY+1, w, 1, " ")
    gpu.fill(1, baseY+3, w, 1, " ")
    gpu.set((w-68)/2+1, baseY+1, "Enter terminal password: ")
    while true do
      gpu.fill((w-68)/2+26, baseY+1, w-26, 1, " ")
      term.setCursor((w-68)/2+26, baseY+1)
      local input = term.read(nil, false, nil, "*")
      if input == pass .. "\n" then
        break
      end
      gpu.set((w-68)/2+1, baseY+3, "Wrong password, try again!")
    end
  end
  local shell = require("shell")
  local result, reason = xpcall(shell.getShell(), function(msg)
    return tostring(msg).."\n"..debug.traceback()
  end)
  if not result then
    require("term").clear()
    io.stderr:write((reason ~= nil and tostring(reason) or "unknown error") .. "\n")
    dofile("/bin/lua.lua")
  end
  computer.shutdown(true)
end

local filesystem = require("filesystem")
if filesystem.exists("/home/main.lua") then
  gpu.fill(1, baseY+1, w, 1, " ")
  gpu.fill(1, baseY+3, w, 1, " ")
  centerText(baseY+1, "Hold \"Ctrl+Shift\" to open terminal")
  gpu.setForeground(0x3D3D3D)
  centerText(baseY+3, "██████████████████████████████████████████████████")
  gpu.setForeground(0xFFFF00)
  for i=1,10 do
    gpu.set((w-50)/2+1+(i-1)*5, baseY+3, "█████")
    os.sleep(0.1)
  end
  
  gpu.setForeground(0xFFFFFF)
  local keyboard = require("keyboard")
  if keyboard.isShiftDown() and keyboard.isControlDown() then
    shell()
    return
  end

  centerText(baseY+1, "The main application is now running.")
  local status, err = pcall(function() dofile("/home/main.lua") end)
  if not status then
    centerText(baseY+3, "Please reboot and open terminal!")
    gpu.fill(1, baseY+1, w, 1, " ")
    centerText(baseY+1, err)
  else
    centerText(baseY+1, "The main application finished running.")
  end
else
  shell()
end

local event = require("event")
while true do
  event.pull()
end
