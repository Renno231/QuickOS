local filesystem = require("filesystem")
local lzss = require("lzss")

local qboot = {}

local HEADER = "-- QBOOT-GENERATED: 1"
local SOURCE_INIT = "/.qboot/source-init.lua"
local BUILD_INIT = "/.qboot/build-init.lua"
local BUILD_ARCHIVE = "/.qboot/build-archive.lzss"
local ACTIVE_ARCHIVE = "/.qboot/archive.lzss"
local LOADER_START = "local function loadfile(file)"
local BOOT_CALL = "local status, err = pcall(loadfile(\"/lib/core/boot.lua\"), loadfile)"

local RAW_FILES = {
  {name = "/lib/core/boot.lua", path = "/lib/core/boot.lua"},
  {name = "/lib/package.lua", path = "/lib/package.lua"},
  {name = "/lib/io.lua", path = "/lib/io.lua"},
  {name = "/lib/buffer.lua", path = "/lib/buffer.lua"},
  {name = "/lib/filesystem.lua", path = "/lib/filesystem.lua"},
  {name = "base.lua", path = "/base.lua"},
}

local MODULE_FILES = {
  {name = "process", path = "/lib/process.lua"},
  {name = "event", path = "/lib/event.lua"},
  {name = "keyboard", path = "/lib/keyboard.lua"},
  {name = "tty", path = "/lib/tty.lua"},
  {name = "shell", path = "/lib/shell.lua"},
  {name = "rc", path = "/lib/rc.lua"},
  {name = "sh", path = "/lib/sh.lua"},
  {name = "term", path = "/lib/term.lua"},
  {name = "text", path = "/lib/text.lua"},
  {name = "transforms", path = "/lib/transforms.lua"},
  {name = "vt100", path = "/lib/vt100.lua"},
  {name = "core/cursor", path = "/lib/core/cursor.lua"},
}

local VIRTUAL_FILES = {
  {name = "bin/rc.lua", path = "/bin/rc.lua"},
  {name = "bin/sh.lua", path = "/bin/sh.lua"},
  {name = "bin/source.lua", path = "/bin/source.lua"},
  {name = "etc/profile.lua", path = "/etc/profile.lua"},
  {name = "etc/rc.cfg", path = "/etc/rc.cfg"},
  {name = "home/.shrc", path = "/home/.shrc", optional = true},
}

local KNOWN_ABSENT_PATHS = {
  "bin/rc", "bin/source", "dev", "etc/hostname", "home/.pwd",
  "home/main.lua", "lib/lzss.lua", "tmp",
}

local function readFile(path)
  local file, reason = io.open(path, "rb")
  if not file then return nil, reason end
  local value = file:read("*a")
  file:close()
  return value
end

local function ensureDirectory(path)
  if filesystem.exists(path) then
    if filesystem.isDirectory(path) then return true end
    return nil, path .. " is not a directory"
  end
  local parent = filesystem.path(path)
  if parent and parent ~= path and parent ~= "" and not filesystem.exists(parent) then
    local ok, reason = ensureDirectory(parent)
    if not ok then return nil, reason end
  end
  return filesystem.makeDirectory(path)
end

local function replaceFile(path, value)
  local temporary = path .. ".tmp"
  local backup = path .. ".old"
  filesystem.remove(temporary)
  local file, reason = io.open(temporary, "wb")
  if not file then return nil, reason end
  local ok, writeReason = file:write(value)
  file:close()
  if not ok then
    filesystem.remove(temporary)
    return nil, writeReason or "write failed"
  end

  filesystem.remove(backup)
  local hadDestination = filesystem.exists(path)
  if hadDestination then
    local moved, moveReason = filesystem.rename(path, backup)
    if not moved then
      filesystem.remove(temporary)
      return nil, moveReason
    end
  end
  local installed, installReason = filesystem.rename(temporary, path)
  if not installed then
    if hadDestination then filesystem.rename(backup, path) end
    filesystem.remove(temporary)
    return nil, installReason
  end
  filesystem.remove(backup)
  return true
end

local function copyFile(from, to)
  local value, reason = readFile(from)
  if not value then return nil, reason end
  return replaceFile(to, value)
end

local function firstLine(value)
  return value and (value:match("^([^\r\n]*)") or "") or ""
end

local function metadata(value)
  local result = {}
  if firstLine(value) ~= HEADER then return result end
  result.managed = true
  for key, setting in value:gmatch("%-%- qboot%-([%w%-]+): ([^\r\n]+)") do
    if key == "diagnostics" then result[key] = setting == "true"
    else result[key] = setting end
  end
  return result
end

local function luaLiteral(value)
  local output = {'"'}
  for index = 1, #value do
    local byte = value:byte(index)
    if byte == 34 then
      output[#output + 1] = '\\"'
    elseif byte == 92 then
      output[#output + 1] = "\\\\"
    elseif byte >= 32 and byte <= 126 then
      output[#output + 1] = string.char(byte)
    else
      output[#output + 1] = string.format("\\%03d", byte)
    end
  end
  output[#output + 1] = '"'
  return table.concat(output)
end

local function quoted(value)
  return string.format("%q", value)
end

local function readEntries(files, kind)
  local result = {}
  for _, definition in ipairs(files) do
    local source, reason = readFile(definition.path)
    if not source then
      if definition.optional then
        result[#result + 1] = {
          kind = kind, name = definition.name, path = definition.path,
          absent = true, source = "", compressed = "",
        }
      else
        return nil, "missing " .. kind .. " boot file " .. definition.path .. ": " .. tostring(reason)
      end
    else
      result[#result + 1] = {
        kind = kind, name = definition.name, path = definition.path,
        source = source, compressed = lzss.compress(source),
      }
    end
  end
  return result
end

local function appendAll(target, values)
  for _, value in ipairs(values) do target[#target + 1] = value end
end

local function normalizePath(path)
  return path:gsub("^/+", "")
end

local function collectDirectories(entries)
  local directories = { [""] = true }
  for _, entry in ipairs(entries) do
    if not entry.absent then
      local path = normalizePath(entry.path)
      local current = ""
      for part in path:gmatch("([^/]+)/") do
        current = current == "" and part or current .. "/" .. part
        directories[current] = true
      end
    end
  end
  return directories
end

local function sortedKeys(values)
  local keys = {}
  for key in pairs(values) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function renderBooleanMap(values)
  local output = {}
  for _, value in ipairs(sortedKeys(values)) do
    output[#output + 1] = "  [" .. quoted(value) .. "] = true,\n"
  end
  return table.concat(output)
end

local function renderModulePaths(entries)
  local output = {}
  for _, entry in ipairs(entries) do
    output[#output + 1] = "  [" .. quoted(entry.name) .. "] = " .. quoted(entry.path) .. ",\n"
  end
  return table.concat(output)
end

local function makeIndexes(groups, values)
  local offset = 1
  local indexes = {raw = {}, module = {}, virtual = {}}
  local parts = {}
  for _, kind in ipairs(groups) do
    for _, entry in ipairs(values[kind]) do
      if not entry.absent then
        local data = entry.compressed
        indexes[kind][entry.name] = {offset, #data}
        parts[#parts + 1] = data
        offset = offset + #data
      end
    end
  end
  return table.concat(parts), indexes
end

local function makeSourceIndexes(groups, values)
  local offset = 1
  local indexes = {raw = {}, module = {}, virtual = {}}
  local parts = {}
  for _, kind in ipairs(groups) do
    for _, entry in ipairs(values[kind]) do
      if not entry.absent then
        indexes[kind][entry.name] = {offset, #entry.source}
        parts[#parts + 1] = entry.source
        offset = offset + #entry.source
      end
    end
  end
  return table.concat(parts), indexes
end

local function renderSliceMap(indexes, sourceName, unpackKind, sliceFunction)
  local output = {}
  sliceFunction = sliceFunction or "stringSub"
  for _, name in ipairs(sortedKeys(indexes)) do
    local position = indexes[name]
    local expression = sliceFunction .. "(" .. sourceName .. ", " .. position[1] .. ", " .. (position[1] + position[2] - 1) .. ")"
    if unpackKind then
      expression = "qbootUnpack(" .. quoted(unpackKind) .. ", " .. quoted(name) .. ", " .. expression .. ")"
    end
    output[#output + 1] = "  [" .. quoted(name) .. "] = " .. expression .. ",\n"
  end
  return table.concat(output)
end

local LOCALIZATION = [==[
local string, assert, table, math, tostring = string, assert, table, math, tostring
local stringByte, stringSub, stringUnpack, stringRep = string.byte, string.sub, string.unpack, string.rep
local tableConcat = table.concat
local mathMax, mathCeil = math.max, math.ceil
]==]

local DECOMPRESSOR = [==[
local function qbootDecompress(input)
  local offset, output, outputCount, window = 1, {}, 0, ""
  local inputLength = #input
  while offset <= inputLength do
    local flags = stringByte(input, offset)
    offset = offset + 1
    local flagBit = 1
    for _ = 1, 8 do
      if offset > inputLength then break end
      local value
      if (flags & flagBit) ~= 0 then
        value = stringSub(input, offset, offset)
        offset = offset + 1
      else
        local token = stringUnpack(">I2", input, offset)
        offset = offset + 2
        local position = (token >> 4) + 1
        local length = (token & 15) + 3
        local windowStart = mathMax(1, #window - 4096 + 1)
        local realPosition = windowStart + position - 1
        local available = stringSub(window, realPosition)
        assert(#available > 0, "invalid QBoot LZSS reference at input " .. tostring(offset) .. ", position " .. tostring(position) .. ", window " .. tostring(#window) .. ", bytes " .. tostring(#input))
        if #available >= length then
          value = stringSub(available, 1, length)
        else
          value = stringSub(stringRep(available, mathCeil(length / #available)), 1, length)
        end
      end
      outputCount = outputCount + 1
      output[outputCount] = value
      window = window .. value
      if #window > 8192 then window = stringSub(window, -4096) end
      flagBit = flagBit << 1
    end
  end
  return tableConcat(output)
end
]==]

local RUNTIME_AFTER_ARCHIVE = [==[
local function qbootNormalize(path)
  local parts = {}
  for part in tostring(path or ""):gsub("\\", "/"):gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 then parts[#parts] = nil end
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, "/")
end

local qbootComponent = component
local qbootOriginalComponentInvoke = qbootComponent.invoke
local qbootHandles = {}
local qbootNextHandle = 0
local qbootFinished = false
local qbootFinishBoot
local qbootSuppressBootScreen = __QBOOT_SUPPRESS_SCREEN__
local qbootGpuAddress = qbootSuppressBootScreen and qbootComponent.list("gpu", true)() or nil

local function qbootVirtualInvoke(address, method, ...)
  if qbootSuppressBootScreen and address == qbootGpuAddress and (method == "fill" or method == "set") then
    return true
  end
  if address ~= addr then return qbootOriginalComponentInvoke(address, method, ...) end
  local first, second = ...
  if method == "exists" then
    local path = qbootNormalize(first)
    if qbootFileMetadata[path] or qbootDirectories[path] then return true end
    if qbootKnownAbsent[path] or path:match("^mnt/[^/]+$") then return false end
    return false
  elseif method == "isDirectory" then
    local path = qbootNormalize(first)
    if qbootDirectories[path] then return true end
    if qbootFileMetadata[path] or qbootKnownAbsent[path] or path:match("^mnt/[^/]+$") then return false end
    return false
  elseif method == "open" then
    local path = qbootNormalize(first)
    local mode = tostring(second or "r")
    local compressed = qbootVirtualFiles[path]
    if type(compressed) ~= "string" or (mode ~= "r" and mode ~= "rb") then
      return nil, "QBoot boot file unavailable: /" .. path
    end
    qbootNextHandle = qbootNextHandle + 1
    local handle = "qboot:" .. tostring(qbootNextHandle)
    qbootHandles[handle] = {data = qbootUnpack("virtual", path, compressed), offset = 1, path = path}
    return handle
  elseif method == "read" then
    local state = qbootHandles[first]
    if not state then return nil, "invalid QBoot handle" end
    if state.offset > #state.data then return nil end
    local requested = tonumber(second) or #state.data
    local remaining = #state.data - state.offset + 1
    local count = math.min(requested, remaining)
    local value = stringSub(state.data, state.offset, state.offset + count - 1)
    state.offset = state.offset + #value
    return value
  elseif method == "close" then
    local state = qbootHandles[first]
    if not state then return nil, "invalid QBoot handle" end
    qbootHandles[first] = nil
    if state.path == "bin/source.lua" then qbootFinishBoot() end
    return true
  elseif method == "getLabel" then
    return "qboot"
  elseif method == "spaceTotal" or method == "spaceUsed" then
    return 0
  elseif method == "isReadOnly" then
    return true
  end
  return nil, "QBoot boot filesystem method unavailable: " .. tostring(method)
end

qbootComponent.invoke = qbootVirtualInvoke

qbootFinishBoot = function()
  if not qbootFinished then
    qbootFinished = true
    qbootComponent.invoke = qbootOriginalComponentInvoke
    qbootVirtualFiles = nil
    qbootHandles = nil
  end
  _G.__qboot_finishBoot = nil
end
_G.__qboot_finishBoot = qbootFinishBoot
]==]

local LOADER = [==[
local qbootPackage
local function loadfile(file)
  if file == "/lib/package.lua" then qbootSuppressBootScreen = false end
  if file == "/lib/package.lua" and qbootPackage then
    return function() return qbootPackage end
  end

  local compressed = qbootRaw[file]
  if type(compressed) ~= "string" then
    return nil, "QBoot raw boot file unavailable: " .. tostring(file)
  end
  local source = qbootUnpack("raw", file, compressed)
  local program, reason = load(source, "=" .. file, "bt", _G)
  if not program then return nil, reason end
  qbootRaw[file] = nil
  return program
end

local packageProgram, packageReason = loadfile("/lib/package.lua")
assert(packageProgram, packageReason)
qbootPackage = packageProgram()
qbootRaw["/lib/package.lua"] = qbootPackage
local originalRequire = require

require = function(module)
  checkArg(1, module, "string")
  local cached = qbootModules[module]
  if type(cached) == "table" then
    return cached
  elseif type(cached) == "string" then
    if qbootLoading[module] then
      error("already loading QBoot module: " .. module .. "\n" .. debug.traceback(), 2)
    end
    qbootLoading[module] = true
    local source = qbootUnpack("module", module, cached)
    local path = assert(qbootModulePaths[module], "missing QBoot module path")
    local program, reason = load(source, "=" .. path, "bt", _G)
    if not program then
      qbootLoading[module] = nil
      error(reason, 2)
    end
    local result = table.pack(pcall(program, module))
    qbootLoading[module] = nil
    if not result[1] then error(result[2], 2) end
    assert(type(result[2]) == "table", "QBoot module did not return a table: " .. module)
    qbootModules[module] = result[2]
    qbootPackage.loaded[module] = result[2]
    return result[2]
  end

  if qbootPackage.loaded[module] ~= nil then return originalRequire(module) end
  return originalRequire(module)
end
]==]

local DIAGNOSTIC_PREFIX = [==[
local qbootStats = {decompressions = {}, rawLoads = 0, moduleLoads = 0, cacheHits = 0}
local qbootUptime, qbootCpuTime = computer.uptime, os.clock
local function qbootUnpack(kind, name, input)
  local startedUptime, startedCpu = qbootUptime(), qbootCpuTime()
  local output = qbootDecompress(input)
  qbootStats.decompressions[#qbootStats.decompressions + 1] = {
    kind = kind, name = name, compressedBytes = #input, sourceBytes = #output,
    uptimeSeconds = qbootUptime() - startedUptime,
    cpuSeconds = qbootCpuTime() - startedCpu,
  }
  return output
end
_G.__qboot_stats = qbootStats
]==]

local NORMAL_UNPACK = [==[
local function qbootUnpack(_, _, input)
  return qbootDecompress(input)
end
]==]

local SOLID_UNPACK = [==[
local function qbootUnpack(_, _, input)
  return input
end
]==]

local function renderEmbeddedMap(entries)
  local output = {}
  for _, entry in ipairs(entries) do
    if not entry.absent then
      output[#output + 1] = "  [" .. quoted(entry.name) .. "] = " .. luaLiteral(entry.compressed) .. ",\n"
    end
  end
  return table.concat(output)
end

local function renderGenerated(sourceInit, options, values)
  local loaderPosition = assert(sourceInit:find(LOADER_START, 1, true), "init.lua has no QuickOS raw loader")
  assert(not sourceInit:find(LOADER_START, loaderPosition + 1, true), "init.lua has multiple raw loaders")
  local bootPosition = assert(sourceInit:find(BOOT_CALL, loaderPosition, true), "init.lua has no QuickOS boot call")
  assert(not sourceInit:find(BOOT_CALL, bootPosition + 1, true), "init.lua has multiple boot calls")
  local beforeLoader = sourceInit:sub(1, loaderPosition - 1)
  local afterBoot = sourceInit:sub(bootPosition + #BOOT_CALL)
  local groups = {"raw", "module", "virtual"}
  local allEntries = {}
  appendAll(allEntries, values.raw)
  appendAll(allEntries, values.module)
  appendAll(allEntries, values.virtual)

  local fileMetadata, absent = {}, {}
  for _, entry in ipairs(allEntries) do
    local path = normalizePath(entry.path)
    if entry.absent then absent[path] = true else fileMetadata[path] = true end
  end
  for _, path in ipairs(KNOWN_ABSENT_PATHS) do absent[path] = true end
  local directories = collectDirectories(allEntries)

  local archiveDeclaration, archiveExpansion, archive
  if options.archiveLayout == "per-file" then
    local joined, indexes = makeIndexes(groups, values)
    archive = options.archiveStorage == "sidecar" and joined or nil
    if options.archiveStorage == "sidecar" then
      archiveDeclaration = [==[
local function qbootReadSidecar()
  local handle, reason = invoke(addr, "open", "/.qboot/archive.lzss")
  assert(handle, reason)
  local chunks = {}
  while true do
    local chunk = invoke(addr, "read", handle, math.maxinteger or math.huge)
    if not chunk then break end
    chunks[#chunks + 1] = chunk
  end
  invoke(addr, "close", handle)
  return tableConcat(chunks)
end
local qbootSidecarData = qbootReadSidecar()
qbootReadSidecar = nil
]==]
      archiveDeclaration = archiveDeclaration
        .. "local qbootRaw = {\n" .. renderSliceMap(indexes.raw, "qbootSidecarData") .. "}\n"
        .. "local qbootModules = {\n" .. renderSliceMap(indexes.module, "qbootSidecarData") .. "}\n"
        .. "local qbootVirtualFiles = {\n" .. renderSliceMap(indexes.virtual, "qbootSidecarData") .. "}\n"
        .. "qbootSidecarData = nil\n"
    else
      archiveDeclaration = "local qbootRaw = {\n" .. renderEmbeddedMap(values.raw) .. "}\n"
        .. "local qbootModules = {\n" .. renderEmbeddedMap(values.module) .. "}\n"
        .. "local qbootVirtualFiles = {\n" .. renderEmbeddedMap(values.virtual) .. "}\n"
    end
    archiveExpansion = ""
  else
    local source, indexes = makeSourceIndexes(groups, values)
    local compressed = lzss.compress(source)
    archive = options.archiveStorage == "sidecar" and compressed or nil
    if options.archiveStorage == "sidecar" then
      archiveDeclaration = [==[
local function qbootReadSidecar()
  local handle, reason = invoke(addr, "open", "/.qboot/archive.lzss")
  assert(handle, reason)
  local chunks = {}
  while true do
    local chunk = invoke(addr, "read", handle, math.maxinteger or math.huge)
    if not chunk then break end
    chunks[#chunks + 1] = chunk
  end
  invoke(addr, "close", handle)
  return tableConcat(chunks)
end
local qbootPackedArchive = qbootReadSidecar()
qbootReadSidecar = nil
]==]
    else
      archiveDeclaration = "local qbootPackedArchive = " .. luaLiteral(compressed) .. "\n"
    end
    archiveExpansion = "local qbootArchiveSource = qbootDecompress(qbootPackedArchive)\nqbootPackedArchive = nil\n"
      .. "local qbootRaw = {\n" .. renderSliceMap(indexes.raw, "qbootArchiveSource") .. "}\n"
      .. "local qbootModules = {\n" .. renderSliceMap(indexes.module, "qbootArchiveSource") .. "}\n"
      .. "local qbootVirtualFiles = {\n" .. renderSliceMap(indexes.virtual, "qbootArchiveSource") .. "}\n"
      .. "qbootArchiveSource = nil\n"
  end

  local header = HEADER .. "\n"
    .. "-- qboot-layout: " .. options.archiveLayout .. "\n"
    .. "-- qboot-storage: " .. options.archiveStorage .. "\n"
    .. "-- qboot-boot-screen: " .. (options.noBootScreen and "disabled" or "enabled") .. "\n"
    .. "-- qboot-diagnostics: " .. tostring(options.diagnostics) .. "\n"
    .. "-- Edit " .. SOURCE_INIT .. " and rebuild; do not edit this file.\n"

  local runtime = LOCALIZATION
    .. archiveDeclaration
    .. "local qbootModulePaths = {\n" .. renderModulePaths(values.module) .. "}\n"
    .. "local qbootFileMetadata = {\n" .. renderBooleanMap(fileMetadata) .. "}\n"
    .. "local qbootDirectories = {\n" .. renderBooleanMap(directories) .. "}\n"
    .. "local qbootKnownAbsent = {\n" .. renderBooleanMap(absent) .. "}\n"
    .. "local qbootLoading = {}\n"
    .. DECOMPRESSOR
    .. archiveExpansion
    .. (options.archiveLayout == "solid" and SOLID_UNPACK or (options.diagnostics and DIAGNOSTIC_PREFIX or NORMAL_UNPACK))
    .. RUNTIME_AFTER_ARCHIVE:gsub("__QBOOT_SUPPRESS_SCREEN__", tostring(options.noBootScreen))
    .. LOADER

  local runnerSource = "return function(bootProgram, rawLoadfile, shutdown)\n"
    .. "local status, err = pcall(bootProgram, rawLoadfile)" .. afterBoot .. "\nend\n"
  local runner = "local qbootRunnerProgram, qbootRunnerReason = load("
    .. luaLiteral(runnerSource) .. ", \"=@qboot/runner.lua\", \"t\", _G)\n"
    .. "assert(qbootRunnerProgram, qbootRunnerReason)\n"
    .. "local qbootRunner = qbootRunnerProgram()\n"
    .. "local qbootBootProgram, qbootBootReason = loadfile(\"/lib/core/boot.lua\")\n"
    .. "assert(qbootBootProgram, qbootBootReason)\n"
    .. "return qbootRunner(qbootBootProgram, loadfile, shutdown)\n"

  return header .. beforeLoader .. runtime .. runner, archive
end

local function validateOptions(options)
  options = options or {}
  local result = {
    archiveLayout = options.archiveLayout or "per-file",
    archiveStorage = options.archiveStorage or "sidecar",
    noBootScreen = not not options.noBootScreen,
    diagnostics = not not options.diagnostics,
  }
  assert(result.archiveLayout == "per-file" or result.archiveLayout == "solid", "archive layout must be per-file or solid")
  assert(result.archiveStorage == "embedded" or result.archiveStorage == "sidecar", "archive storage must be embedded or sidecar")
  return result
end

local function currentSourceInit()
  local source = readFile(SOURCE_INIT)
  if source then return source end
  local active, reason = readFile("/init.lua")
  assert(active, reason)
  local activeHeader = firstLine(active)
  local activeMetadata = metadata(active)
  assert(not activeHeader:match("^%-%- QBOOT%-GENERATED:") or activeHeader == HEADER, "unsupported QBoot header: " .. activeHeader)
  assert(not activeMetadata.managed, "QBoot is enabled but preserved source init.lua is missing")
  assert(ensureDirectory("/.qboot"))
  assert(replaceFile(SOURCE_INIT, active))
  return active
end

local function buildInformation()
  local value = readFile(BUILD_INIT)
  local info = metadata(value)
  info.built = not not info.managed
  if info.built and info.storage == "sidecar" and not filesystem.exists(BUILD_ARCHIVE) then
    info.built = false
    info.reason = "build archive is missing"
  end
  return info
end

function qboot.build(options)
  options = validateOptions(options)
  assert(ensureDirectory("/.qboot"))
  local sourceInit = currentSourceInit()
  local raw, rawReason = readEntries(RAW_FILES, "raw")
  assert(raw, rawReason)
  local modules, moduleReason = readEntries(MODULE_FILES, "module")
  assert(modules, moduleReason)
  local virtual, virtualReason = readEntries(VIRTUAL_FILES, "virtual")
  assert(virtual, virtualReason)

  local generated, archive = renderGenerated(sourceInit, options, {
    raw = raw, module = modules, virtual = virtual,
  })
  if archive then
    assert(replaceFile(BUILD_ARCHIVE, archive))
  else
    filesystem.remove(BUILD_ARCHIVE)
  end
  assert(replaceFile(BUILD_INIT, generated))
  return {
    status = "built and disabled",
    built = true,
    enabled = metadata(assert(readFile("/init.lua"))).managed or false,
    layout = options.archiveLayout,
    storage = options.archiveStorage,
    bootScreen = options.noBootScreen and "disabled" or "enabled",
    diagnostics = options.diagnostics,
    generatedBytes = #generated,
    archiveBytes = archive and #archive or 0,
  }
end

function qboot.status()
  local buildStatus = buildInformation()
  local active = metadata(readFile("/init.lua"))
  local enabled = not not active.managed
  local state
  if enabled then state = "enabled"
  elseif buildStatus.built then state = "built and disabled"
  else state = "not built" end
  local diagnostics = buildStatus.diagnostics
  if enabled then diagnostics = active.diagnostics end
  return {
    status = state,
    built = buildStatus.built,
    enabled = enabled,
    layout = enabled and active.layout or buildStatus.layout,
    storage = enabled and active.storage or buildStatus.storage,
    bootScreen = enabled and active["boot-screen"] or buildStatus["boot-screen"],
    diagnostics = diagnostics,
  }
end

function qboot.enable(options)
  options = options or {}
  local buildStatus = buildInformation()
  if not buildStatus.built or options.forceBuild then
    qboot.build(options)
    buildStatus = buildInformation()
  end
  assert(buildStatus.built, buildStatus.reason or "QBoot build is unavailable")

  if buildStatus.storage == "sidecar" then
    assert(copyFile(BUILD_ARCHIVE, ACTIVE_ARCHIVE))
  else
    filesystem.remove(ACTIVE_ARCHIVE)
  end
  assert(copyFile(BUILD_INIT, "/init.lua"))
  local result = qboot.status()
  result.status = "enabled"
  return result
end

function qboot.restore()
  local source, reason = readFile(SOURCE_INIT)
  assert(source, reason or "QBoot preserved source init.lua is unavailable")
  assert(replaceFile("/init.lua", source))
  filesystem.remove(ACTIVE_ARCHIVE)
  local result = qboot.status()
  result.status = result.built and "built and disabled" or "disabled"
  return result
end

qboot.disable = qboot.restore

return qboot
