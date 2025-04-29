local shutdown = computer.shutdown
local addr, invoke = computer.getBootAddress(), component.invoke
local function loadfile(file)
  local handle = assert(invoke(addr, "open", file))
  local buffer = ""
  repeat
    local data = invoke(addr, "read", handle, math.maxinteger or math.huge)
    buffer = buffer .. (data or "")
  until not data
  invoke(addr, "close", handle)
  return load(buffer, "=" .. file, "bt", _G)
end
local status, err = pcall(loadfile("/lib/core/boot.lua"), loadfile)
if err == "interrupted" then
  io.write("Detected force interrupt (Ctrl+Alt+C)\n")
end
if not status then
  if io ~= nil then
    io.write("OS crashed, rebooting in 5 seconds\n")
    io.write("\"" .. tostring(err) .. "\"")
    os.sleep(5)
  else
    error(tostring(err))
  end
end
shutdown(true)