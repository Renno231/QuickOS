-- mkinstaller: make an installer floppy that runs from the BIOS, without booting an OS.
-- The floppy holds /init.lua (the installer), /lz4.lua (its decompressor), one bundle per
-- package under /install, and /install.cfg listing them with their first-boot settings.
local fs = require("filesystem")
local shell = require("shell")
local serialization = require("serialization")
local frame = require("lz4_frame")

local args, opts = shell.parse(...)
if not args[1] or (#args == 1 and not opts.os) then
  print("Usage: mkinstaller DEST [PROJECT...] [--os] [--label=TEXT] [--name=PATTERN [--first=N]] [--auto=SECONDS]")
  print("DEST is where the floppy is mounted, e.g. /mnt/1a2. Each PROJECT is a directory with a")
  print("bundle.cfg, as for `bundle pack`, which may also say what the installer does at first boot:")
  print('  {name="mill", paths={"etc","usr"}, enable={"worker"}, hostname=true}')
  print("enable lists rc daemons to enable; hostname=true asks for a hostname.")
  print("--os also packs this OS in osinstall's groups, without /home, /tmp, /mnt and machine state")
  print("(hostname, tnet.hosts, rc.cfg, filesystem.cfg). --label is the drive label it installs with.")
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

local function copy(from, to)
  local i = assert(io.open(from, "rb")); local o = assert(io.open(to, "wb"))
  o:write(i:read("*a")); i:close(); o:close()
end

local function pack(name, ...)
  local file = fs.concat(dest, "install", name .. ".bundle")
  fs.remove(file)
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
    if files then
      table.sort(files)
      local name = "os-" .. group.id
      local file = fs.concat(dest, "install", name .. ".bundle")
      -- The bundle format (see bundle.lua), written here so /init.lua can come from elsewhere.
      local out = assert(frame.open(file, "wb"))
      local ok, why = pcall(function()
        out:write("OCB1")
        for _, full in ipairs(files) do
          local i = assert(io.open(full == "/init.lua" and init or full, "rb"))
          local data = i:read("*a") or ""; i:close()
          out:write(string.pack(">s2I4", full:sub(2), #data)); out:write(data)
        end
        out:write(string.pack(">s2", ""))
      end)
      out:close()
      if not ok then fs.remove(file); error(why, 0) end
      entries[#entries + 1] = {file = "install/" .. name .. ".bundle", name = "OS: " .. group.name,
        required = group.required, on = group.on}
    end
  end
end

local function packProject(dir)
  dir = shell.resolve(dir)
  local f = io.open(fs.concat(dir, "bundle.cfg"), "rb")
  if not f then error("no bundle.cfg in " .. dir, 0) end
  local cfg = serialization.unserialize(f:read("*a") or ""); f:close()
  if type(cfg) ~= "table" then error(dir .. "/bundle.cfg is not a table", 0) end
  local name = cfg.name or fs.name(dir)
  entries[#entries + 1] = {file = pack(name, dir, "--out=" .. fs.concat(dest, "install", name .. ".bundle")),
    name = name, on = true, enable = cfg.enable, hostname = cfg.hostname}
end

local ok, why = pcall(function()
  fs.makeDirectory(fs.concat(dest, "install"))
  copy("/usr/share/installer/init.lua", fs.concat(dest, "init.lua"))
  copy("/usr/lib/lz4.lua", fs.concat(dest, "lz4.lua"))
  if opts.os then packOS() end
  for i = 2, #args do packProject(args[i]) end
  local out = assert(io.open(fs.concat(dest, "install.cfg"), "wb"))
  out:write(serialization.serialize({label = opts.label, name = opts.name, auto = auto, entries = entries})); out:close()
  fs.remove(fs.concat(dest, "next"))
  if opts.name then
    local f = assert(io.open(fs.concat(dest, "next"), "wb")); f:write(tostring(math.floor(first))); f:close()
  end
end)
if not ok then io.stderr:write("mkinstaller: " .. tostring(why) .. "\n"); return 1 end
local proxy = fs.get(dest)
print(string.format("%d packages on %s: %d of %d KB used", #entries, dest,
  proxy.spaceUsed() // 1024, proxy.spaceTotal() // 1024))
