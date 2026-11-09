-- mkinstaller: make an installer floppy that runs from the BIOS, without booting an OS.
-- The floppy holds /init.lua (the installer), /lz4.lua (its decompressor), one bundle per
-- package under /install, and /install.cfg listing them with their first-boot settings.
local fs = require("filesystem")
local shell = require("shell")
local serialization = require("serialization")
local frame = require("lz4_frame")

local args, opts = shell.parse(...)
if not args[1] or (#args == 1 and not opts.os) then
  print("Usage: mkinstaller DEST [PROJECT...] [--os[=GROUP,...]] [--skip=PATH,...] [--label=TEXT]")
  print("                   [--name=PATTERN [--first=N]] [--auto=SECONDS]")
  print("DEST is where the floppy is mounted, e.g. /mnt/1a2. Each PROJECT is a directory with a")
  print("bundle.cfg, as for `bundle pack`, which may also say what the installer does at first boot:")
  print('  {name="mill", paths={"etc","usr"}, enable={"worker"}, hostname=true}')
  print("enable lists rc daemons to enable; hostname=true asks for a hostname.")
  print("--os also packs this OS in osinstall's groups (required, qos, sys, basic, man, unsorted),")
  print("without /home, /tmp, /mnt, machine state (hostname, tnet.hosts, rc.cfg, filesystem.cfg) or")
  print("any file in a PROJECT's paths, excluded ones too. --os=required,qos packs only those groups;")
  print("--skip=PATH,... leaves paths out of the OS. --label is the drive label it installs with.")
  print("--name names each computer from a pattern with one number, e.g. mill-%02d, starting at --first")
  print("(default 1). A writable floppy counts up after each install; a read-only one asks instead.")
  print("--auto installs the ticked packages after that many seconds unless a key is pressed; a")
  print("computer with no screen or keyboard installs them at once. Either beeps when done and")
  print("reboots once the floppy is taken out.")
  return
end
-- The pattern takes one number: one % (%% aside), and it formats an integer.
local plain = type(opts.name) == "string" and opts.name:gsub("%%%%", "")
if opts.name and not (plain and select(2, plain:gsub("%%", "")) == 1 and plain:match("%%%d*d")) then
  io.stderr:write("mkinstaller: --name needs exactly one number, e.g. mill-%02d\n"); return 1
end
local first, auto = tonumber(opts.first or 1), opts.auto and tonumber(opts.auto)
if not first or first < 0 or (opts.auto and not (auto and auto > 0)) then
  io.stderr:write("mkinstaller: --first and --auto take numbers\n"); return 1
end

local dest = shell.resolve(args[1])
local entries = {}
-- --os packs every group; --os=a,b only those, in the usual order. Leaving out Required is
-- allowed (full control), but such a floppy can't make an empty drive bootable.
local chosenGroups
if type(opts.os) == "string" then
  chosenGroups = {}
  for id in opts.os:gmatch("[^,]+") do chosenGroups[id] = true end
end
-- Everything written to the floppy, removed again if the installer can't be finished, so a
-- half-made floppy never boots.
local wrote = {}

local function copy(from, to)
  local i = assert(io.open(from, "rb")); local data = i:read("*a"); i:close()
  wrote[#wrote + 1] = to
  local o = assert(io.open(to, "wb")); local done, why = o:write(data)
  if done then done, why = o:flush() end
  o:close(); if not done then error(why or ("could not write " .. to), 0) end
end

local function pack(name, ...)
  local file = fs.concat(dest, "install", name .. ".bundle")
  fs.remove(file)
  wrote[#wrote + 1] = file
  shell.execute("bundle", nil, "pack", ...)
  if not fs.exists(file) then error("bundle did not write " .. file, 0) end
  return "install/" .. name .. ".bundle"
end

-- osinstall's groups; each file goes to the first that matches. Required also takes
-- /bin/hostname.lua, which base.lua runs at boot once /etc/hostname exists.
local GROUPS = {
  {id = "required", name = "Required", required = true, match = function(f)
    return f:match("^/lib/") or f:match("^/etc/") or f:match("^/bin/sh%.lua") or f:match("^/bin/rc%.lua")
      or f == "/bin/hostname.lua" or f == "/init.lua" or f == "/base.lua" end},
  {id = "qos", name = "QOS Tools", on = true, match = function(f) return f:match("^/usr/lib/") end},
  {id = "sys", name = "Sys Tools", on = true, match = function(f)
    for _, n in ipairs({"cfgemu", "flash", "lshw", "mount", "pastebin", "wget"}) do
      if f:match(n .. "%.lua") then return true end
    end end},
  {id = "basic", name = "Basic Tools", on = true, match = function(f) return f:match("^/bin/") end},
  {id = "man", name = "Man Pages", match = function(f) return f:match("^/usr/man/") end},
  {id = "unsorted", name = "Unsorted", match = function() return true end},
}
local known = {}
for _, group in ipairs(GROUPS) do known[group.id] = true end
for id in pairs(chosenGroups or {}) do
  if not known[id] then
    io.stderr:write("mkinstaller: no OS group " .. id .. " (required, qos, sys, basic, man, unsorted)\n"); return 1
  end
end
if chosenGroups and not chosenGroups.required then
  io.stderr:write("mkinstaller: warning: without the required group this floppy can't install a bootable OS\n")
end
local SKIP = {["/home"] = true, ["/tmp"] = true, ["/mnt"] = true, ["/dev"] = true, ["/.qboot"] = true,
  ["/etc/hostname"] = true, ["/etc/tnet.hosts"] = true, ["/etc/rc.cfg"] = true, ["/etc/filesystem.cfg"] = true}

local function packOS()
  local root, found = fs.get("/"), {}
  local function walk(dir)
    for name in fs.list(dir) do
      local full = fs.concat(dir, name)
      if not SKIP[full] and fs.get(full) == root then
        if fs.isDirectory(full) then walk(full) else
          for _, group in ipairs(GROUPS) do
            if group.match(full) then
              found[group] = found[group] or {}
              table.insert(found[group], full)
              break
            end
          end
        end
      end
    end
  end
  walk("/")
  -- With qboot enabled, /init.lua is generated and holds this computer's boot files, rc.cfg
  -- included, and may need /.qboot; the original it was made from is installed instead.
  local init = "/init.lua"
  local f = io.open(init, "rb"); local head = f and f:read("*l") or ""; if f then f:close() end
  if head:match("^%-%- QBOOT%-GENERATED") then
    init = "/.qboot/source-init.lua"
    if not fs.exists(init) then error("qboot is enabled but " .. init .. " is missing", 0) end
  end
  for _, group in ipairs(GROUPS) do
    local files = found[group]
    if files and (not chosenGroups or chosenGroups[group.id]) then
      table.sort(files)
      local name = "os-" .. group.id
      local file = fs.concat(dest, "install", name .. ".bundle")
      -- The bundle format (see bundle.lua), written here so /init.lua can come from elsewhere.
      wrote[#wrote + 1] = file
      local out = assert(frame.open(file, "wb"))
      -- A full floppy shows up as a failed write or close.
      local function put(data) local done, why = out:write(data); if not done then error(why or "write failed", 0) end end
      local ok, why = pcall(function()
        put("OCB1")
        for _, full in ipairs(files) do
          local i = assert(io.open(full == "/init.lua" and init or full, "rb"))
          local data = i:read("*a") or ""; i:close()
          put(string.pack(">s2I4", full:sub(2), #data)); put(data)
        end
        put(string.pack(">s2", ""))
        local flushed, flushWhy = out:flush(); if not flushed then error(flushWhy or "write failed", 0) end
      end)
      local closed, closeWhy = pcall(out.close, out)
      if ok and not closed then ok, why = false, closeWhy end
      if not ok then error(why, 0) end
      entries[#entries + 1] = {file = "install/" .. name .. ".bundle", name = "OS: " .. group.name,
        required = group.required, on = group.on}
    end
  end
end

local projects = {}
for i = 2, #args do
  local dir = fs.canonical(shell.resolve(args[i]))
  local f = io.open(fs.concat(dir, "bundle.cfg"), "rb")
  if not f then io.stderr:write("mkinstaller: no bundle.cfg in " .. dir .. "\n"); return 1 end
  local cfg = serialization.unserialize(f:read("*a") or ""); f:close()
  if type(cfg) ~= "table" or type(cfg.paths) ~= "table" then
    io.stderr:write("mkinstaller: " .. dir .. "/bundle.cfg needs paths={...}\n"); return 1
  end
  projects[#projects + 1] = {dir = dir, cfg = cfg}
  -- Each file in the project's paths, excluded ones too, is left out of the OS where bundle
  -- unpack would put it: under its place, or its path in the project folder.
  local function skip(full, at)
    if fs.isDirectory(full) then
      for name in fs.list(full) do
        name = name:gsub("/$", "")
        skip(fs.concat(full, name), at == "" and name or at .. "/" .. name)
      end
    elseif at ~= "" then SKIP["/" .. at] = true end
  end
  for _, entry in ipairs(cfg.paths) do
    local path, place = entry, nil
    if type(entry) == "table" then path, place = entry[1], entry[2] end
    local full = fs.canonical(path:sub(1, 1) == "/" and path or fs.concat(dir, path))
    skip(full, place or (full == dir and "" or full:sub(#dir + 2)))
  end
end
for path in tostring(type(opts.skip) == "string" and opts.skip or ""):gmatch("[^,]+") do
  SKIP[fs.canonical(shell.resolve(path))] = true
end

local function packProject(project)
  local name = project.cfg.name or fs.name(project.dir)
  entries[#entries + 1] = {file = pack(name, project.dir, "--out=" .. fs.concat(dest, "install", name .. ".bundle")),
    name = name, on = true, enable = project.cfg.enable, hostname = project.cfg.hostname}
end

local ok, why = pcall(function()
  local install = fs.concat(dest, "install")
  fs.makeDirectory(install)
  -- Bundles from an earlier installer on this floppy would only take room.
  for name in fs.list(install) do
    if name:match("%.bundle$") then fs.remove(fs.concat(install, name)) end
  end
  copy("/usr/share/installer/init.lua", fs.concat(dest, "init.lua"))
  copy("/usr/lib/lz4.lua", fs.concat(dest, "lz4.lua"))
  if opts.os then packOS() end
  for _, project in ipairs(projects) do packProject(project) end
  local cfg = fs.concat(dest, "install.cfg")
  wrote[#wrote + 1] = cfg
  local out = assert(io.open(cfg, "wb"))
  local done, why = out:write(serialization.serialize({label = opts.label, name = opts.name, auto = auto, entries = entries}))
  if done then done, why = out:flush() end
  out:close(); if not done then error(why or ("could not write " .. cfg), 0) end
  fs.remove(fs.concat(dest, "next"))
  if opts.name then
    local f = assert(io.open(fs.concat(dest, "next"), "wb")); f:write(tostring(math.floor(first))); f:close()
  end
end)
if not ok then
  for _, file in ipairs(wrote) do fs.remove(file) end
  local install = fs.concat(dest, "install")
  if fs.isDirectory(install) and not fs.list(install)() then fs.remove(install) end
  io.stderr:write("mkinstaller: " .. tostring(why) .. "\n"); return 1
end
local proxy = fs.get(dest)
print(string.format("%d packages on %s: %d of %d KB used", #entries, dest,
  proxy.spaceUsed() // 1024, proxy.spaceTotal() // 1024))
