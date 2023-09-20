-- Basic LUA library
function loadfile(filename, ...)
  if filename:sub(1,1) ~= "/" then
    filename = (os.getenv("PWD") or "/") .. "/" .. filename
  end
  local handle, open_reason = require("filesystem").open(filename)
  if not handle then
    return nil, open_reason
  end
  local buffer = {}
  while true do
    local data, reason = handle:read(1024)
    if not data then
      handle:close()
      if reason then
        return nil, reason
      end
      break
    end
    buffer[#buffer + 1] = data
  end
  return load(table.concat(buffer), "=" .. filename, ...)
end

function dofile(filename)
  local program, reason = loadfile(filename)
  if not program then
    return error(reason .. ':' .. filename, 0)
  end
  return program()
end

function print(...)
  local args = table.pack(...)
  local stdout = io.stdout
  local pre = ""
  for i = 1, args.n do
    stdout:write(pre, (assert(tostring(args[i]), "'tostring' must return a string to 'print'")))
    pre = "\t"
  end
  stdout:write("\n")
  stdout:flush()
end

-- Process and coroutine library
local process = require("process")
local fs = require("filesystem")
local _coroutine = coroutine

_G.coroutine = setmetatable(
  {
    resume = function(co, ...)
      local proc = process.info(co)
      return (proc and proc.data.coroutine_handler.resume or _coroutine.resume)(co, ...)
    end
  },
  {
    __index = function(_, key)
      local proc = process.info(_coroutine.running())
      return (proc and proc.data.coroutine_handler or _coroutine)[key]
    end
  }
)

package.loaded.coroutine = _G.coroutine

local kernel_load = _G.load
local intercept_load
intercept_load = function(source, label, mode, env)
  local prev_load = env and env.load or _G.load
  local e = env and setmetatable({
    load = function(_source, _label, _mode, _env)
      return prev_load(_source, _label, _mode, _env or env)
    end}, {
      __index = env,
      __pairs = function(...) return pairs(env, ...) end,
      __newindex = function(_, key, value) env[key] = value end,
  })
  return kernel_load(source, label, mode, e or process.info().env)
end
_G.load = intercept_load

local kernel_create = _coroutine.create
_coroutine.create = function(f,standAlone)
  local co = kernel_create(f)
  if not standAlone then
    table.insert(process.findProcess().instances, co)
  end
  return co
end

_coroutine.wrap = function(f)
  local thread = coroutine.create(f)
  return function(...)
    return select(2, coroutine.resume(thread, ...))
  end
end

local init_thread = _coroutine.running()
process.list[init_thread] = {
  path = "/init.lua",
  command = "init",
  env = _ENV,
  data =
  {
    vars={},
    handles={},
    io={},
    coroutine_handler = _coroutine,
    signal = error
  },
  instances = setmetatable({}, {__mode="v"})
}

local fs_open = fs.open
fs.open = function(...)
  local fs_open_result = table.pack(fs_open(...))
  if fs_open_result[1] then
    process.addHandle(fs_open_result[1])
  end
  return table.unpack(fs_open_result, 1, fs_open_result.n)
end

-- Basic OS library
local computer = require("computer")
local info = require("process").info
local event = require("event")

function os.getenv(varname)
  local env = info().data.vars
  if not varname then
    return env
  elseif varname == '#' then
    return #env
  end
  return env[varname]
end

function os.setenv(varname, value)
  checkArg(1, varname, "string", "number")
  if value ~= nil then
    value = tostring(value)
  end
  info().data.vars[varname] = value
  return value
end

function os.sleep(timeout)
  checkArg(1, timeout, "number", "nil")
  local deadline = computer.uptime() + (timeout or 0)
  repeat
    event.pull(deadline - computer.uptime())
  until computer.uptime() >= deadline
end

os.setenv("PATH", "/bin:/usr/bin:/home/bin:.")
os.setenv("TMP", "/tmp") -- Deprecated
os.setenv("TMPDIR", "/tmp")

if computer.tmpAddress() then
  fs.mount(computer.tmpAddress(), "/tmp")
end

require("package").delay(os, "/lib/core/full_filesystem.lua")

-- Basic input/output library
local buffer = require("buffer")
local tty_stream = require("tty").stream

local core_stdin = buffer.new("r", tty_stream)
local core_stdout = buffer.new("w", tty_stream)
local core_stderr = buffer.new("w", setmetatable(
{
  write = function(_, str)
    return tty_stream:write("\27[31m"..str.."\27[37m")
  end
}, {__index=tty_stream}))

core_stdout:setvbuf("no")
core_stderr:setvbuf("no")
core_stdin.tty = true
core_stdout.tty = true
core_stderr.tty = true

core_stdin.close = tty_stream.close
core_stdout.close = tty_stream.close
core_stderr.close = tty_stream.close

local io_mt = getmetatable(io) or {}
io_mt.__index = function(_, k)
  return
    k == 'stdin' and io.input() or
    k == 'stdout' and io.output() or
    k == 'stderr' and io.error() or
    nil
end

setmetatable(io, io_mt)

io.input(core_stdin)
io.output(core_stdout)
io.error(core_stderr)

-- Component library
local component = require("component")

local adding = {}
local primaries = {}

setmetatable(component, {
  __index = function(_, key)
    return component.getPrimary(key)
  end,
  __pairs = function(self)
    local parent = false
    return function(_, key)
      if parent then
        return next(primaries, key)
      else
        local k, v = next(self, key)
        if not k then
          parent = true
          return next(primaries)
        else
          return k, v
        end
      end
    end
  end
})

function component.get(address, componentType)
  checkArg(1, address, "string")
  checkArg(2, componentType, "string", "nil")
  for c in component.list(componentType, true) do
    if c:sub(1, address:len()) == address then
      return c
    end
  end
  return nil, "no such component"
end

function component.isAvailable(componentType)
  checkArg(1, componentType, "string")
  if not primaries[componentType] and not adding[componentType] then
    component.setPrimary(componentType, component.list(componentType, true)())
  end
  return primaries[componentType] ~= nil
end

function component.isPrimary(address)
  local componentType = component.type(address)
  if componentType then
    if component.isAvailable(componentType) then
      return primaries[componentType].address == address
    end
  end
  return false
end

function component.getPrimary(componentType)
  checkArg(1, componentType, "string")
  assert(component.isAvailable(componentType),
    "no primary '" .. componentType .. "' available")
  return primaries[componentType]
end

function component.setPrimary(componentType, address)
  checkArg(1, componentType, "string")
  checkArg(2, address, "string", "nil")
  if address ~= nil then
    address = component.get(address, componentType)
    assert(address, "no such component")
  end

  local wasAvailable = primaries[componentType]
  if wasAvailable and address == wasAvailable.address then
    return
  end
  local wasAdding = adding[componentType]
  if wasAdding and address == wasAdding.address then
    return
  end
  if wasAdding then
    event.cancel(wasAdding.timer)
  end
  primaries[componentType] = nil
  adding[componentType] = nil

  local primary = address and component.proxy(address) or nil
  if wasAvailable then
    computer.pushSignal("component_unavailable", componentType)
  end
  if primary then
    if wasAvailable or wasAdding then
      adding[componentType] = {
        address=address,
        proxy = primary,
        timer=event.timer(0.1, function()
          adding[componentType] = nil
          primaries[componentType] = primary
          computer.pushSignal("component_available", componentType)
        end)
      }
    else
      primaries[componentType] = primary
      computer.pushSignal("component_available", componentType)
    end
  end
end

local function onComponentAdded(_, address, componentType)
  local prev = primaries[componentType] or (adding[componentType] and adding[componentType].proxy)

  if prev then
    if componentType == "screen" then
      if #prev.getKeyboards() == 0 then
        local first_kb = component.invoke(address, 'getKeyboards')[1]
        if first_kb then
          component.setPrimary("keyboard", first_kb)
          prev = nil
        end
      end
    elseif componentType == "keyboard" then
      if address ~= prev.address then
        local current_screen = primaries.screen or (adding.screen and adding.screen.proxy)
        if current_screen then
          prev = address ~= current_screen.getKeyboards()[1]
        end
      end
    end
  end

  if not prev then
    component.setPrimary(componentType, address)
  end
end

local function onComponentRemoved(_, address, componentType)
  if primaries[componentType] and primaries[componentType].address == address or
     adding[componentType] and adding[componentType].address == address
  then
    local next = component.list(componentType, true)()
    component.setPrimary(componentType, next)

    if componentType == "screen" and next then
      local proxy = (primaries.screen or (adding.screen and adding.screen.proxy))
      if proxy then
        local next_kb = proxy.getKeyboards()[1]
        local old_kb = primaries.keyboard or adding.keyboard
        if next_kb and (not old_kb or old_kb.address ~= next_kb) then
          component.setPrimary("keyboard", next_kb)
        end
      end
    end
  end
end

event.listen("component_added", onComponentAdded)
event.listen("component_removed", onComponentRemoved)

if _G.boot_screen then
  component.setPrimary("screen", _G.boot_screen)
end
_G.boot_screen = nil

-- Virtual device filesystem
require("filesystem").mount(
setmetatable({
  address = "f5501a9b-9c23-1e7a-4afe-4b65eed9b88a"
},
{
  __index=function(tbl,key)
    local result =
    ({
      getLabel = "devfs",
      spaceTotal = 0,
      spaceUsed = 0,
      isReadOnly = false,
    })[key]

    if result ~= nil then
      return function() return result end
    end
    local lib = require("devfs")
    lib.register(tbl)
    return lib.proxy[key]
  end
}), "/dev")

-- Run .rc scripts
require("event").listen("init", function()
  dofile(require("shell").resolve("rc", "lua"))
  return false
end)

-- Filesystem stuff
local shell = require("shell")
local tmp = require("computer").tmpAddress()

local pendingAutoruns = {}

local function onComponentAdded(_, address, componentType)
  if componentType == "filesystem" and tmp ~= address then
    local proxy = fs.proxy(address)
    if proxy then
      local name = address:sub(1, 3)
      while fs.exists(fs.concat("/mnt", name)) and
            name:len() < address:len() -- just to be on the safe side
      do
        name = address:sub(1, name:len() + 1)
      end
      name = fs.concat("/mnt", name)
      fs.mount(proxy, name)
      if not fs.exists("/etc/filesystem.cfg") or fs.isAutorunEnabled() then
        local file = shell.resolve(fs.concat(name, "autorun"), "lua") or
                      shell.resolve(fs.concat(name, ".autorun"), "lua")
        if file then
          local run = {file, _ENV, proxy}
          if pendingAutoruns then
            table.insert(pendingAutoruns, run)
          else
            xpcall(shell.execute, event.onError, table.unpack(run))
          end
        end
      end
    end
  end
end

local function onComponentRemoved(_, address, componentType)
  if componentType == "filesystem" then
    if fs.get(shell.getWorkingDirectory()).address == address then
      shell.setWorkingDirectory("/")
    end
    fs.umount(address)
  end
end

event.listen("init", function()
  for _, run in ipairs(pendingAutoruns) do
    xpcall(shell.execute, event.onError, table.unpack(run))
  end
  pendingAutoruns = nil
  return false
end)

event.listen("component_added", onComponentAdded)
event.listen("component_removed", onComponentRemoved)

require("package").delay(fs, "/lib/core/full_filesystem.lua")

-- Initialize the GPU
local function onComponentAvailable(_, componentType)
  local component = require("component")
  local tty = require("tty")
  if (componentType == "screen" and component.isAvailable("gpu")) or
     (componentType == "gpu" and component.isAvailable("screen"))
  then
    local gpu, screen = component.gpu, component.screen
    local screen_address = screen.address
    if gpu.getScreen() ~= screen_address then
      gpu.bind(screen_address)
    end
    local depth = math.floor(2^(gpu.getDepth()))
    os.setenv("TERM", "term-"..depth.."color")
    event.push("gpu_bound", gpu.address, screen_address)
    if tty.gpu() ~= gpu then
      tty.bind(gpu)
      event.push("term_available")
    end
  end
end

event.listen("component_available", onComponentAvailable)

-- Initialize the keyboard
local keyboard = require("keyboard")

local function onKeyChange(ev, _, char, code)
  keyboard.pressedChars[char] = ev == "key_down" or nil
  keyboard.pressedCodes[code] = ev == "key_down" or nil
end

event.listen("key_down", onKeyChange)
event.listen("key_up", onKeyChange)

-- Initialize the terminal
local function components_changed(ename, address, type)
  local tty = require("tty")
  local window = tty.window
  if not window then
    return
  end

  if ename == "component_available" or ename == "component_unavailable" then
    type = address
  end

  if ename == "component_removed" or ename == "component_unavailable" then
    if type == "gpu" and window.gpu.address == address then
      window.gpu = nil
      window.keyboard = nil
    elseif type == "keyboard" then
      window.keyboard = nil
    end
    if (type == "screen" or type == "gpu") and not tty.isAvailable() then
      event.push("term_unavailable")
    end
  elseif (ename == "component_added" or ename == "component_available") and type == "keyboard" then
    window.keyboard = nil
  end
end

event.listen("component_removed",     components_changed)
event.listen("component_added",       components_changed)
event.listen("component_available",   components_changed)
event.listen("component_unavailable", components_changed)

-- Initialize the shell
if require("filesystem").exists("/etc/hostname") then
  loadfile("/bin/hostname.lua")("--update")
end
os.setenv("SHELL","/bin/sh.lua")

-- Push component_added signal for every component
for c, t in component.list() do
  computer.pushSignal("component_added", c, t)
end

-- Push init signal
computer.pushSignal("init")
require("event").pull(1, "init")
_G.runlevel = 1