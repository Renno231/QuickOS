local qboot = require("qboot")
local shell = require("shell")

local args, options = shell.parse(...)
local command = args[1]

local function usage()
  io.write([[
Usage:
  qboot build [--archive-layout=per-file|solid] [--archive-storage=sidecar|embedded] [--no-boot-screen] [--diagnostics] [--json]
  qboot enable [build options] [--json]
  qboot status [--json]
  qboot restore [--json]
  qboot disable [--json]
]])
end

local allowedOptions = {
  ["archive-layout"] = true,
  ["archive-storage"] = true,
  ["no-boot-screen"] = true,
  diagnostics = true,
  json = true,
  h = true,
  help = true,
}

for name in pairs(options) do
  if not allowedOptions[name] then
    io.stderr:write("qboot: unknown option --" .. tostring(name) .. "\n")
    return
  end
end

if not command or command == "help" or options.h or options.help then
  usage()
  return
end
if #args > 1 then
  io.stderr:write("qboot: unexpected argument " .. tostring(args[2]) .. "\n")
  return
end

local commands = {
  build = qboot.build,
  enable = qboot.enable,
  status = qboot.status,
  restore = qboot.restore,
  disable = qboot.disable,
}
local operation = commands[command]
if not operation then
  io.stderr:write("qboot: unknown command " .. tostring(command) .. "\n")
  usage()
  return
end

local buildOptionPresent = options["archive-layout"] ~= nil
  or options["archive-storage"] ~= nil
  or options["no-boot-screen"] ~= nil
  or options.diagnostics ~= nil
if command ~= "build" and command ~= "enable" and buildOptionPresent then
  io.stderr:write("qboot: build options are valid only with build or enable\n")
  return
end

local request = {
  archiveLayout = options["archive-layout"],
  archiveStorage = options["archive-storage"],
  noBootScreen = options["no-boot-screen"],
  diagnostics = options.diagnostics,
  forceBuild = command == "build" or (command == "enable" and buildOptionPresent),
}

local function jsonString(value)
  return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
end

local function json(value)
  local kind = type(value)
  if kind == "nil" then return "null"
  elseif kind == "boolean" or kind == "number" then return tostring(value)
  elseif kind == "string" then return jsonString(value)
  elseif kind == "table" then
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local output = {}
    for _, key in ipairs(keys) do
      output[#output + 1] = jsonString(key) .. ":" .. json(value[key])
    end
    return "{" .. table.concat(output, ",") .. "}"
  end
  error("cannot encode " .. kind .. " as JSON")
end

local ok, result = pcall(operation, request)
if not ok then
  io.stderr:write("qboot: " .. tostring(result) .. "\n")
  return
end

if options.json then
  io.write(json(result), "\n")
elseif command == "status" then
  io.write("QBoot: ", result.status, "\n")
  if result.built or result.enabled then
    io.write("Layout: ", tostring(result.layout), "\n")
    io.write("Storage: ", tostring(result.storage), "\n")
    io.write("Boot screen: ", tostring(result.bootScreen), "\n")
    io.write("Diagnostics: ", tostring(result.diagnostics), "\n")
  end
else
  io.write("QBoot ", result.status, "\n")
end
