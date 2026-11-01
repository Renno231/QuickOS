-- Installer floppy, run by the BIOS with no OS. It lists the bundles in /install.cfg on this
-- floppy, unpacks the chosen ones onto a drive, writes the first-boot settings they ask for
-- (rc daemons to enable, a hostname), sets that drive as the boot disk and reboots. Without a
-- screen and keyboard it installs headless and reports by beeping.
-- mkinstaller writes this file, /lz4.lua and /install.cfg; see it for the floppy layout.
local invoke = component.invoke
local floppy = computer.getBootAddress()
local gpu, screen = component.list("gpu")(), component.list("screen")()
local headless = not (gpu and screen and component.list("keyboard")())
gpu = gpu and screen and component.proxy(gpu)
local W, H = 0, 0
if gpu then W, H = gpu.getResolution() end
local LZ4, RAW = "\4\34\77\24", 0x80000000

local function readAll(fs, path)
  local h, why = invoke(fs, "open", path, "rb")
  if not h then return nil, why end
  local parts = {}
  repeat
    local s = invoke(fs, "read", h, math.huge)
    parts[#parts + 1] = s
  until not s
  invoke(fs, "close", h)
  return table.concat(parts)
end

local function writeAll(fs, path, data)
  local h, why = invoke(fs, "open", path, "wb")
  if not h then error(path .. ": " .. tostring(why), 0) end
  invoke(fs, "write", h, data)
  invoke(fs, "close", h)
end

local lz4 = load(assert(readAll(floppy, "/lz4.lua")), "=lz4", "t", _G)()
local cfg = load("return " .. assert(readAll(floppy, "/install.cfg")), "=install.cfg", "t", {})()

-- OpenComputers stops a machine that runs about five seconds without yielding.
local resumed = computer.uptime()
local function breathe()
  if computer.uptime() - resumed > 1 then computer.pullSignal(0); resumed = computer.uptime() end
end

---------------------------------------------------------------- screen and keys

local function put(x, y, s, inverse)
  if not gpu then return end
  gpu.setForeground(inverse and 0 or 0xFFFFFF); gpu.setBackground(inverse and 0xFFFFFF or 0)
  gpu.set(x, y, s)
end

local function page(title, hint)
  if not gpu then return end
  put(1, 1, ""); gpu.fill(1, 1, W, H, " ")
  put(1, 1, (" " .. title):sub(1, W) .. (" "):rep(W - #title - 1), true)
  if hint then put(1, H, hint:sub(1, W)) end
end

local function key()
  while true do
    local name, _, char, code = computer.pullSignal()
    if name == "key_down" then return char, code end
  end
end
local UP, DOWN, ENTER, SPACE, BACK = 200, 208, 28, 57, 14

-- Arrow keys move, Enter picks, Backspace goes back (nil). With toggle, Space ticks rows.
local function menu(title, rows, toggle)
  local at, top = 1, 1
  local lines = H - 4
  while true do
    page(title, toggle and "Up/Down move  Space tick  Enter continue  Backspace back"
                        or "Up/Down move  Enter choose  Backspace back")
    if at < top then top = at elseif at >= top + lines then top = at - lines + 1 end
    for i = top, math.min(#rows, top + lines - 1) do
      local row = rows[i]
      local text = toggle and ((row.locked and "[*] " or row.on and "[x] " or "[ ] ") .. row.text) or row.text
      put(2, 2 + i - top + 1, text:sub(1, W - 2), i == at)
    end
    local _, code = key()
    if code == UP then at = at > 1 and at - 1 or #rows
    elseif code == DOWN then at = at < #rows and at + 1 or 1
    elseif code == SPACE and toggle and not rows[at].locked then rows[at].on = not rows[at].on
    elseif code == ENTER then return at
    elseif code == BACK then return nil end
  end
end

local function prompt(title, question, value)
  while true do
    page(title, "Enter accept  (empty: leave unset)")
    put(2, 3, question)
    put(2, 5, ("> " .. value .. "_" .. (" "):rep(W)):sub(1, W - 2))
    local char, code = key()
    if code == ENTER then return value
    elseif code == BACK then value = value:sub(1, -2)
    elseif char >= 32 and char < 127 then value = value .. string.char(char) end
  end
end

local function message(title, lines, hint)
  page(title, hint or "Press any key")
  for i, line in ipairs(lines) do put(2, 2 + i, line:sub(1, W - 2)) end
  return key()
end

---------------------------------------------------------------- bundles

-- Returns take(n): exactly n bytes from the chunks next() hands out, nil when it runs out.
local function reader(next, what)
  local buf, pos = "", 1
  return function(n)
    local parts, have = {}, 0
    while have < n do
      if pos > #buf then
        buf, pos = next(), 1
        if not buf then error("truncated " .. what, 0) end
      end
      local s = buf:sub(pos, pos + n - have - 1)
      pos, have = pos + #s, have + #s
      parts[#parts + 1] = s
    end
    return table.concat(parts)
  end
end

-- Calls each(path, size, take) for every file in a raw or LZ4-framed bundle on the floppy.
local function unpack(path, each)
  local h = assert(invoke(floppy, "open", path, "rb"))
  local ok, why = pcall(function()
    local file = reader(function() return invoke(floppy, "read", h, math.huge) end, path)
    local data, magic = file, file(4)
    if magic == LZ4 then
      local flags = file(2):byte()   -- then the block size byte
      if flags >> 6 ~= 1 or flags & 32 == 0 or flags & 1 ~= 0 then error(path .. ": unsupported LZ4 frame", 0) end
      file((flags & 8 ~= 0 and 8 or 0) + 1)   -- content size, header checksum
      local ended = false
      data = reader(function()
        if ended then return nil end
        local size = string.unpack("<I4", file(4))
        if size == 0 then ended = true; return nil end
        local block = file(size & ~RAW)
        if flags & 16 ~= 0 then file(4) end
        breathe()
        if size & RAW ~= 0 then return block end
        return lz4.decompress(block)
      end, path)
      magic = data(4)
    end
    if magic ~= "OCB1" then error(path .. ": not a bundle", 0) end
    while true do
      local name = data(string.unpack(">I2", data(2)))
      if name == "" then return end
      local size = string.unpack(">I4", data(4))
      if ("/" .. name .. "/"):find("/%.%./") then error("unsafe path in bundle: " .. name, 0) end
      each(name, size, data)
    end
  end)
  invoke(floppy, "close", h)
  if not ok then error(why, 0) end
end

---------------------------------------------------------------- choices

local function drives()
  local list = {}
  for address in component.list("filesystem") do
    if address ~= floppy and address ~= computer.tmpAddress() and not invoke(address, "isReadOnly") then
      local used, total = invoke(address, "spaceUsed"), invoke(address, "spaceTotal")
      local label = invoke(address, "getLabel") or "no label"
      local os = invoke(address, "exists", "/init.lua") and ", has an OS" or ""
      list[#list + 1] = {address = address, label = label, text = string.format("%s  %s  %d of %d KB used%s",
        label, address:sub(1, 8), used // 1024, total // 1024, os)}
    end
  end
  table.sort(list, function(a, b) return a.address < b.address end)
  return list
end

local function packages()
  local rows = {}
  for _, entry in ipairs(cfg.entries) do
    local size = invoke(floppy, "size", "/" .. entry.file) or 0
    rows[#rows + 1] = {entry = entry, on = entry.on or entry.required, locked = entry.required,
      text = string.format("%-28s %4d KB packed", entry.name, (size + 1023) // 1024)}
  end
  return rows
end

---------------------------------------------------------------- install

local function rcConfig(target, names)
  local text = readAll(target, "/etc/rc.cfg") or "enabled = {}\n"
  local env = {}
  local chunk = load(text, "=rc.cfg", "t", env)
  if chunk then pcall(chunk) end
  local enabled, seen = {}, {}
  for _, name in ipairs(type(env.enabled) == "table" and env.enabled or {}) do
    enabled[#enabled + 1], seen[name] = name, true
  end
  for _, name in ipairs(names) do
    if not seen[name] then enabled[#enabled + 1], seen[name] = name, true end
  end
  local quoted = {}
  for i, name in ipairs(enabled) do quoted[i] = string.format("%q", name) end
  local line = "enabled = {" .. table.concat(quoted, ", ") .. "}"
  local replaced, n = text:gsub("enabled%s*=%s*%b{}", function() return line end, 1)
  if n == 0 then replaced = text .. (text:sub(-1) == "\n" and "" or "\n") .. line .. "\n" end
  writeAll(target, "/etc/rc.cfg", replaced)
end

local function install(drive, chosen, hostname)
  local target, title = drive.address, "Installing to " .. drive.label
  local files, made = 0, {}
  local function line(y, s) put(2, y, (s .. (" "):rep(W)):sub(1, W - 2)) end
  local enable = {}
  page(title)
  for i, entry in ipairs(chosen) do
    line(3, string.format("%s (%d of %d)", entry.name, i, #chosen))
    unpack("/" .. entry.file, function(path, size, take)
      local dir = ("/" .. path):match("^(.*)/[^/]*$")
      if dir ~= "" and not made[dir] then invoke(target, "makeDirectory", dir); made[dir] = true end
      local h, why = invoke(target, "open", "/" .. path, "wb")
      if not h then error(path .. ": " .. tostring(why), 0) end
      while size > 0 do
        local n = math.min(size, 8192)
        local ok, err = invoke(target, "write", h, take(n))
        if not ok then invoke(target, "close", h); error(path .. ": " .. tostring(err), 0) end
        size = size - n
      end
      invoke(target, "close", h)
      files = files + 1
      line(5, string.format("%d files  /%s", files, path))
      breathe()
    end)
    for _, name in ipairs(entry.enable or {}) do enable[#enable + 1] = name end
  end
  if hostname and hostname ~= "" then
    invoke(target, "makeDirectory", "/etc")
    writeAll(target, "/etc/hostname", hostname)
  end
  -- QuickOS starts in /home and its rc needs /etc/rc.cfg; neither is packed (/home and machine state
  -- never are), so an installed OS gets them here.
  if invoke(target, "exists", "/init.lua") then invoke(target, "makeDirectory", "/home") end
  if #enable > 0 or (invoke(target, "exists", "/bin/rc.lua") and not invoke(target, "exists", "/etc/rc.cfg")) then
    invoke(target, "makeDirectory", "/etc")
    rcConfig(target, enable)
  end
  if cfg.label and not invoke(target, "getLabel") then invoke(target, "setLabel", cfg.label) end
  return files, enable
end

---------------------------------------------------------------- main

local title = cfg.label and cfg.label .. " installer" or "Installer"

-- Names from cfg.name, e.g. "mill-%02d", numbered from /next on this floppy. The number moves on
-- after each install that used it, so a writable floppy names each computer it sets up in turn.
local counter = tonumber((readAll(floppy, "/next") or ""):match("%d+") or "")
local writable = not invoke(floppy, "isReadOnly")
-- The next name, only from a floppy that can count past it; a read-only one would repeat it.
local function generated()
  if cfg.name and counter and writable then return string.format(cfg.name, counter) end
end

-- Installs, makes the drive the boot drive when it now has an OS, and moves the counter on.
local function finish(drive, chosen, hostname)
  local ok, files = pcall(install, drive, chosen, hostname)
  if not ok then return false, files end
  if hostname and hostname == generated() then
    counter = counter + 1
    writeAll(floppy, "/next", tostring(counter))
  end
  local boots = invoke(drive.address, "exists", "/init.lua")
  if boots then computer.setBootAddress(drive.address) end
  return true, files, boots
end

local function defaults()
  local chosen, ask = {}, false
  for _, entry in ipairs(cfg.entries) do
    if entry.on or entry.required then chosen[#chosen + 1] = entry; ask = ask or entry.hostname end
  end
  return chosen, ask
end

-- Hands-off: install the ticked packages under the next name, after cfg.auto seconds unless a key
-- is pressed, or at once on a computer with no screen and keyboard. It needs a single drive without
-- an OS, and a name whenever one is wanted; otherwise the menu opens. Without these the floppy
-- could rename a computer that has one already. When done it beeps twice and reboots once the
-- floppy is taken out, so the next computer can have it.
local function handsOff()
  local list = drives()
  if not (cfg.auto or headless) or #list ~= 1 or invoke(list[1].address, "exists", "/init.lua") then return end
  local drive = list[1]
  local chosen, ask = defaults()
  local hostname = generated()
  if (ask or cfg.name) and not hostname then return end
  local names = {}
  for i, entry in ipairs(chosen) do names[i] = entry.name end
  local deadline = computer.uptime() + (headless and 0 or cfg.auto)
  while computer.uptime() < deadline do
    page(title, "Press any key for options")
    put(2, 3, "Installing " .. table.concat(names, ", "))
    put(2, 4, "onto " .. drive.text)
    if hostname then put(2, 5, "as " .. hostname) end
    put(2, 7, string.format("in %d s", math.ceil(deadline - computer.uptime())))
    if computer.pullSignal(math.min(1, deadline - computer.uptime())) == "key_down" then return end
  end
  local ok, files, boots = finish(drive, chosen, hostname)
  if not ok then
    computer.beep(125, 2)
    if headless then computer.shutdown() end
    message(title .. ": failed", {tostring(files), "", "Nothing was rolled back."}); return
  end
  page(title .. ": done", "Take the floppy out to " .. (boots and "reboot" or "turn off"))
  put(2, 3, string.format("Installed %d files on %s%s.", files, drive.label, hostname and " as " .. hostname or ""))
  computer.beep(); computer.beep()
  repeat
    local name, address = computer.pullSignal()
  until name == "component_removed" and address == floppy
  computer.beep()
  computer.shutdown(boots)
end

handsOff()
-- Headless and it couldn't install: one long low beep, then off.
if headless then computer.beep(125, 2); computer.shutdown() end
while true do
  local list = drives()
  if #list == 0 then
    message(title, {"No writable drive found.", "Add a hard drive, then press any key."})
  else
    local d = #list == 1 and 1 or menu(title .. ": choose a drive", list)
    local drive = d and list[d]
    local rows = drive and packages()
    while drive and menu(title .. ": choose what to install", rows, true) do
      local chosen, ask, enable = {}, false, {}
      for _, row in ipairs(rows) do
        if row.on then
          chosen[#chosen + 1] = row.entry
          ask = ask or row.entry.hostname
          for _, name in ipairs(row.entry.enable or {}) do enable[#enable + 1] = name end
        end
      end
      local hostname = (ask or cfg.name) and prompt(title, "Hostname for this computer:", generated()
        or (readAll(drive.address, "/etc/hostname") or ""):match("^[^\r\n]*")) or nil
      local names = {}
      for i, entry in ipairs(chosen) do names[i] = entry.name end
      local summary = {
        "Drive:    " .. drive.text,
        "Install:  " .. (#names > 0 and table.concat(names, ", ") or "nothing"),
        "Enable:   " .. (#enable > 0 and table.concat(enable, ", ") or "no daemons"),
        "Hostname: " .. (hostname and hostname ~= "" and hostname or "unchanged"),
        "",
        "Files already on the drive with the same names are replaced.",
      }
      local _, code = message(title .. ": confirm", summary, "Enter install  any other key back")
      if code == ENTER and #chosen > 0 then
        local ok, files, boots = finish(drive, chosen, hostname)
        if not ok then
          message(title .. ": failed", {tostring(files), "", "Nothing was rolled back."})
        else
          local _, again = message(title .. ": done", {
            string.format("Installed %d files on %s.", files, drive.label),
            boots and "It is now the boot drive." or "It has no /init.lua, so the boot drive is unchanged.",
          }, "Enter reboot  Backspace back to the installer")
          if again ~= BACK then computer.shutdown(true) end
        end
      end
    end
  end
end
